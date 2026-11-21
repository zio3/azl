<#
.SYNOPSIS
  Rotate the SP client secret for an existing azl alias.
.DESCRIPTION
  Prompts for a new secret, validates it by logging in as the SP,
  and overwrites only the 'secret' field on success. All other
  fields (appId / tenantId / subscriptionId / ...) are preserved.
#>
param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Name
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
$sub        = [string]$data.subscriptionId
$tenantName = [string]$data.tenantName
$subName    = [string]$data.subscriptionName

Write-Host "Rotate SP secret for alias '$Name' ($tenantName / $subName)."

$newSecretSecure = Read-Host "new secret (hidden)" -AsSecureString
$ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($newSecretSecure)
try {
    $newSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
} finally {
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
}
if (-not $newSecret) { Write-Error "secret is required"; exit 1 }

Write-Host ""
Write-Host "Validating new secret by logging in..."
$loginOut = & $azBin login --service-principal -u $appId -p $newSecret --tenant $tenant --output none 2>&1
if ($LASTEXITCODE -ne 0) {
    $newSecret = $null; [GC]::Collect()
    Write-Error "Login failed with the new secret: $loginOut"
    Write-Host "Stored secret was NOT changed. Verify the new secret is correct." -ForegroundColor Yellow
    exit 1
}
Write-Host "Login OK."

if ($sub) {
    & $azBin account set --subscription $sub --output none 2>&1 | Out-Null
}

# Optional expiry of the received secret: lets 'azl <name>' warn offline.
$expIn = Read-Host "secret expiry date YYYY-MM-DD (optional, Enter to skip)"
$secretExpiresAt = $null
if ($expIn) {
    try {
        $secretExpiresAt = ([datetime]::ParseExact($expIn, 'yyyy-MM-dd', $null)).ToString('yyyy-MM-dd')
    } catch {
        Write-Host "Unrecognized date '$expIn'; expiry will not be recorded." -ForegroundColor Yellow
    }
}

# Update the secret (and expiry bookkeeping); preserve other fields
$data.secret = $newSecret
if ($secretExpiresAt) {
    $data.secretExpiresAt = $secretExpiresAt
} elseif ($data.ContainsKey('secretExpiresAt')) {
    # Old expiry belongs to the previous secret; drop it rather than mislead.
    $data.Remove('secretExpiresAt')
}
if ($data.ContainsKey('secretKeyId')) {
    # The recorded keyId identifies the previous credential; after a manual rotate
    # we no longer know our credential's keyId, so drop it (renew re-records it).
    $data.Remove('secretKeyId')
}
Set-Secret -Name $Name -Vault $VaultName -Secret $data

$newSecret = $null
$data = $null
[GC]::Collect()

Write-Host ""
Write-Host ("[azl rotate] Secret rotated for '{0}' ({1} / {2})." -f $Name, $tenantName, $subName)
Write-Host "Session is logged in with the new secret."
exit 0
