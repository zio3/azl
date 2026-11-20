<#
.SYNOPSIS
  Auto-renew the SP client secret for an azl alias (generate a fresh secret via Graph).
.DESCRIPTION
  Unlike 'azl rotate' (which asks you to paste a secret produced elsewhere), 'renew'
  generates a brand-new secret itself with `az ad app credential reset --append`,
  stores it in the vault, then removes the previous credential.

  Requires being logged in as a USER who can manage the App Registration
  (owner, or Global Administrator / Application Administrator). The SP itself
  cannot manage its own credentials, so run `azl <name> -Graph` first.

  For a service principal you received from someone else (which you cannot
  administer), renew is not possible -- this script detects that and points
  you to `azl rotate` instead.
.PARAMETER Name
  The alias to renew.
.PARAMETER Years
  Lifetime of the new secret in years (default 2).
.PARAMETER KeepOld
  Do not delete the previous credential after a successful renew (leave an overlap).
#>
param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Name,
    [int]$Years = 2,
    [switch]$KeepOld
)

$ErrorActionPreference = 'Stop'
$VaultName = 'azl'

function Resolve-AzCli {
    foreach ($candidate in @('az', 'az.cmd')) {
        $c = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
    }
    return $null
}

# Run a native az command with stderr warnings tolerated (az writes notices to stderr
# which would trip $ErrorActionPreference='Stop' as NativeCommandError otherwise).
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

$azBin = Resolve-AzCli
if (-not $azBin) {
    Write-Error "Azure CLI (az) not found. Install: winget install Microsoft.AzureCLI"
    exit 1
}

if (-not (Get-Module -ListAvailable Microsoft.PowerShell.SecretManagement)) {
    Write-Error "Microsoft.PowerShell.SecretManagement not installed."
    exit 1
}
Import-Module Microsoft.PowerShell.SecretManagement -ErrorAction Stop

$vault = Get-SecretVault -Name $VaultName -ErrorAction SilentlyContinue
if (-not $vault) {
    Write-Error "Vault '$VaultName' is not registered."
    exit 1
}

$data = $null
try {
    $data = Get-Secret -Name $Name -Vault $VaultName -AsPlainText -ErrorAction Stop
} catch {
    Write-Error "Alias '$Name' not found. Use 'azl register' first."
    exit 1
}
if ($data -isnot [hashtable]) {
    Write-Error "Stored secret for '$Name' is not a hashtable."
    exit 1
}
foreach ($required in @('appId','tenantId')) {
    if (-not $data.ContainsKey($required) -or [string]::IsNullOrEmpty([string]$data[$required])) {
        Write-Error "Field '$required' missing in alias '$Name'. Re-register via 'azl register'."
        exit 1
    }
}

$appId      = [string]$data.appId
$tenant     = [string]$data.tenantId
$tenantName = [string]$data.tenantName
$subName    = [string]$data.subscriptionName

# --- 1. Must be a USER login (the SP cannot manage its own credentials) -----------
$acctRes = Invoke-Az @('account','show','--output','json')
$acct = $null
if ($acctRes.Exit -eq 0) { try { $acct = ($acctRes.Out -join "`n") | ConvertFrom-Json } catch { } }
if (-not $acct) {
    Write-Error "Not logged in. Run 'azl $Name -Graph' first (user login with Graph scope)."
    exit 1
}
if ($acct.user.type -ne 'user') {
    Write-Host "[azl renew] 現在サービスプリンシパルとしてログインしています。" -ForegroundColor Yellow
    Write-Host "SP は自分自身のシークレットを更新できません。まず本人ログインしてください:"
    Write-Host "    azl $Name -Graph"
    Write-Host "その後もう一度 'azl renew $Name' を実行してください。"
    exit 1
}

# --- 2. Manageability guard: can we read this App Registration? --------------------
# A received/foreign SP that you don't administer will fail here -> point to rotate.
$showRes = Invoke-Az @('ad','app','show','--id',$appId,'--output','none')
if ($showRes.Exit -ne 0) {
    Write-Host "[azl renew] この App Registration ($appId) を参照/管理できません。" -ForegroundColor Yellow
    Write-Host "他者から受領した SP や、あなたが管理者でないテナントの SP の可能性があります。"
    Write-Host "その場合はここでは更新できません。提供元にローテーションを依頼し、"
    Write-Host "新しいシークレットを受け取ったら次で登録してください:"
    Write-Host "    azl rotate $Name"
    exit 2
}

