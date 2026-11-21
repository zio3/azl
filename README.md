# azl — Azure CLI ログインアシスタント

Claude Code（および任意のCLI環境）から、**正しいテナント/サブスクリプションに確実にログインした状態を作る**ためのスクリプト群。ルートは2つ:

- **`azl`** — Assisted login。本人でサインインし、所属テナント一覧(名前+ドメイン表示)から選んで確定。対話作業向け
- **`azl <name>`** — SPエイリアスログイン。完全非対話。LLM/CI などの無人実行向け。シークレットは **PowerShell SecretStore (DPAPI 暗号化)** に保管

> **Repo**: https://github.com/zio3/azl  
> **Last Updated**: 2026-11-21

## 背景と目的

- Claude CodeにAzureの制御・デプロイ等を任せたい
- `az login` のブラウザ認証 + 複数テナント運用は自動化しづらい(トークン失効・テナントID指定漏れ・`AccountUnusable` 多発)
- 特に多数テナント所属のアカウントでは `az login` がデフォルトで使えるテナントを特定できず、毎回 `az login --tenant <ID>` を要求される
- サービスプリンシパル(SP)なら完全コマンドベースで完結する
- SPシークレットを **PowerShell SecretStore(DPAPI 暗号化)** に保管し、エイリアス名だけで呼び出せるようにする

## 全体設計

```
Claude Code (bash / git bash)
   └─ azl <name>                     ← bashラッパー
       └─ powershell.exe azl.ps1 <name>
           ├─ Get-Secret -Name <name> -Vault azl -AsPlainText
           │     └─ Hashtable { appId, tenantId, secret, subscriptionId, displayName, note }
           ├─ az login --service-principal -u ... -p ... --tenant ...
           └─ (subscriptionId があれば) az account set --subscription ...
```

- シークレットは bash の `$VAR` / プロセス引数 / 履歴に露出しない(PowerShell から az へ直接渡す。ただし `az login` 実行中の数秒間は az プロセスの引数に載る — 「守れないこと」参照)
- bash側には成功/失敗だけ戻す
- 以降は通常の `az` コマンドがそのまま使える

## データ構造

**Vault 名:** `azl` (Microsoft.PowerShell.SecretStore)

**Secret 1件 = Hashtable**:

| キー | 必須 | 内容 |
|---|---|---|
| `appId` | ✅ | SP の client id |
| `tenantId` | ✅ | テナント ID |
| `secret` | ✅ | SP client secret |
| `subscriptionId` | 任意 | 既定にしたいサブスク ID (あれば `az account set` 自動実行) |
| `displayName` | 任意 | `azl list` 表示用の人間向けラベル |
| `note` | 任意 | 自由記述 |

## 提供コマンド

エントリポイントは `azl` 1 本。

| コマンド | 用途 |
|---|---|
| **`azl`** | **Assisted login: 本人でサインインし、テナント一覧(名前+ドメイン)から選択 → サブスク選択まで誘導** |
| `azl -Graph` | Assisted login + Graph スコープ取得(`az ad ...` がそのまま使える) |
| `azl <name>` | 指定エイリアスでSPログイン(非対話。LLM/CI 向け) |
| `azl login <name>` | 同上(明示形) |
| `azl <name> -Verbose` | ログイン(進捗フル表示) |
| `azl list` | 登録済みエイリアスを表示(**シークレットは出さない**) |
| `azl status` | 現在のログイン状態を1行表示(エイリアス逆引き・`-Json` あり。**ログイン状態を変えない**) |
| `azl show <name>` | vault のメタ情報を表示(**シークレットは出さない**)。`-Live` で AD 上の実期限・ロール割当も取得(**SP ログインに切り替わる**) |
| `azl register` | エイリアスを新規登録(全フィールドを対話入力、最後に alias 名) |
| `azl rotate <name>` | SP シークレットのローテ(受領した新secret→検証→secret フィールドのみ書換) |
| `azl renew <name>` | SP シークレットを自動生成して更新(要 `azl <name> -Graph` + App管理権限) |
| `azl remove <name>` | エイリアス削除 |
| `azl -help` | ヘルプ表示 |

**設計方針**: azl は「正しく認証済みの状態を作る」薄い層に徹する。SP の新規作成やロール割当などの管理操作は、ログイン後に素の `az ...`(LLM と対話しながらでも)で行う — azl は個々の管理機能を抱え込まない。

## ファイル構成

