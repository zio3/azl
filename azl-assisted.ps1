<#
.SYNOPSIS
  Assisted interactive Azure login: sign in as yourself and land on the RIGHT tenant.
.DESCRIPTION
  azl's core, thinnest job. Driving az from an LLM/CLI, the classic pain is that a
  plain `az login` only authenticates your HOME tenant -- every other tenant fails
  with "AccountUnusable" and you can't reach its subscriptions/directory until you
  run `az login --tenant <ID>`. So the thing you actually need to choose is the
  TENANT.

  This flow:
    1) az login (home tenant) just to bootstrap a token
    2) list ALL tenants you belong to (by name + domain, not GUIDs)
    3) you pick a tenant
    4) az login --tenant <chosen>  -> clears AccountUnusable for that tenant
    5) pick a subscription in it (auto if only one; skipped if none)

  You end up logged in AS YOURSELF, on the tenant you meant. No SP, no vault.
  For unattended/automation (no browser), use an SP alias: `azl <name>`.
.PARAMETER Graph
  Also acquire the Microsoft Graph scope for the chosen tenant, so `az ad ...`
  (directory operations) work without a re-login.
#>
[CmdletBinding()]
param(
    [switch]$Graph,
    # Assisted login is always a user login; -User is accepted as a no-op so that
    # `azl -User` (habit from `azl <name> -User`) doesn't error out.
    [switch]$User
)

$ErrorActionPreference = 'Stop'

function Resolve-AzCli {
    foreach ($candidate in @('az', 'az.cmd')) {
        $c = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
    }
    return $null
}

# Run az tolerating stderr notices (they would trip $ErrorActionPreference='Stop').
function Invoke-Az {
    param([string[]]$AzArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $azBin @AzArgs 2>&1
        return [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $out }
    } finally {
        $ErrorActionPreference = $prev
    }
}

function ConvertFrom-AzJson {
    param($Res)
    if ($Res.Exit -ne 0) { return $null }
    try {
        # PS 5.1's ConvertFrom-Json returns a JSON array as ONE Object[] item
        # (unlike PS 7, which enumerates). The trailing ForEach-Object unrolls it
        # so callers see individual elements on both versions.
        return ($Res.Out | Where-Object { $_ -notmatch '^WARNING' } | ForEach-Object { $_.ToString() }) -join "`n" | ConvertFrom-Json | ForEach-Object { $_ }
    } catch { return $null }
}

# ARM + (optional) Graph login for a specific tenant.
function Connect-Tenant {
    param([string]$TenantId, [bool]$WithGraph)
    if ((Invoke-Az @('login','--tenant',$TenantId,'--output','none')).Exit -ne 0) {
        return $false
    }
    if ($WithGraph) {
        if ((Invoke-Az @('login','--tenant',$TenantId,'--scope','https://graph.microsoft.com//.default','--output','none')).Exit -ne 0) {
            Write-Host "[azl] Graph スコープの取得に失敗しました (ARM ログインは有効)。" -ForegroundColor Yellow
        }
    }
    return $true
}

$azBin = Resolve-AzCli
if (-not $azBin) {
    Write-Error "Azure CLI (az) not found. Install: winget install Microsoft.AzureCLI"
    exit 1
}

# --- 1. Bootstrap login (home tenant) to obtain a token for the tenants query -----
Write-Host "[azl] az login でサインインします (ブラウザでアカウントを選択)..."
if ((Invoke-Az @('login','--output','none')).Exit -ne 0) {
    Write-Error "az login に失敗しました。ブラウザでアカウントを選び直してください。"
    exit 1
}
$acct = ConvertFrom-AzJson (Invoke-Az @('account','show','--output','json'))
$currentTenant = if ($acct) { [string]$acct.tenantId } else { $null }

# --- 2. List ALL tenants (name + domain), not just the home one -------------------
$ten = ConvertFrom-AzJson (Invoke-Az @('rest','--method','get','--uri','https://management.azure.com/tenants?api-version=2022-12-01','--output','json'))
$tenants = if ($ten) { @($ten.value) } else { @() }