# --- 3. Record our current credential (by hint) so we can delete just ours later ---
$oldHint = $null
if ($data.secret) {
    $s = [string]$data.secret
    if ($s.Length -ge 3) { $oldHint = $s.Substring(0,3) }
}
$oldKeyId = $null
$listRes = Invoke-Az @('ad','app','credential','list','--id',$appId,'--output','json')
if ($listRes.Exit -eq 0) {
    try { $creds = ($listRes.Out -join "`n") | ConvertFrom-Json } catch { $creds = $null }
    if ($oldHint -and $creds) {
        foreach ($c in @($creds)) {
            if ($c.hint -eq $oldHint) { $oldKeyId = $c.keyId; break }
        }
    }
}

# --- 4. Generate a fresh secret (append so existing sessions keep working) ---------
$stamp = (Get-Date).ToString('yyyyMMdd')
$dn = "azl-$Name-$stamp"
Write-Host "[azl renew] '$Name' ($tenantName / $subName) の新しいシークレットを生成します (有効 $Years 年)..."
$resetRes = Invoke-Az @('ad','app','credential','reset','--id',$appId,'--append','--years',"$Years",'--display-name',$dn,'--output','json')
if ($resetRes.Exit -ne 0) {
    $err = ($resetRes.Out | ForEach-Object { $_.ToString() }) -join "`n"
    Write-Host "[azl renew] シークレットの生成に失敗しました:" -ForegroundColor Yellow
    Write-Host $err
    Write-Host ""
    Write-Host "権限不足の場合、この SP を管理できない可能性があります。"
    Write-Host "提供元に依頼して 'azl rotate $Name' で登録するか、権限を確認してください。"
    exit 3
}
try {
    $new = ($resetRes.Out | Where-Object { $_ -notmatch '^WARNING' } | ForEach-Object { $_.ToString() }) -join "`n" | ConvertFrom-Json
} catch {
    $new = $null
}
$newSecret = if ($new) { [string]$new.password } else { $null }
if ([string]::IsNullOrEmpty($newSecret)) {
    Write-Error "Reset succeeded but no password was returned; aborting without changing the vault."
    exit 3
}
Write-Host "[azl renew] 新シークレットを取得しました。"

# --- 5. Store new secret + its expiry in the vault (preserve all other fields) -----
# Record the exact endDateTime so 'azl <name>' can warn about expiry offline,
# without any Graph permission (the SP cannot read its own credentials).
$newHint = if ($newSecret.Length -ge 3) { $newSecret.Substring(0, 3) } else { $null }
$expiresAt = $null
$listRes2 = Invoke-Az @('ad','app','credential','list','--id',$appId,'--output','json')
if ($listRes2.Exit -eq 0 -and $newHint) {
    try {
        $creds2 = ($listRes2.Out | Where-Object { $_ -notmatch '^WARNING' } | ForEach-Object { $_.ToString() }) -join "`n" | ConvertFrom-Json
    } catch { $creds2 = $null }
    foreach ($c in @($creds2)) {
        if ($c.hint -eq $newHint) {
            try { $expiresAt = ([datetime]$c.endDateTime).ToString('yyyy-MM-dd') } catch { }
            break
        }
    }
}
if (-not $expiresAt) {
    # Fallback: az computes end date as now + years; close enough for a warning.
    $expiresAt = (Get-Date).AddYears($Years).ToString('yyyy-MM-dd')
}
$data.secret = $newSecret
$data.secretRenewedAt = $stamp
$data.secretExpiresAt = $expiresAt
Set-Secret -Name $Name -Vault $VaultName -Secret $data
Write-Host "[azl renew] vault を更新しました (alias '$Name', 期限 $expiresAt を記録)。"

# --- 6. Delete the previous credential (unless -KeepOld) ---------------------------
if ($KeepOld) {
    Write-Host "[azl renew] -KeepOld 指定のため旧シークレットは残します。"
} elseif ($oldKeyId) {
    $delRes = Invoke-Az @('ad','app','credential','delete','--id',$appId,'--key-id',$oldKeyId)
    if ($delRes.Exit -eq 0) {
        Write-Host "[azl renew] 旧シークレット (keyId=$oldKeyId) を削除しました。"
    } else {
        Write-Host "[azl renew] 旧シークレットの削除に失敗しました (残置)。手動で確認してください。" -ForegroundColor Yellow
    }
} else {
    Write-Host "[azl renew] 旧シークレットを特定できませんでした (残置)。必要なら手動で整理してください。" -ForegroundColor Yellow
}

$newSecret = $null
$data = $null
[GC]::Collect()

Write-Host ""
Write-Host ("[azl renew] 完了。'{0}' のシークレットを更新しました。" -f $Name)
Write-Host "反映確認: azl $Name   (SP ログインに切り替わります)"
exit 0
