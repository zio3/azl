<#
.SYNOPSIS
  One-shot initial setup for SP alias storage (SecretManagement + SecretStore).
.DESCRIPTION
  Automates the README's manual steps: install the two modules, register the
  'azl' vault, put SecretStore into non-interactive mode, and self-test a
  write/read/delete. Idempotent: every step is skipped when already done.

  NOT needed for plain `azl` (assisted user login) — only SP aliases use the vault.

  Safety rails (deliberate):
    - Reset-SecretStore WIPES the whole SecretStore. If the store already holds
      any secret (azl's or anyone else's), setup STOPS instead of resetting.
    - -DefaultVault is only passed when the user has no other vault registered,
      so setup never steals someone's default vault.
    - Must run in Windows PowerShell 5.1 (the shims do this): installing the
      modules from pwsh 7 puts them where azl (powershell.exe) cannot see them.
    - Interactive by design (confirmation prompt before the reset); refuses to
      run in a non-interactive shell.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$VaultName = 'azl'

function Say  { param([string]$Msg) Write-Host "[azl setup] $Msg" }
function Warn { param([string]$Msg) Write-Host "[azl setup WARN] $Msg" -ForegroundColor Yellow }

Say "SP エイリアス用の SecretStore 初期設定を行います"
Say "(引数なしの 'azl' 本人ログインだけを使う場合、この設定は不要です)"

Say ("PowerShell {0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    Warn "Windows PowerShell 5.1 (powershell.exe) で実行してください。pwsh 7 で入れたモジュールは azl から見えません。"
    Warn "通常は 'azl setup'(shim 経由)で実行すれば自動的に 5.1 になります。"
    exit 1
}

# Interactive by design: the SecretStore reset below asks for confirmation.
if ([Console]::IsInputRedirected -or -not [Environment]::UserInteractive) {
    Say "非対話セッションでは実行できません (確認プロンプトを使います)。人がターミナルで 'azl setup' を実行してください。"
    exit 2
}

# --- 1. Modules -------------------------------------------------------------
foreach ($mod in @('Microsoft.PowerShell.SecretManagement', 'Microsoft.PowerShell.SecretStore')) {
    if (Get-Module -ListAvailable $mod) {
        Say "モジュール ${mod}: インストール済み"
    } else {
        Say "モジュール ${mod}: インストールします (Install-Module -Scope CurrentUser)..."
        Install-Module $mod -Scope CurrentUser -Force -AllowClobber
        Say "モジュール ${mod}: インストールしました"
    }
}
Import-Module Microsoft.PowerShell.SecretManagement -ErrorAction Stop
Import-Module Microsoft.PowerShell.SecretStore -ErrorAction Stop

# --- 2. Vault registration --------------------------------------------------
$vault = Get-SecretVault -Name $VaultName -ErrorAction SilentlyContinue
if ($vault) {
    if ($vault.ModuleName -ne 'Microsoft.PowerShell.SecretStore') {
        Warn "vault '$VaultName' は別モジュール ($($vault.ModuleName)) で登録済みです。azl は SecretStore を想定しています。"
        exit 1
    }
    Say "vault '$VaultName': 登録済み"
} else {
    # Don't silently change the user's default vault: only claim default when
    # they have no vault at all yet.
    $others = @(Get-SecretVault -ErrorAction SilentlyContinue)
    $makeDefault = ($others.Count -eq 0)
    Register-SecretVault -Name $VaultName -ModuleName Microsoft.PowerShell.SecretStore -DefaultVault:$makeDefault
    if ($makeDefault) {
        Say "vault '$VaultName': 登録しました (既定の vault に設定)"
    } else {
        Say "vault '$VaultName': 登録しました (既存の vault があるため既定は変更していません)"
    }
}

# --- 3. SecretStore non-interactive mode -------------------------------------
$cfg = $null
try { $cfg = Get-SecretStoreConfiguration -ErrorAction Stop } catch { }
if ($cfg -and [string]$cfg.Authentication -eq 'None' -and [string]$cfg.Interaction -eq 'None') {
    Say "SecretStore: 非対話モード設定済み (Authentication=None, Interaction=None)"
} else {
    # Reset-SecretStore wipes EVERYTHING in the store, azl's and anyone else's.
    # Refuse when content exists (or when we cannot prove it is empty, e.g. a
    # password-locked store we failed to enumerate).
    $existing = 0
    $enumFailed = $false
    foreach ($v in @(Get-SecretVault | Where-Object { $_.ModuleName -eq 'Microsoft.PowerShell.SecretStore' })) {
        try {
            $existing += @(Get-SecretInfo -Vault $v.Name -ErrorAction Stop).Count
        } catch {
            $enumFailed = $true
        }
    }
    if ($existing -gt 0 -or $enumFailed) {
        if ($enumFailed) {
            Warn "SecretStore の中身を確認できませんでした (パスワード保護中の可能性)。"
        } else {
            Warn "SecretStore に既存のシークレットが $existing 件あります。"
        }
        Warn "Reset-SecretStore は SecretStore の中身をすべて消すため、ここで中断します。"
        Warn "中身を確認・退避したうえで、手動で次を実行してください:"
        Warn "  Reset-SecretStore -Authentication None -Interaction None -Scope CurrentUser"
        exit 1
    }
    Say "SecretStore を非対話モードに初期化します (Authentication=None, Interaction=None)"
    Say "※ 現在の SecretStore は空です。初期化してもデータは失われません。"
    $ans = Read-Host "よろしいですか? [y/N]"
    if ($ans -notin @('y', 'Y', 'yes', 'YES')) {
        Say "中断しました。"
        exit 1
    }
    Reset-SecretStore -Authentication None -Interaction None -Scope CurrentUser -Force
    Say "SecretStore: 非対話モードに初期化しました"
}

# --- 4. Self-test: write / read / delete -------------------------------------
Say "動作確認 (テストシークレットの書込/読取/削除)..."
$testName = 'azl-setup-selftest'
Set-Secret -Name $testName -Secret 'ok' -Vault $VaultName
$readBack = Get-Secret -Name $testName -Vault $VaultName -AsPlainText
Remove-Secret -Name $testName -Vault $VaultName
if ($readBack -ne 'ok') {
    Warn "動作確認に失敗しました (読み戻した値が一致しません)。"
    exit 1
}
Say "動作確認 OK"

Write-Host ""
Say "セットアップ完了。次の手順:"
Say "  1. SP を作成:  az ad sp create-for-rbac --name <名前> --role <最小ロール> --scopes /subscriptions/<sub-id>"
Say "  2. 登録:      azl register   (appId / tenantId / secret を貼り付け)"
Say "  3. ログイン:   azl <alias>"
Say "確認コマンド:   azl doctor"
exit 0
