<#
.SYNOPSIS
  Show the current az login state as one line (never changes login state).
.DESCRIPTION
  Reads `az account show` and reverse-maps the signed-in identity to a registered
  azl alias (SP login: by appId, user login: by tenantId). Read-only: performs no
  login and no `az account set`.

  Output (plain):
    azl: ok alias=<name|-> mode=<sp|user> tenant="<label>" sub="<name>" sub_id=<id> config_dir=<dir|(default)>
  Output (-Json): the same fields as a single JSON object.

  Exit codes: 0 = logged in, 1 = not logged in (or az missing).
#>
param(
    [switch]$Json
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

$configDir = if ($env:AZURE_CONFIG_DIR) { $env:AZURE_CONFIG_DIR } else { '(default)' }

$azBin = Resolve-AzCli
if (-not $azBin) {
    if ($Json) {
        [pscustomobject]@{ ok = $false; error = 'az-not-found'; configDir = $configDir } | ConvertTo-Json -Compress
    } else {
        Write-Host "azl: error az-not-found"
    }
    exit 1
}

$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $showJson = & $azBin account show --output json 2>$null
    $showExit = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $prevEAP
}
$acct = $null
if ($showExit -eq 0 -and $showJson) {
    try { $acct = ($showJson | Out-String) | ConvertFrom-Json } catch { $acct = $null }
}

if (-not $acct) {
    if ($Json) {
        [pscustomobject]@{ ok = $false; error = 'not-logged-in'; configDir = $configDir } | ConvertTo-Json -Compress
    } else {
        Write-Host ("azl: not-logged-in config_dir={0}" -f $configDir)
    }
    exit 1
}

$mode = 'user'
if ([string]$acct.user.type -eq 'servicePrincipal') { $mode = 'sp' }

# Vault entries may store tenantId as a GUID or as a domain name (azl register
# accepts both). `az account show` reports a GUID in tenantId and, on az 2.61+,
# the domain in tenantDefaultDomain; compare in whichever form the entry uses.
# Returns 'verified' (known to match), 'unverified' (domain entry that cannot be
# checked on this az version) or '' (known not to match). An unverified candidate
# must never outrank a verified one.
function Test-TenantMatch {
    param([string]$Stored, $Acct)
    if (-not $Stored) { return '' }
    if ($Stored -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
        if ($Stored -eq [string]$Acct.tenantId) { return 'verified' }
        return ''
    }
    $acctDomain = [string]$Acct.tenantDefaultDomain
    if ($acctDomain) {
        if ($Stored -ieq $acctDomain) { return 'verified' }
        return ''
    }
    # Domain-name entry but az is too old to report the domain: cannot verify.
    return 'unverified'
}

# Reverse-map the signed-in identity to a registered alias.
# SP login: the same appId can be registered under several aliases (multi-tenant SP,
# or per-subscription aliases), so match appId + tenantId and prefer the alias whose
# subscriptionId is the active one. User login: best effort by tenantId.
# '-' when nothing matches.
$alias = '-'
$tenantLabel = [string]$acct.tenantId
if (Get-Module -ListAvailable Microsoft.PowerShell.SecretManagement) {
    Import-Module Microsoft.PowerShell.SecretManagement -ErrorAction SilentlyContinue
    $entries = @(Get-SecretInfo -Vault $VaultName -ErrorAction SilentlyContinue)
    # Candidate tiers, best first. A verified tenant match always outranks an
    # unverified one (domain entry that this az version cannot check); within a
    # tier, a subscriptionId match outranks no sub match; within that, first wins.
    $tiers = @{ verifiedSub = $null; verified = $null; unverifiedSub = $null; unverified = $null }
    foreach ($entry in $entries) {
        $d = $null
        try { $d = Get-Secret -Name $entry.Name -Vault $VaultName -AsPlainText -ErrorAction Stop } catch { }
        if ($d -isnot [hashtable]) { continue }
        $tenantRank = Test-TenantMatch -Stored ([string]$d.tenantId) -Acct $acct
        $isCandidate = $false
        if ($mode -eq 'sp') {
            $isCandidate = ($tenantRank -ne '') -and ([string]$d.appId -eq [string]$acct.user.name)
        } else {
            $isCandidate = ($tenantRank -ne '')
        }
        if ($isCandidate) {
            $cand = @{ Name = $entry.Name; TenantName = [string]$d.tenantName }
            $subHit = ([string]$d.subscriptionId -eq [string]$acct.id)
            if ($tenantRank -eq 'verified') {
                if ($subHit) {
                    $tiers.verifiedSub = $cand
                    $d = $null
                    break   # cannot be beaten
                }
                if (-not $tiers.verified) { $tiers.verified = $cand }
            } else {
                if ($subHit) {
                    if (-not $tiers.unverifiedSub) { $tiers.unverifiedSub = $cand }
                } elseif (-not $tiers.unverified) {
                    $tiers.unverified = $cand
                }
            }
        }
        $d = $null
    }
    $match = $null
    foreach ($tier in @('verifiedSub','verified','unverifiedSub','unverified')) {
        if ($tiers[$tier]) { $match = $tiers[$tier]; break }
    }
    if ($match) {
        $alias = $match.Name
        if ($match.TenantName) { $tenantLabel = $match.TenantName }
    }
}
[GC]::Collect()

if ($Json) {
    [pscustomobject]([ordered]@{
        ok             = $true
        alias          = $alias
        mode           = $mode
        signedInAs     = [string]$acct.user.name
        tenantId       = [string]$acct.tenantId
        tenant         = $tenantLabel
        subscription   = [string]$acct.name
        subscriptionId = [string]$acct.id
        configDir      = $configDir
    }) | ConvertTo-Json -Compress
} else {
    Write-Host ("azl: ok alias={0} mode={1} tenant=""{2}"" sub=""{3}"" sub_id={4} config_dir={5}" -f `
        $alias, $mode, $tenantLabel, [string]$acct.name, [string]$acct.id, $configDir)
}
exit 0