$chosenTenantId   = $currentTenant
$chosenTenantName = $null
if ($tenants.Count -gt 1) {
    Write-Host ""
    Write-Host "テナントを選択してください:"
    $defaultIndex = 1
    for ($i = 0; $i -lt $tenants.Count; $i++) {
        $t = $tenants[$i]
        $marker = if ($t.tenantId -eq $currentTenant) { ' [current]' } else { '' }
        if ($t.tenantId -eq $currentTenant) { $defaultIndex = $i + 1 }
        Write-Host ("  {0,2}) {1}  ({2}){3}" -f ($i + 1), $t.displayName, $t.defaultDomain, $marker)
    }
    Write-Host ""
    $sel = Read-Host "Number [$defaultIndex]"
    if (-not $sel) { $sel = "$defaultIndex" }
    $selInt = 0
    if (-not [int]::TryParse($sel, [ref]$selInt) -or $selInt -lt 1 -or $selInt -gt $tenants.Count) {
        Write-Error "Invalid selection: $sel"
        exit 1
    }
    $chosenTenantId   = [string]$tenants[$selInt - 1].tenantId
    $chosenTenantName = [string]$tenants[$selInt - 1].displayName
} elseif ($tenants.Count -eq 1) {
    $chosenTenantId   = [string]$tenants[0].tenantId
    $chosenTenantName = [string]$tenants[0].displayName
}
$chosenTenantLabel = if ($chosenTenantName) { $chosenTenantName } else { $chosenTenantId }

# --- 3. Log into the chosen tenant (clears AccountUnusable) + optional Graph -------
# Always (re)login to the chosen tenant unless it's already current and no Graph is
# needed -- a fresh tenant needs it, the home tenant re-login is silent from cache.
if (($chosenTenantId -ne $currentTenant) -or $Graph) {
    Write-Host ("[azl] テナント {0} にログインします..." -f $chosenTenantLabel)
    if (-not (Connect-Tenant -TenantId $chosenTenantId -WithGraph:$Graph)) {
        Write-Error "テナント $chosenTenantId へのログインに失敗しました。"
        exit 1
    }
}

# --- 4. Pick a subscription in the chosen tenant ----------------------------------
$subs = @(@(ConvertFrom-AzJson (Invoke-Az @('account','list','--output','json'))) | Where-Object { $_.tenantId -eq $chosenTenantId })
if ($subs.Count -eq 0) {
    Write-Host ("[azl] テナント '{0}' にサブスクリプションはありません (ディレクトリ操作のみ可)。" -f $chosenTenantLabel)
} else {
    $chosen = $null
    if ($subs.Count -eq 1) {
        $chosen = $subs[0]
        Write-Host ("[azl] サブスクリプション: {0} ({1})" -f $chosen.name, $chosen.id)
    } else {
        Write-Host ""
        Write-Host "サブスクリプションを選択してください:"
        $defaultIndex = 1
        for ($i = 0; $i -lt $subs.Count; $i++) {
            $s = $subs[$i]
            $marker = if ($s.isDefault) { ' [default]' } else { '' }
            if ($s.isDefault) { $defaultIndex = $i + 1 }
            Write-Host ("  {0,2}) {1}  ({2}){3}" -f ($i + 1), $s.name, $s.id, $marker)
        }
        Write-Host ""
        $sel = Read-Host "Number [$defaultIndex]"
        if (-not $sel) { $sel = "$defaultIndex" }
        $selInt = 0
        if (-not [int]::TryParse($sel, [ref]$selInt) -or $selInt -lt 1 -or $selInt -gt $subs.Count) {
            Write-Error "Invalid selection: $sel"
            exit 1
        }
        $chosen = $subs[$selInt - 1]
    }
    Invoke-Az @('account','set','--subscription',$chosen.id) | Out-Null
}

# --- 5. Show the resulting context ------------------------------------------------
$acct = ConvertFrom-AzJson (Invoke-Az @('account','show','--output','json'))
if ($acct) {
    $gtag = if ($Graph) { ' [graph]' } else { '' }
    $tn = if ($chosenTenantName) { $chosenTenantName } else { $acct.tenantId }
    Write-Host ("[azl] Active{0}: {1} | tenant={2} | sub={3}" -f $gtag, $acct.user.name, $tn, $acct.name)
    if ($env:AZURE_CONFIG_DIR) {
        Write-Host ("[azl] config: AZURE_CONFIG_DIR={0}" -f $env:AZURE_CONFIG_DIR)
    }
    Write-Host "[azl] このまま 'az ...' を実行できます。"
} else {
    Write-Host "[azl] ログイン状態を確認できませんでした。'az account show' で確認してください。" -ForegroundColor Yellow
}
exit 0
