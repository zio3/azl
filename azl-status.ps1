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

  -Check additionally acquires an ARM token (value never shown) to prove the
  login is actually alive (`az account show` only reads a local file, so an
  expired SP secret or a revoked user session still looks "ok" without it),
  and probes whether a Microsoft Graph token can be obtained silently
  (graph=yes|no; same silent acquisition that `az ad ...` would rely on).

  Exit codes: 0 = logged in (and, with -Check, token alive),
              1 = not logged in / az missing / -Check token acquisition failed.
#>
param(
    [switch]$Json,
    [switch]$Check
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

# '(default:shared)' flags the shared ~/.azure profile: with no AZURE_CONFIG_DIR,
# alias switches in any session affect every other session, and a vanished
# settings entry is otherwise easy to miss.
$sharedProfile = -not $env:AZURE_CONFIG_DIR
$configDir = if ($env:AZURE_CONFIG_DIR) { $env:AZURE_CONFIG_DIR } else { '(default:shared)' }

$azBin = Resolve-AzCli
if (-not $azBin) {
    if ($Json) {
        [pscustomobject]@{ ok = $false; error = 'az-not-found'; configDir = $configDir; sharedProfile = $sharedProfile } | ConvertTo-Json -Compress
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
        [pscustomobject]@{ ok = $false; error = 'not-logged-in'; configDir = $configDir; sharedProfile = $sharedProfile } | ConvertTo-Json -Compress
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

# -Check: actually acquire tokens (silently; values are discarded via --output none).
$tokenOk = $null
$graphOk = $null
if ($Check) {
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $azBin account get-access-token --output none 2>$null
        $tokenOk = ($LASTEXITCODE -eq 0)
        if ($tokenOk) {
            # --tenant is only valid for user accounts (az rejects it for SP logins).
            $graphArgs = @('account','get-access-token','--resource-type','ms-graph','--output','none')
            if ($mode -eq 'user') { $graphArgs += @('--tenant', [string]$acct.tenantId) }
            & $azBin @graphArgs 2>$null
            $graphOk = ($LASTEXITCODE -eq 0)
        } else {
            $graphOk = $false
        }
    } finally {
        $ErrorActionPreference = $prevEAP
    }
}

$checkFailed = ($Check -and -not $tokenOk)

if ($Json) {
    $obj = [ordered]@{
        ok             = (-not $checkFailed)
        alias          = $alias
        mode           = $mode
        signedInAs     = [string]$acct.user.name
        tenantId       = [string]$acct.tenantId
        tenant         = $tenantLabel
        subscription   = [string]$acct.name
        subscriptionId = [string]$acct.id
        configDir      = $configDir
        sharedProfile  = $sharedProfile
    }
    if ($Check) {
        if ($checkFailed) { $obj.error = 'token-failed' }
        $obj.tokenOk = $tokenOk
        $obj.graphOk = $graphOk
    }
    [pscustomobject]$obj | ConvertTo-Json -Compress
} else {
    $head = if ($checkFailed) { 'stale' } else { 'ok' }
    $checkSuffix = ''
    if ($Check) {
        $checkSuffix = (" token={0} graph={1}" -f `
            $(if ($tokenOk) { 'ok' } else { 'failed' }), `
            $(if ($graphOk) { 'yes' } else { 'no' }))
    }
    Write-Host ("azl: {0} alias={1} mode={2} tenant=""{3}"" sub=""{4}"" sub_id={5} config_dir={6}{7}" -f `
        $head, $alias, $mode, $tenantLabel, [string]$acct.name, [string]$acct.id, $configDir, $checkSuffix)
}
if ($checkFailed) { exit 1 }
exit 0
