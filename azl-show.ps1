<#
.SYNOPSIS
  Show vault metadata for an alias (read-only by default).
.DESCRIPTION
  Default: prints only what is stored in the vault, including the recorded
  secret expiry. Performs NO az calls, so the current az login is untouched.

  -Live additionally logs in as the SP to fetch live info (actual credential
  expiry, role assignments). This WILL switch your az session to this SP.
#>
param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Name,
    [switch]$Live
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
    Write-Error "Alias '$Name' not found."
    exit 1
}
if ($data -isnot [hashtable]) {
    Write-Error "Stored secret for '$Name' is not a hashtable."
    exit 1
}

# --- Stored metadata ---
$portalUrl = "https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/Credentials/appId/$([string]$data.appId)"

# Vault-recorded expiry (same source as `azl list` / login-time check)
$expiresDisp = '(not recorded — run azl renew to record it)'
if ($data.ContainsKey('secretExpiresAt') -and $data.secretExpiresAt) {
    try {
        $end = [datetime]::ParseExact([string]$data.secretExpiresAt, 'yyyy-MM-dd', $null)
        $days = [math]::Floor(($end - (Get-Date)).TotalDays)
        if ($days -lt 0) {
            $expiresDisp = ('期限切れ ({0})' -f $end.ToString('yyyy-MM-dd'))
        } else {
            $expiresDisp = ('{0} (残り {1} 日)' -f $end.ToString('yyyy-MM-dd'), $days)
        }
    } catch { $expiresDisp = '(invalid secretExpiresAt in vault)' }
}

$out = [ordered]@{
    name             = $Name
    tenantName       = [string]$data.tenantName
    subscriptionName = [string]$data.subscriptionName
    tenantId         = [string]$data.tenantId
    subscriptionId   = [string]$data.subscriptionId
    appId            = [string]$data.appId
    secret           = if ($data.secret) { '(set)' } else { '(unset)' }
    'secret expires'  = $expiresDisp
    'portal (creds)' = $portalUrl
}
if ($data.ContainsKey('secretRenewedAt') -and $data.secretRenewedAt) {
    $out['secret renewed'] = [string]$data.secretRenewedAt
}
$out.GetEnumerator() | ForEach-Object {
    '{0,-18} : {1}' -f $_.Key, $_.Value
}

if (-not $Live) {
    Write-Host ""
    Write-Host "(vault の情報のみ。ライブ情報 — AD 上の実際の期限・ロール割当 — は 'azl show $Name -Live'。"
    Write-Host " -Live はこの SP でログインし直すため、現在の az ログイン状態が切り替わります)"
    exit 0
}

# --- Live info (-Live only: switches the az session to this SP) ---
Write-Host ""
Write-Host "--- Live info ---"

$azBin = Resolve-AzCli
if (-not $azBin) {
    Write-Host "Azure CLI (az) not found. Skipping live info."
    exit 0
}

$appId  = [string]$data.appId
$tenant = [string]$data.tenantId
$secret = [string]$data.secret
$sub    = [string]$data.subscriptionId

if (-not $appId -or -not $tenant -or -not $secret) {
    Write-Host "Required fields missing; cannot login. Skipping live info."
    exit 0
}

Write-Host "Logging in as SP to fetch live info..."
$loginOut = & $azBin login --service-principal -u $appId -p $secret --tenant $tenant --output none 2>&1
$secret = $null; [GC]::Collect()
if ($LASTEXITCODE -ne 0) {
    Write-Host "Login failed: $loginOut"
    Write-Host "Skipping live info."
    exit 0
}

if ($sub) {
    & $azBin account set --subscription $sub --output none 2>&1 | Out-Null
}

$savedEA = $ErrorActionPreference
$ErrorActionPreference = 'Continue'

# Secret expiration
$credsRaw = $null
$credsExit = 1
try {
    $credsRaw = & $azBin ad app credential list --id $appId --output json 2>$null
    $credsExit = $LASTEXITCODE
} catch {
    $credsExit = 1
}
$ourHint = $null
if ($data.secret) {
    $s = [string]$data.secret
    if ($s.Length -ge 3) { $ourHint = $s.Substring(0, 3) }
}

if ($credsExit -eq 0 -and $credsRaw) {
    $credsJson = ($credsRaw | Out-String)
    $creds = $null
    try { $creds = $credsJson | ConvertFrom-Json } catch { }
    $credsArr = @($creds)
    if ($credsArr.Count -gt 0) {
        $now = Get-Date
        # Match OUR secret by hint (first 3 chars of stored secret)
        $matched = $null
        if ($ourHint) {
            foreach ($c in $credsArr) {
                if ($c.hint -eq $ourHint) { $matched = $c; break }
            }
        }
        if ($matched) {
            try {
                $end = [datetime]$matched.endDateTime
                $days = [math]::Floor(($end - $now).TotalDays)
                $dn = if ($matched.displayName) { $matched.displayName } else { '(no name)' }
                '{0,-18} : {1} ({2} days left) [displayName: {3}]' -f 'secret expires', $end.ToString('yyyy-MM-dd'), $days, $dn
            } catch {
                '{0,-18} : (matched credential has invalid endDateTime)' -f 'secret expires'
            }
        } else {
            '{0,-18} : (could not match stored secret by hint; run ''az ad app credential list --id {1} -o table'')' -f 'secret expires', $appId
        }
        $otherCount = $credsArr.Count - ($(if ($matched) { 1 } else { 0 }))
        if ($otherCount -gt 0) {
            '{0,-18} : {1} credential(s) total on this App Registration' -f 'credentials', $credsArr.Count
        }
    } else {
        '{0,-18} : (credential list empty)' -f 'secret expires'
    }
} else {
    '{0,-18} : (unavailable — no AD read permission)' -f 'secret expires'
}

# Role assignments
$rolesRaw = $null
$rolesExit = 1
try {
    $rolesRaw = & $azBin role assignment list --assignee $appId --all --output json 2>$null
    $rolesExit = $LASTEXITCODE
} catch {
    $rolesExit = 1
}
if ($rolesExit -eq 0 -and $rolesRaw) {
    $rolesJson = ($rolesRaw | Out-String)
    $roles = @()
    try { $roles = @($rolesJson | ConvertFrom-Json) } catch { }
    if ($roles.Count -eq 0) {
        '{0,-18} : (none visible)' -f 'role assignments'
    } else {
        '{0,-18} :' -f 'role assignments'
        foreach ($r in $roles) {
            $roleName = if ($r.roleDefinitionName) { $r.roleDefinitionName } else { '(unknown role)' }
            $scope    = if ($r.scope) { $r.scope } else { '(no scope)' }
            '  - {0,-15} @ {1}' -f $roleName, $scope
        }
    }
} else {
    '{0,-18} : (unavailable — insufficient permission)' -f 'role assignments'
}

$ErrorActionPreference = $savedEA

exit 0
