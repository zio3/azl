<#
.SYNOPSIS
  List registered azl aliases (secret is never shown).
.DESCRIPTION
  -Json emits one JSON array with full (untruncated) values — the table view
  can clip long columns such as SUBID in narrow non-interactive shells.
#>
param(
    [switch]$Json
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
    Write-Error "Vault '$VaultName' is not registered. Run setup first."
    exit 1
}

$entries = Get-SecretInfo -Vault $VaultName -ErrorAction SilentlyContinue
if (-not $entries) {
    if ($Json) { Write-Host '[]' } else { Write-Host "(no azl aliases registered)" }
    exit 0
}

$rows = foreach ($entry in $entries) {
    $name = $entry.Name
    $data = $null
    try {
        $data = Get-Secret -Name $name -Vault $VaultName -AsPlainText -ErrorAction Stop
    } catch { }

    if ($data -isnot [hashtable]) {
        [PSCustomObject]([ordered]@{
            name             = $name
            tenantName       = '(error)'
            subscriptionName = ''
            secretExpiresAt  = ''
            daysLeft         = $null
            appId            = ''
            subscriptionId   = ''
        })
        continue
    }

    # Remaining days from the vault-recorded expiry (written by renew/register/rotate)
    $expiresAt = ''
    $daysLeft = $null
    if ($data.ContainsKey('secretExpiresAt') -and $data.secretExpiresAt) {
        $expiresAt = [string]$data.secretExpiresAt
        try {
            $end = [datetime]::ParseExact($expiresAt, 'yyyy-MM-dd', $null)
            $daysLeft = [int][math]::Floor(($end - (Get-Date)).TotalDays)
        } catch { }
    }

    [PSCustomObject]([ordered]@{
        name             = $name
        tenantName       = [string]$data.tenantName
        subscriptionName = [string]$data.subscriptionName
        secretExpiresAt  = $expiresAt
        daysLeft         = $daysLeft
        appId            = [string]$data.appId
        subscriptionId   = [string]$data.subscriptionId
    })
    $data = $null
}
[GC]::Collect()

if ($Json) {
    # -InputObject keeps a 0/1-element array an array on PS 5.1.
    Write-Host (ConvertTo-Json -InputObject @($rows) -Compress)
    exit 0
}

$table = foreach ($r in $rows) {
    $expires = '-'
    if ($r.tenantName -eq '(error)') {
        $expires = ''
    } elseif ($r.secretExpiresAt) {
        if ($null -eq $r.daysLeft) {
            $expires = '(invalid)'
        } elseif ($r.daysLeft -lt 0) {
            $expires = ("期限切れ ({0})" -f $r.secretExpiresAt)
        } else {
            $expires = ("残り {0} 日 ({1})" -f $r.daysLeft, $r.secretExpiresAt)
        }
    }
    [PSCustomObject]([ordered]@{
        NAME         = $r.name
        TENANT       = $r.tenantName
        SUBSCRIPTION = $r.subscriptionName
        EXPIRES      = $expires
        APPID        = $r.appId
        SUBID        = $r.subscriptionId
    })
}

# Out-String -Width: Format-Table clips long columns (e.g. SUBID GUIDs) at the
# console width, which is narrow in non-interactive LLM/CI shells.
($table | Format-Table -AutoSize | Out-String -Width 512).TrimEnd() | Write-Host
exit 0