```
azl/
  ├─ README.md              # このファイル
  ├─ azl.ps1                # ディスパッチャ
  ├─ azl-assisted.ps1       # assisted login(本人・テナント/サブスク選択)
  ├─ azl-login.ps1          # SPエイリアスログイン(+ -User / -Graph)
  ├─ azl-register.ps1       # 登録
  ├─ azl-rotate.ps1         # secret ローテ(手動貼り付け)
  ├─ azl-renew.ps1          # secret 自動更新(Graph)
  ├─ azl-list.ps1           # 一覧
  ├─ azl-status.ps1         # 現在のログイン状態の1行表示(読み取り専用)
  ├─ azl-remove.ps1         # 削除
  ├─ azl-show.ps1           # メタ情報表示(-Live でライブ情報)
  └─ bin\
      ├─ azl                # bash shim
      └─ azl.cmd            # cmd shim
```

`bin/` をユーザーの PATH に追加(例: `~/.bashrc` に `export PATH="$HOME/source/azl/bin:$PATH"`)。
個別の ps1 はコマンドラインから直接呼ぶ必要はなく、`azl <subcommand>` 経由で使う。

## 依存

### PowerShell モジュール

Microsoft 公式の 2 つのモジュールを使用:

- `Microsoft.PowerShell.SecretManagement` — vault 抽象化レイヤー
- `Microsoft.PowerShell.SecretStore` — ローカル暗号化ストア実装

```powershell
Install-Module Microsoft.PowerShell.SecretManagement, Microsoft.PowerShell.SecretStore -Scope CurrentUser -Force
```

### Azure CLI

- `az` コマンドがPATHに通っていること (`winget install Microsoft.AzureCLI` 等)

## 初期セットアップ

### 0. リポジトリ取得と PATH 通し

```bash
git clone https://github.com/zio3/azl.git
# or: gh repo clone zio3/azl
cd azl
```

`bin/` を PATH に通すと `azl` をどこからでも呼べる(bash / PowerShell 双方に shim あり):

```powershell
# PowerShell(現在のユーザーの永続 PATH に追加)
$binPath = (Resolve-Path .\bin).Path
[Environment]::SetEnvironmentVariable(
  'Path',
  [Environment]::GetEnvironmentVariable('Path','User') + ';' + $binPath,
  'User')
# 反映は新しいシェルから
```

> Windows ネイティブは `bin/azl.cmd`、bash(git bash 等)は `bin/azl`(LF 固定)が使われる。
> どちらも `azl.ps1` ディスパッチャに委譲するだけの薄い shim。

### 1. モジュールインストール

```powershell
Install-Module Microsoft.PowerShell.SecretManagement, Microsoft.PowerShell.SecretStore -Scope CurrentUser -Force
```

### 2. Vault の登録と非対話モード設定

```powershell
# Vault 登録(デフォルト vault として)
Register-SecretVault -Name azl -ModuleName Microsoft.PowerShell.SecretStore -DefaultVault

# SecretStore を非対話運用にリセット(パスワード保護なし)
Reset-SecretStore -Authentication None -Interaction None -Scope CurrentUser -Force -PassThru
```

- `Authentication None`: ストア解錠にパスワードを要求しない
- `Interaction None`: 対話プロンプトを出さない

Claude Code から非対話で呼ぶためこの設定が必須。マルウェア防御が目的ではなく「平文保存・git事故の防止」が目的のため、許容できるトレードオフ。

### 3. SP 作成

```bash
az ad sp create-for-rbac --name "claude-code-work" --role Contributor \
  --scopes /subscriptions/<sub-id>
```

出力の `appId` / `password` / `tenant` を控える。**ロールは必要最小限** (Reader や特定 RG 限定の Contributor など) を推奨。

### 4. エイリアス登録

```bash
azl register
```

対話プロンプトに appId / tenantId / secret / subscriptionId / displayName / note を入力。

## 日常利用

```bash
azl work                       # ログイン
azl status                     # いまどのエイリアス/テナントか1行で確認
az group list -o table         # 以降、普通に az が使える
az deployment group create ... # デプロイもそのまま
```

## 複数セッションでの併用(AZURE_CONFIG_DIR)

az はログイン状態を既定で `~/.azure` の **1ファイルに保存**するため、複数のセッション
(複数の LLM セッション・ターミナル)で azl を使うと、片方の `azl <name>` がもう片方の
ログイン先を書き換えてしまう。症状は「突然 `ResourceGroupNotFound` / 403 になる」で、
Azure 側の設定ミスに見えるのが厄介。

