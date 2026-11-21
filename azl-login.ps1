<#
.SYNOPSIS
  Log in to Azure via a stored service principal alias.
.DESCRIPTION
  Output modes:
    (default) minimal: start / active summary / secret days remaining.
    -Verbose  full step-by-step output with timestamps.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Name,
    [switch]$User,
    [switch]$Graph
)

# Both -User and -Graph are interactive user logins (differ only in requested scope).
$isUser = $User -or $Graph

$ErrorActionPreference = 'Stop'
$VaultName = 'azl'
$startedAt = Get-Date

$isVerbose = $PSBoundParameters.ContainsKey('Verbose') -or ($VerbosePreference -eq 'Continue')

# Levels:
#   STEP / OK / INFO : only shown in -Verbose
#   SUMMARY          : always shown
#   WARN / ERROR     : always shown
function Log {
    param(
        [string]$Msg,
        [string]$Level = 'INFO'
    )
    $show = $false
    switch ($Level) {
        'WARN'    { $show = $true }
        'ERROR'   { $show = $true }
        'SUMMARY' { $show = $true }
        default   { if ($isVerbose) { $show = $true } }
    }
    if (-not $show) { return }

    if ($isVerbose) {
        $t = (Get-Date).ToString('HH:mm:ss.fff')
        $elapsed = ((Get-Date) - $startedAt).TotalSeconds
        $tag = switch ($Level) {
            'WARN'    { '[azl WARN]' }
            'ERROR'   { '[azl ERR ]' }
            'STEP'    { '[azl STEP]' }
            'OK'      { '[azl  OK ]' }
            'SUMMARY' { '[azl  >> ]' }
            default   { '[azl INFO]' }
        }
        Write-Host ("{0} {1} +{2:N2}s  {3}" -f $t, $tag, $elapsed, $Msg)
    } else {
        $prefix = switch ($Level) {
            'WARN'  { '[azl WARN]' }
            'ERROR' { '[azl ERR ]' }
            default { '[azl]' }
        }
        Write-Host "$prefix $Msg"
    }
}

Log ("ログインを開始します: {0}" -f $Name) 'SUMMARY'
Log "Starting azl for alias '$Name'" 'STEP'

Log "Resolving Azure CLI..."
function Resolve-AzCli {
    foreach ($candidate in @('az', 'az.cmd')) {
        $c = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
    }
    return $null
}
$azBin = Resolve-AzCli
if (-not $azBin) {
    Log "Azure CLI (az) not found. Install: winget install Microsoft.AzureCLI" 'ERROR'
    exit 1
}
Log "Using az at: $azBin" 'OK'

Log "Loading Microsoft.PowerShell.SecretManagement module..."
if (-not (Get-Module -ListAvailable Microsoft.PowerShell.SecretManagement)) {
    Log "Module not installed." 'ERROR'
    exit 1
}
Import-Module Microsoft.PowerShell.SecretManagement -ErrorAction Stop
Log "Module loaded." 'OK'

Log "Checking vault '$VaultName'..."
$vault = Get-SecretVault -Name $VaultName -ErrorAction SilentlyContinue
if (-not $vault) {
    Log "Vault '$VaultName' is not registered. Run setup first." 'ERROR'
    exit 1
}
Log "Vault OK (module=$($vault.ModuleName))." 'OK'

Log "Reading secret '$Name' from vault..." 'STEP'
$data = $null
try {
    $data = Get-Secret -Name $Name -Vault $VaultName -AsPlainText -ErrorAction Stop
} catch {
    Log "Alias '$Name' not found. Register it first: azl register (登録の最後に alias 名を聞かれます)" 'ERROR'
    exit 1
}
if ($data -isnot [hashtable]) {
    Log "Stored secret for '$Name' is not a hashtable (type: $($data.GetType().Name))." 'ERROR'
    exit 1
}
Log "Secret loaded (keys: $($data.Keys -join ', '))." 'OK'

Log "Validating required fields..."
$requiredFields = if ($isUser) { @('tenantId') } else { @('appId','tenantId','secret') }
foreach ($required in $requiredFields) {
    if (-not $data.ContainsKey($required) -or [string]::IsNullOrEmpty([string]$data[$required])) {
        $modeLabel = if ($isUser) { ' (user mode requires tenantId)' } else { '' }
        Log "Field '$required' is missing or empty in alias '$Name'.$modeLabel" 'ERROR'
        exit 1
    }
}
$appId      = [string]$data.appId
$tenant     = [string]$data.tenantId
$secret     = [string]$data.secret
$sub        = [string]$data.subscriptionId
$tenantName = [string]$data.tenantName
$subName    = [string]$data.subscriptionName
Log "Required fields OK." 'OK'

