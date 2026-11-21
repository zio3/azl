<#
.SYNOPSIS
  Diagnose the azl environment (read-only; changes nothing, prompts nothing).
.DESCRIPTION
  Checks everything an SP alias login needs and prints one line per item:
    [ok] fine   [NG] broken (fix hint follows)   [--] informational
  Exit codes: 0 = no [NG], 1 = at least one [NG].

  Designed so that a remote user can paste its output and the conversation is
  over in one round-trip.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$VaultName = 'azl'
$failures = 0

function Ok   { param([string]$Msg) Write-Host "[ok] $Msg" }
function Info { param([string]$Msg) Write-Host "[--] $Msg" }
function Bad  { param([string]$Msg) Write-Host "[NG] $Msg" -ForegroundColor Yellow; $script:failures++ }

# --- PowerShell -------------------------------------------------------------
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    Ok ("PowerShell: {0} (Desktop / powershell.exe)" -f $PSVersionTable.PSVersion)
} else {
    Bad ("PowerShell: {0} ({1}) — azl は Windows PowerShell 5.1 で動く前提です。shim (azl.cmd / bin/azl) 経由で実行してください" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
}

# --- Azure CLI --------------------------------------------------------------
$azCmd = $null
foreach ($candidate in @('az', 'az.cmd')) {
    $c = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($c) { $azCmd = $c; break }
}
if ($azCmd) {
    Ok ("Azure CLI: {0}" -f $azCmd.Source)
} else {
    Bad "Azure CLI: 見つかりません → winget install Microsoft.AzureCLI"
}

# --- Modules ----------------------------------------------------------------
$haveSecretMgmt = $false
foreach ($mod in @('Microsoft.PowerShell.SecretManagement', 'Microsoft.PowerShell.SecretStore')) {
    $found = Get-Module -ListAvailable $mod | Sort-Object Version -Descending | Select-Object -First 1
    if ($found) {
        Ok ("モジュール {0}: {1}" -f $mod, $found.Version)
        if ($mod -eq 'Microsoft.PowerShell.SecretManagement') { $haveSecretMgmt = $true }
    } else {
        Bad ("モジュール {0}: 未インストール → azl setup" -f $mod)
    }
}

# --- Vault + SecretStore configuration ---------------------------------------
if ($haveSecretMgmt) {
    Import-Module Microsoft.PowerShell.SecretManagement -ErrorAction SilentlyContinue
    $vault = Get-SecretVault -Name $VaultName -ErrorAction SilentlyContinue
    if ($vault) {
        Ok ("vault '{0}': 登録済み (module={1})" -f $VaultName, $vault.ModuleName)
    } else {
        Bad ("vault '{0}': 未登録 → azl setup (SP エイリアスを使う場合のみ必要)" -f $VaultName)
    }

    $cfg = $null
    if (Get-Module -ListAvailable Microsoft.PowerShell.SecretStore) {
        Import-Module Microsoft.PowerShell.SecretStore -ErrorAction SilentlyContinue
        try { $cfg = Get-SecretStoreConfiguration -ErrorAction Stop } catch { }
    }
    if ($cfg) {
        if ([string]$cfg.Authentication -eq 'None' -and [string]$cfg.Interaction -eq 'None') {
            Ok "SecretStore: Authentication=None, Interaction=None (非対話で使える)"
        } else {
            Bad ("SecretStore: Authentication={0}, Interaction={1} — 非対話ログインが止まります → azl setup (既存の中身がある場合は手動対応)" -f $cfg.Authentication, $cfg.Interaction)
        }
    } elseif ($vault) {
        Bad "SecretStore: 設定を読めませんでした → azl setup"
    }

    if ($vault) {
        $aliasCount = @(Get-SecretInfo -Vault $VaultName -ErrorAction SilentlyContinue).Count
        if ($aliasCount -gt 0) {
            Ok ("エイリアス: {0} 件 (一覧は azl list)" -f $aliasCount)
        } else {
            Info "エイリアス: 0 件 (azl register で登録)"
        }
    }
}

# --- AZURE_CONFIG_DIR --------------------------------------------------------
if ($env:AZURE_CONFIG_DIR) {
    Ok ("AZURE_CONFIG_DIR: {0}" -f $env:AZURE_CONFIG_DIR)
} else {
    # Not a failure: a single-session machine is fine on the shared default.
    Info "AZURE_CONFIG_DIR: 未設定 (共有 ~/.azure)。複数セッション併用時は README「複数セッションでの併用」参照"
}

Write-Host ""
if ($failures -eq 0) {
    Write-Host "azl doctor: 問題なし"
    exit 0
}
Write-Host ("azl doctor: {0} 件の問題" -f $failures)
exit 1
