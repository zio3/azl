<#
.SYNOPSIS
  List registered azl aliases (secret is never shown).
#>
$ErrorActionPreference = 'Stop'
$VaultName = 'azl'

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

$entries = Get-SecretInfo -Vault $VaultName -ErrorAction SilentlyContinue
if (-not $entries) {
    Write-Host "(no azl aliases registered)"
    exit 0
}

$rows = foreach ($entry in $entries) {
    $name = $entry.Name
    $data = $null
    try {
        $data = Get-Secret -Name $name -Vault $VaultName -AsPlainText -ErrorAction Stop
    } catch { }

    if ($data -isnot [hashtable]) {
        [PSCustomObject]@{
            NAME         = $name
            TENANT       = '(error)'
            SUBSCRIPTION = ''
            EXPIRES      = ''
            APPID        = ''
            SUBID        = ''
        }
        continue
    }

    # Remaining days from the vault-recorded expiry (written by renew/register/rotate)
    $expires = '-'
    if ($data.ContainsKey('secretExpiresAt') -and $data.secretExpiresAt) {
        try {
            $end = [datetime]::ParseExact([string]$data.secretExpiresAt, 'yyyy-MM-dd', $null)
            $days = [math]::Floor(($end - (Get-Date)).TotalDays)
            if ($days -lt 0) {
                $expires = ("期限切れ ({0})" -f $end.ToString('yyyy-MM-dd'))
            } else {
                $expires = ("残り {0} 日 ({1})" -f $days, $end.ToString('yyyy-MM-dd'))
            }
        } catch { $expires = '(invalid)' }
    }

    [PSCustomObject]@{
        NAME         = $name
        TENANT       = [string]$data.tenantName
        SUBSCRIPTION = [string]$data.subscriptionName
        EXPIRES      = $expires
        APPID        = [string]$data.appId
        SUBID        = [string]$data.subscriptionId
    }
    $data = $null
}
[GC]::Collect()

$rows | Format-Table -AutoSize
exit 0