$loginStart = Get-Date
if ($isUser) {
    # Any interactive user login needs ARM: right after auth, az enumerates
    # subscriptions via ARM, so a Graph-only login fails with AccountUnusable.
    # => always acquire ARM first; -Graph adds the Graph scope on top.

    # Interactive: tell the caller up front that a human must act in the browser
    # (an LLM shell would otherwise just see the command "hang").
    Log "ブラウザでのサインイン操作が必要です。人が操作してください (LLM からは実行しない)..." 'SUMMARY'

    Log ("Calling az login --tenant {0} (user mode, scope=ARM, interactive browser)..." -f $tenant) 'STEP'
    # az login --tenant writes an interactive "Select the account..." notice to stderr.
    # Under $ErrorActionPreference='Stop' that surfaces as a NativeCommandError and aborts
    # the script even though the login itself succeeds, so relax it around this call.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $loginOut = & $azBin login --tenant $tenant --output none 2>&1
        $loginExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEAP
    }

    if ($Graph -and $loginExit -eq 0) {
        # The ARM login's refresh token can usually be redeemed for the Graph scope
        # WITHOUT a second browser round-trip, so probe silently first. Only when
        # that fails (e.g. per-resource Conditional Access, missing consent) fall
        # back to a second interactive login.
        Log "Trying to acquire the Graph scope silently from the token cache..." 'STEP'
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $azBin account get-access-token --resource-type ms-graph --tenant $tenant --output none 2>&1 | Out-Null
            $graphSilentExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prevEAP
        }
        if ($graphSilentExit -eq 0) {
            Log "Graph スコープはキャッシュから取得しました (追加ログインなし)" 'SUMMARY'
        } else {
            Log "Graph スコープのサイレント取得に失敗。ブラウザで追加ログインします..." 'SUMMARY'
            Log ("Calling az login --tenant {0} (user mode, scope=Microsoft Graph, interactive browser)..." -f $tenant) 'STEP'
            $prevEAP = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $loginOut = & $azBin login --tenant $tenant --scope 'https://graph.microsoft.com//.default' --output none 2>&1
                $loginExit = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $prevEAP
            }
        }
    }
} else {
    $appIdMasked = if ($appId.Length -ge 8) { $appId.Substring(0,8) + '...' } else { $appId }
    Log ("Calling az login --service-principal (tenant={0}, appId={1}, secret=***)..." -f $tenant, $appIdMasked) 'STEP'
    $loginOut = & $azBin login --service-principal -u $appId -p $secret --tenant $tenant --output none 2>&1
    $loginExit = $LASTEXITCODE
}
$loginDur = ((Get-Date) - $loginStart).TotalSeconds

$secret = $null
[GC]::Collect()

if ($loginExit -ne 0) {
    # $loginOut is an array of output/error records (from 2>&1); flatten so the real
    # az error text is shown instead of "System.Object[]".
    $loginErr = (@($loginOut) | ForEach-Object { $_.ToString() }) -join "`n"
    Log ("az login failed after {0:N2}s:`n{1}" -f $loginDur, $loginErr) 'ERROR'
    exit $loginExit
}
Log ("az login succeeded in {0:N2}s." -f $loginDur) 'OK'

if ($sub) {
    Log "Setting default subscription to $sub..." 'STEP'
    $setOut = & $azBin account set --subscription $sub 2>&1
    if ($LASTEXITCODE -ne 0) {
        # Fail hard: callers (especially LLMs) trust the exit code. Continuing on the
        # wrong subscription silently misroutes every subsequent az command.
        Log "az account set failed ($sub): $setOut" 'ERROR'
        exit 1
    } else {
        Log "Default subscription set." 'OK'
    }
} else {
    Log "No subscriptionId in alias; skipping az account set."
}

Log "Fetching active account info..." 'STEP'
$showJson = & $azBin account show --output json 2>$null
$showExit = $LASTEXITCODE
if ($showExit -eq 0) {
    $account = $showJson | ConvertFrom-Json
    $subLabel = if ($subName) { $subName } else { $account.name }
    $modeTag = if ($Graph) { ' [user+graph]' } elseif ($User) { ' [user]' } else { '' }
    Log ("Active: {0}{1} | {2} / {3} | sub={4}" -f $Name, $modeTag, $tenantName, $subLabel, $account.id) 'SUMMARY'
    if ($env:AZURE_CONFIG_DIR) {
        Log ("config: AZURE_CONFIG_DIR={0}" -f $env:AZURE_CONFIG_DIR) 'SUMMARY'
    } else {
        # Shared profile: switching an alias here also switches every other session
        # that uses the default ~/.azure. Say so, so nobody debugs phantom 403s.
        Log "config: 共有プロファイル (~/.azure) — AZURE_CONFIG_DIR 未設定のため、他のセッションのログイン先も切り替わります" 'SUMMARY'
    }
} else {
    # Fail hard: a login whose final state cannot be verified must not report success.
    Log "az account show failed; login state unclear." 'ERROR'
    exit 1
}

