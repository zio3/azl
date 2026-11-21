<#
.SYNOPSIS
  Ensure the az session is logged in as the given SP alias (idempotent login).
.DESCRIPTION
  "If we are already that alias, do nothing; otherwise log in as it." One call
  replaces the status-then-decide dance, and avoids needless re-logins that
  would disturb other sessions on a shared (default ~/.azure) profile.

  Already-aligned means: SP login whose appId matches the alias, on the alias's
  tenant, and on the alias's subscription (when one is recorded). A user-mode
  login on the same tenant/subscription is NOT accepted by default (the point
  of an SP alias is the SP identity); pass -AllowUser to accept it.

  Output: one status-style line with action=none (unchanged) or action=login
  (switched). Never opens a browser (SP login only).

  Exit codes: 0 = aligned (with or without switching), non-zero = login failed.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Name,
    [switch]$AllowUser
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

$azBin = Resolve-AzCli
if (-not $azBin) {
    Write-Host "azl: error az-not-found"
    exit 1
}

if (-not (Get-Module -ListAvailable Microsoft.PowerShell.SecretManagement)) {
    Write-Host "azl: error secretmanagement-not-installed"
    exit 1
}
Import-Module Microsoft.PowerShell.SecretManagement -ErrorAction Stop

$data = $null
try {
    $data = Get-Secret -Name $Name -Vault $VaultName -AsPlainText -ErrorAction Stop
} catch {
    Write-Host "azl: error alias '$Name' not found. Register it first: azl register"
    exit 1
}
if ($data -isnot [hashtable]) {
    Write-Host "azl: error stored entry for '$Name' is not a hashtable."
    exit 1
}

$storedTenant = [string]$data.tenantId
$storedAppId  = [string]$data.appId
$storedSub    = [string]$data.subscriptionId
$tenantName   = [string]$data.tenantName
$data = $null
[GC]::Collect()

$sharedProfile = -not $env:AZURE_CONFIG_DIR
$configDir = if ($env:AZURE_CONFIG_DIR) { $env:AZURE_CONFIG_DIR } else { '(default:shared)' }

# Same semantics as azl-status.ps1: the vault may store tenantId as GUID or as a
# domain name; only a check that is KNOWN to match counts as aligned (an
# unverifiable domain entry on old az falls through to re-login, which is safe
# because SP login is idempotent).
function Test-TenantVerified {
    param([string]$Stored, $Acct)
    if (-not $Stored) { return $false }
    if ($Stored -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
        return ($Stored -eq [string]$Acct.tenantId)
    }
    $acctDomain = [string]$Acct.tenantDefaultDomain
    if ($acctDomain) { return ($Stored -ieq $acctDomain) }
    return $false
}

function Get-CurrentAccount {
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $showJson = & $azBin account show --output json 2>$null
        $showExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    if ($showExit -ne 0 -or -not $showJson) { return $null }
    try { return (($showJson | Out-String) | ConvertFrom-Json) } catch { return $null }
}

function Write-EnsureLine {
    param($Acct, [string]$Action)
    $mode = 'user'
    if ([string]$Acct.user.type -eq 'servicePrincipal') { $mode = 'sp' }
    $label = if ($tenantName) { $tenantName } else { [string]$Acct.tenantId }
    Write-Host ("azl: ok alias={0} mode={1} tenant=""{2}"" sub=""{3}"" sub_id={4} config_dir={5} action={6}" -f `
        $Name, $mode, $label, [string]$Acct.name, [string]$Acct.id, $configDir, $Action)
}

$acct = Get-CurrentAccount
if ($acct) {
    $mode = 'user'
    if ([string]$acct.user.type -eq 'servicePrincipal') { $mode = 'sp' }
    $tenantOk = Test-TenantVerified -Stored $storedTenant -Acct $acct
    $subOk = (-not $storedSub) -or ($storedSub -eq [string]$acct.id)
    $aligned = $false
    if ($mode -eq 'sp') {
        $aligned = $tenantOk -and $subOk -and $storedAppId -and ([string]$acct.user.name -eq $storedAppId)
    } elseif ($AllowUser) {
        # Caller explicitly accepts a human login in place of the SP, as long as
        # it is on the same tenant (and subscription, when recorded).
        $aligned = $tenantOk -and $subOk
    }
    if ($aligned) {
        Write-EnsureLine -Acct $acct -Action 'none'
        exit 0
    }
}

# Not aligned (or not logged in): unattended SP login via the normal login path
# (secret handling, subscription set, expiry warnings all live there).
& (Join-Path (Split-Path -Parent $PSCommandPath) 'azl-login.ps1') $Name
$loginExit = $LASTEXITCODE
if ($loginExit -ne 0) {
    Write-Host ("azl: ensure-failed alias={0} action=login exit={1}" -f $Name, $loginExit)
    exit $loginExit
}

$acct = Get-CurrentAccount
if (-not $acct) {
    Write-Host ("azl: ensure-failed alias={0} action=login (login ok but 'az account show' failed)" -f $Name)
    exit 1
}
Write-EnsureLine -Acct $acct -Action 'login'
exit 0