対策は az 公式の環境変数 **`AZURE_CONFIG_DIR`** で保存先をセッション(プロジェクト)ごとに分けること:

```
AZURE_CONFIG_DIR = C:/Users/<you>/.azure-profiles/<プロジェクト名>
```

- azl 側の設定は不要(az が `AZURE_CONFIG_DIR` を見るので、設定済みの環境で `azl <name>` を打つだけ)
- **SecretStore(エイリアス登録)は Windows ユーザー単位で共有のまま**。分かれるのはログイン状態だけで、登録は1回で済む
- ログイン状態はファイルなので再起動しても残る(`azl <name>` は初回1回だけ)
- Claude Code なら、プロジェクトの `.claude/settings.local.json` の `"env"` に置くと
  そのプロジェクトの全シェルに自動で効く(**次回起動から**)。このファイルは gitignore に入れること
- プロファイルには**トークンが入る**ので、置き場所はリポジトリの外にする
- ログイン後の `Active:` 行と `azl status` に、設定中の `AZURE_CONFIG_DIR` が表示される
- **未設定(共有)のまま使うと、エイリアス切替が他のセッションも巻き込む**。そのためログイン時に
  「共有プロファイル」の注意が1行表示され、`azl status` では `config_dir=(default:shared)` と表示される
  (`-Json` では `sharedProfile: true`)。設定が消えたことに気づく手がかりにもなる

## Assisted Login(`azl` 引数なし)

plain `az login` は **home テナントしか認証しない**。他の所属テナントは軒並み
`AccountUnusable` になり、そのテナントのサブスクにもディレクトリにも届かない
(az 自身が「`az login --tenant <ID>` を使え」と言ってくる)。ここが多テナント
アカウント最大のハマりどころ。

`azl`(引数なし)はこれをテナントファーストで解決する:

```
azl
  1. az login                  # ブラウザでアカウント選択(まず home で入る)
  2. 所属テナント一覧を表示     # 名前+ドメインで表示(GUIDを覚えなくてよい)
  3. 番号で選択
  4. az login --tenant <選択>  # ← AccountUnusable がここで解消される
  5. サブスク選択(1個なら自動、0個なら「ディレクトリ操作のみ可」)
```

- テナント一覧は `az rest` で ARM の `/tenants` API から取得(拡張モジュール不要)
- `azl -Graph` にすると選択テナントの Graph スコープも取得 → `az ad ...` がそのまま通る
- 終わったら本人としてログイン済み。SP も vault も使わない
- 無人実行(ブラウザが開けない環境)はこのルートでは不可 → SP エイリアス(`azl <name>`)を使う

## ローテーション

**自分で管理できる SP**(App の Owner / Global Admin 等)なら自動更新:

```bash
azl work -Graph    # 本人(管理者)で ARM+Graph ログイン
azl renew work     # 新secret自動生成(--append) → vault更新 → 旧secret削除
azl work           # SP に戻す
```

**他者から受領した SP**(自分で管理できない)は手動ローテ:

1. 提供元にシークレット再発行を依頼(または Azure ポータル / CLI で再発行)
2. `azl rotate work` で新シークレットに差し替え(検証付き)

ログイン時の期限警告(残り30日以下)にも、この2ルートの案内が表示される。

### 期限チェックの仕組み

SP は自分自身のアプリ登録を Graph で読めない(権限不足)ため、期限は **vault に記録した
`secretExpiresAt` で判定**する(オフライン・権限不要)。この値は次の操作で記録される:

- `azl renew` — 生成した新シークレットの正確な endDateTime を自動記録
- `azl register` / `azl rotate` — 期限を任意入力(スキップ可)

vault に期限情報がないエイリアスは「期限チェックをスキップ」と表示される
(一度 `azl renew` すれば以後は自動でチェックされる)。

## User Mode(一時的な本人ログイン)

普段は SP ログインで済むが、まれに **本人アカウント権限が要る操作**(RBAC割当、ゲスト招待、Graph API系など、SPに強い権限を渡したくないもの)が発生する。その時に `-User` フラグ1つで、同じエイリアスの `tenantId` を流用して本人ログインに切り替えられる。

```bash
azl work              # 通常運用: SP ログイン
azl work -User        # 一時的に本人ログイン(ARM: RBAC/サブスク操作)
azl work -Graph       # 一時的に本人ログイン(ARM+Graph: az ad ... 操作)
# ... 本人権限の操作を実施 ...
azl work              # SP に戻す
```

