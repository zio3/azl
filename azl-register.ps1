<#
.SYNOPSIS
  Register an azl alias in the 'azl' SecretStore vault.
.DESCRIPTION
  Flow:
    1) Collect tenantId / appId / secret
    2) Validate by actually logging in as the SP
    3) Fetch accessible subscriptions, let user pick one
    4) Ask tenantName (friendly label, after seeing sub context)
    5) Ask alias name, with overwrite prompt
    6) Save to vault. Session remains logged in as the registered SP.
#>
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
    Write-Error "Vault '$VaultName' is not registered. Run setup first."
    exit 1
}

Write-Host "Register a new azl alias."
Write-Host ""

$tenantId = Read-Host "tenantId (GUID or domain)"
if (-not $tenantId) { Write-Error "tenantId is required"; exit 1 }

$appId = Read-Host "appId (SP client id)"
if (-not $appId) { Write-Error "appId is required"; exit 1 }

$secretSecure = Read-Host "secret (hidden)" -AsSecureString
$ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secretSecure)
try {
    $secret = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
} finally {
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
}
if (-not $secret) { Write-Error "secret is required"; exit 1 }

Write-Host ""
Write-Host "Validating credentials by logging in..."
$loginOut = & $azBin login --service-principal -u $appId -p $secret --tenant $tenantId --output none 2>&1
$loginExit = $LASTEXITCODE
if ($loginExit -ne 0) {
    $secret = $null; [GC]::Collect()
    Write-Error "Login failed: $loginOut"
    Write-Host "Please re-run 'azl register' with corrected credentials." -ForegroundColor Yellow
    exit 1
}
Write-Host "Login OK."

Write-Host "Fetching accessible subscriptions..."
$subsRaw = & $azBin account list --output json 2>&1
if ($LASTEXITCODE -ne 0) {
    $secret = $null; [GC]::Collect()
    Write-Error "Failed to list subscriptions: $subsRaw"
    exit 1
}

# Join multi-line output into a single JSON string (needed for PowerShell 5.1)
$subsJson = ($subsRaw | Out-String)
try {
    $parsed = $subsJson | ConvertFrom-Json
} catch {
    $secret = $null; [GC]::Collect()
    Write-Error "Failed to parse subscription list JSON: $_"
    exit 1
}
# Filter to subscriptions actually accessed by the CURRENT SP login.
# az CLI caches past logins and account list includes them, so this keeps us
# from picking a sub that only appears via a cached identity.
$allSubs = @($parsed)
$subs = @($allSubs | Where-Object { $_.user -and $_.user.name -eq $appId })
if ($subs.Count -eq 0) {
    $secret = $null; [GC]::Collect()
    if ($allSubs.Count -gt 0) {
        Write-Error "No subscriptions accessible by SP '$appId'. (Cached subs from other identities were ignored.)"
    } else {
        Write-Error "No accessible subscriptions for this SP. Assign an RBAC role at the subscription scope."
    }
    exit 1
}

Write-Host ""
Write-Host "Available subscriptions:"
$defaultIndex = 1
for ($i = 0; $i -lt $subs.Count; $i++) {
    $s = $subs[$i]
    $marker = if ($s.isDefault) { ' [default]' } else { '' }
    if ($s.isDefault) { $defaultIndex = $i + 1 }
    Write-Host ("  {0}) {1}  ({2}){3}" -f ($i + 1), $s.name, $s.id, $marker)
}
Write-Host ""

$sel = Read-Host "Select subscription [$defaultIndex]"
if (-not $sel) { $sel = "$defaultIndex" }
$selInt = 0
if (-not [int]::TryParse($sel, [ref]$selInt) -or $selInt -lt 1 -or $selInt -gt $subs.Count) {
    $secret = $null; [GC]::Collect()
    Write-Error "Invalid selection: $sel"
    exit 1
}
$chosenSub = $subs[$selInt - 1]

# Set the chosen subscription as default in the current session too
& $azBin account set --subscription $chosenSub.id --output none 2>&1 | Out-Null

Write-Host ""
$tenantName = Read-Host "tenantName (friendly label, Enter to use tenantId)"
if (-not $tenantName) { $tenantName = $tenantId }

# Optional expiry: lets 'azl <name>' warn about expiration offline (the SP itself
# usually cannot read its own credentials via Graph).
$secretExpiresAt = $null
$expIn = Read-Host "secret expiry date YYYY-MM-DD (optional, Enter to skip)"
if ($expIn) {
    try {
        $secretExpiresAt = ([datetime]::ParseExact($expIn, 'yyyy-MM-dd', $null)).ToString('yyyy-MM-dd')
    } catch {
        Write-Host "Unrecognized date '$expIn'; expiry will not be recorded." -ForegroundColor Yellow
    }
}

# Alias name is always asked at the end (positional not accepted)
$reservedNames = @('help', 'login', 'list', 'show', 'register', 'rotate', 'renew', 'remove')
$Name = $null
while ($true) {
    $Name = Read-Host "Alias name"
    if (-not $Name) {
        Write-Host "Alias name is required. (Ctrl-C to cancel)"
        continue
    }
    if ($Name.StartsWith('-')) {
        Write-Host "Alias name cannot start with '-'. Please choose another."
        $Name = $null
        continue
    }
    if ($reservedNames -contains $Name) {
        Write-Host ("Note: '{0}' is also a subcommand name. The shortcut 'azl {0}' will run the '{0}' subcommand, not this alias." -f $Name)
        Write-Host ("To login with this alias you must type: azl login {0}" -f $Name)
        $resp = Read-Host "Use this name anyway? (y/N)"
        if ($resp -notmatch '^[yY]') {
            $Name = $null
            continue
        }
    }
    $existing = Get-SecretInfo -Name $Name -Vault $VaultName -ErrorAction SilentlyContinue
    if ($existing) {
        $resp = Read-Host "Alias '$Name' already exists. Overwrite? (y/N)"
        if ($resp -notmatch '^[yY]') {
            $Name = $null
            continue
        }
    }
    break
}

$data = @{
    appId            = $appId
    tenantId         = $tenantId
    tenantName       = $tenantName
    secret           = $secret
    subscriptionId   = $chosenSub.id
    subscriptionName = $chosenSub.name
}
if ($secretExpiresAt) { $data.secretExpiresAt = $secretExpiresAt }

Set-Secret -Name $Name -Vault $VaultName -Secret $data

$secret = $null
$data = $null
[GC]::Collect()

Write-Host ""
Write-Host ("[azl register] Registered '{0}' ({1} / {2})" -f $Name, $tenantName, $chosenSub.name)
Write-Host "Session is logged in as this SP. You can run 'az ...' commands now."
exit 0