if ($isUser) {
    $totalDur = ((Get-Date) - $startedAt).TotalSeconds
    Log ("Done in {0:N2}s." -f $totalDur) 'OK'
    exit 0
}

Log "Checking SP secret expiration..." 'STEP'

# Report remaining days for a known expiry date (shared by vault-based and
# Graph-based checks below).
function Show-ExpiryStatus {
    param([datetime]$End, [string]$Source)
    $days = [math]::Floor(($End - (Get-Date)).TotalDays)
    $dateStr = $End.ToString('yyyy-MM-dd')
    $portalUrl = "https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/Credentials/appId/$appId"
    # 更新の案内。自分で管理できる SP は 'azl <name> -Graph' → 'azl renew <name>' で
    # 自動更新。他者から受領した SP は提供元に依頼し 'azl rotate <name>' で登録。
    $renewHint  = "  更新: azl $Name -Graph してから azl renew $Name（この App を管理できる場合）"
    $rotateHint = "  もらった SP の場合: 提供元にローテ依頼 → azl rotate $Name"
    if ($days -le 7) {
        Log ("シークレット残り {0} 日で切れます ({1}{2}) — 今すぐ更新してください" -f $days, $dateStr, $Source) 'WARN'
        Log $renewHint 'WARN'
        Log $rotateHint 'WARN'
        Log ("  Portal: {0}" -f $portalUrl) 'WARN'
    } elseif ($days -le 30) {
        Log ("シークレット残り {0} 日で切れます ({1}{2}) — 更新推奨" -f $days, $dateStr, $Source) 'WARN'
        Log $renewHint 'WARN'
        Log $rotateHint 'WARN'
        Log ("  Portal: {0}" -f $portalUrl) 'WARN'
    } else {
        Log ("シークレット残り {0} 日で切れます ({1}{2})" -f $days, $dateStr, $Source) 'SUMMARY'
    }
}

# Preferred: expiry recorded in the vault by azl renew/register/rotate.
# Needs no Graph permission, so it works under plain SP login.
$vaultEnd = $null
if ($data.ContainsKey('secretExpiresAt') -and $data.secretExpiresAt) {
    try { $vaultEnd = [datetime]::ParseExact([string]$data.secretExpiresAt, 'yyyy-MM-dd', $null) } catch { $vaultEnd = $null }
}
if ($vaultEnd) {
    Show-ExpiryStatus -End $vaultEnd -Source ''
    $totalDur = ((Get-Date) - $startedAt).TotalSeconds
    Log ("Done in {0:N2}s." -f $totalDur) 'OK'
    exit 0
}

# Fallback: read the App Registration via Graph (fails under plain SP login
# unless the SP has been granted read access).
# Compute hint of our stored secret so we can identify the exact credential entry
$ourHint = $null
if ($data.secret) {
    $s = [string]$data.secret
    if ($s.Length -ge 3) { $ourHint = $s.Substring(0, 3) }
}

$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $credsJson = & $azBin ad app credential list --id $appId --output json 2>&1
    $credsExit = $LASTEXITCODE
} catch {
    $credsJson = $_.ToString()
    $credsExit = 1
} finally {
    $ErrorActionPreference = $prevEAP
}
if ($credsExit -eq 0) {
    try {
        $creds = $credsJson | ConvertFrom-Json
    } catch {
        $creds = $null
    }
    $credsArr = @($creds)
    if ($credsArr.Count -gt 0) {
        $now = Get-Date
        $matched = $null
        if ($ourHint) {
            foreach ($c in $credsArr) {
                if ($c.hint -eq $ourHint) { $matched = $c; break }
            }
        }
        if ($matched) {
            try { $end = [datetime]$matched.endDateTime } catch { $end = $null }
            if ($end) {
                Show-ExpiryStatus -End $end -Source ''
            } else {
                Log "Matched credential has invalid endDateTime." 'WARN'
            }
        } else {
            Log "Could not match stored secret to any credential on this App Registration." 'WARN'
        }
    } else {
        Log "Credential list returned empty." 'WARN'
    }
} else {
    Log "期限チェックをスキップ (権限不足・vault に期限情報なし)" 'SUMMARY'
    Log "有効化: 'azl renew $Name' で更新すると期限が vault に記録され、以後チェック可能になります。"
}

$totalDur = ((Get-Date) - $startedAt).TotalSeconds
Log ("Done in {0:N2}s." -f $totalDur) 'OK'

exit 0