> **注意**: `-User` / `-Graph`(と引数なしの `azl`)は**ブラウザを開いて人の操作を待つ**。
> LLM のシェルから実行すると止まったように見えるので、人が実行すること
> (Claude Code なら `! azl work -Graph` のように `!` プレフィックスで)。

### 仕組み

- 保存データは変更しない — 既存 SP エイリアスの `tenantId` フィールドをそのまま流用
- `az login --tenant <保存済み tenantId>` を代行するだけ
- `az login` 単独では詰まる **マルチテナント所属アカウントの `AccountUnusable` 問題** を回避
- **ユーザーログインは常に ARM が要る**(ログイン直後の az がサブスク列挙で ARM を叩くため)。
  Graph 単独ログインは `AccountUnusable` で失敗するので、`-Graph` は **ARM を取ってから Graph を追加取得**する(= `-User` を含意)
- `-Graph`(= ARM + Graph)では **ARM ログイン → Graph ログインを順番に**実行し、両スコープのトークンをキャッシュに載せる。`az ad ...` を叩くなら `-Graph`

### 挙動の違い

| 項目 | 通常 (`azl work`) | User Mode (`-User` / `-Graph`) |
|---|---|---|
| 認証方法 | Service Principal | ブラウザで本人ログイン |
| 必須フィールド | appId / tenantId / secret | tenantId のみ |
| 取得スコープ | ARM | `-User`=ARM / `-Graph`=ARM+Graph |
| SP secret 期限チェック | ✅ 実施 | ⏭ スキップ |
| ログ表示 | `Active: work \| ...` | `-User`=`[user]` / `-Graph`=`[user+graph]` |
| 監査ログ名義 | SP名(例: azl-work) | 本人 UPN(例: user@contoso.com) |

### セキュリティ考察

- 保存データに追加の秘密情報は増えない(tenantId は元々秘密でない)
- 本人トークンは az CLI キャッシュ(`%USERPROFILE%\.azure`)に載る → クリアは `az logout`
- 「本人権限をずっと張っておく」運用ではなく、**必要な時だけ切り替えて用が済んだらSPに戻す** のが想定

## セキュリティ特性

### 守れること

- **DPAPI 暗号化** — 同一 Windows ユーザーアカウント以外は復号不可
- ファイル丸ごとコピーしても他 PC では使えない
- git 等に平文でコミットされる経路がない
- シークレットが bash のプロセス引数 / 環境変数 / 履歴に残らない(PowerShell から az へ直接渡す)

### 守れないこと

- **同じユーザーで動く任意のプロセス**は SecretStore を読める(マルウェア防御ではない)
- `az login` 実行中の数秒間、シークレットは az(python)プロセスの**コマンドライン引数に載る**
  (同一ユーザーのプロセス一覧から見える。az CLI が stdin / 環境変数でのシークレット受け渡しを
  サポートしないための制約で、上の「同一ユーザー内は守らない」前提と同じ範囲。
  これを避けたい場合は証明書ベースの SP 認証に移行する)
- `Authentication None` 設定のため、SecretStore のパスワード保護は無効化されている
- OS 再インストール・ユーザー削除で SecretStore は失われる(バックアップ責任は利用者)
- SP シークレット自体の有効期限管理は別途必要(Azure 側で最大 2 年)
- 操作ログは SP 名義で記録される(Azure AD 監査ログ上、本人操作とは区別される)

### 保管場所

`%LOCALAPPDATA%\Microsoft\PowerShell\secretmanagement\localstore` 配下に暗号化されたストアファイルが配置される。Windows 資格情報マネージャーの GUI には出ない(一覧は `azl list` で確認する)。

## 想定運用フロー

### 初回セットアップ

上記「初期セットアップ」の 1〜4 を実施。

### 日常

```bash
azl work
az resource list -o table
```

### ローテーション

```bash
azl rotate work
```

## 参考

- [Azure CLI: az login](https://learn.microsoft.com/cli/azure/authenticate-azure-cli)
- [Azure CLI: Service principal sign-in](https://learn.microsoft.com/cli/azure/authenticate-azure-cli-service-principal)
- [PowerShell SecretManagement overview](https://learn.microsoft.com/powershell/utility-modules/secretmanagement/overview)
- [Microsoft.PowerShell.SecretStore](https://learn.microsoft.com/powershell/module/microsoft.powershell.secretstore/)
