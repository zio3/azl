<#
.SYNOPSIS
  Remove an azl alias from the vault.
#>
param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Name,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$VaultName = 'azl'

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

$info = Get-SecretInfo -Name $Name -Vault $VaultName -ErrorAction SilentlyContinue
if (-not $info) {
    Write-Error "Alias '$Name' not found."
    exit 1
}

if (-not $Force) {
    $resp = Read-Host "Remove alias '$Name'? (y/N)"
    if ($resp -notmatch '^[yY]') {
        Write-Host "Cancelled."
        exit 0
    }
}

Remove-Secret -Name $Name -Vault $VaultName

Write-Host "[azl-remove] Removed '$Name'."
exit 0
