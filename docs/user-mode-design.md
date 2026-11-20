# azl User Mode — 設計と実装

> SP ログインが基本の azl に、**一時的な本人ログイン**を追加する機能。
> 2026-07-01 に設計・実装・実機確認まで完了。

## 目的

普段は SP ログインで済むが、**まれに本人アカウント権限が要る操作**
(RBAC 割当、ゲスト招待、`az ad ...` などのディレクトリ操作。SP に強い権限を渡したくない/渡していないもの)
が発生する。それを azl の1コマンド・フラグで切り替えられるようにする。

## 設計の要点

**保存データは変更しない。呼び出し時のフラグで切り替える。**

- **1エイリアス = 2つの顔**(SP と 本人)を持てる
- 保存 hashtable に `mode` フィールドは持たない。既存 SP エイリアスの `tenantId` をそのまま流用
- `register` / `list` / `show` / `rotate` / `remove` は変更なし
- 本人ログインでは保存済みの `tenantId` を `az login --tenant <ID>` に渡す
  → マルチテナント所属アカウントで詰まる `AccountUnusable` 問題を回避

**設計の議論経緯**:
- 当初「保存データに `mode` フィールドを持つ」案があったが、
  「登録時には分けず、利用時のフラグで切替」という方針に確定(シンプル・後方互換)。
- 本人ログインだけでは `az ad ...`(Graph API)が `AccountUnusable` になる問題に遭遇。
  ARM と Graph はスコープが別のため、`-Graph` フラグで Graph スコープを追加取得する形に拡張。

## 普段の使い分け(運用ガイド)

| 用途 | コマンド | 認証 | スコープ | ダイアログ |
|---|---|---|---|---|
| **普段遣い**(サブスク/リソース操作) | `azl work` | SP | ARM | なし |
| **ちょっと強い権限**(RBAC 割当・サブスク管理など) | `azl work -User` | 本人 | ARM | 1回 |
| **ユーザー/ディレクトリ操作**(`az ad ...`・ゲスト招待・Graph 系) | `azl work -User -Graph` | 本人 | ARM + Graph | 最大2回※ |
| **SP に戻す** | `azl work` | SP | ARM | なし |

※ 2回目のダイアログはアカウントがキャッシュ済みなら無音で通ることも多い。

**判断の目安**:
- リソース(サブスク配下)を触るだけ → `-User`
- `az ad ...` / ゲスト招待 / Graph が絡む → `-User -Graph`(ARM も込みなので迷ったらこれが安全)
- `-Graph` 単独も可能(Graph だけ・ダイアログ1回)だが、その状態だと ARM 操作は通らない
- **用が済んだら `azl work` で SP に戻す**(本人権限を張りっぱなしにしない)

## 実装

### 1. `azl-login.ps1`

- パラメータに `[switch]$User` と `[switch]$Graph` を追加。
  `$isUser = $User -or $Graph`(どちらも本人ログイン扱い)
- 必須フィールド検証を分岐: user mode は `tenantId` のみ、SP mode は `appId/tenantId/secret`
- ログイン処理:
  - `-User` → ARM スコープ、`-Graph` → Graph スコープ、**併用時は ARM→Graph の順で2回ログイン**して
    両トークンを CLI キャッシュに載せる
  - SP mode: 既存の `az login --service-principal ...`(変更なし)
  - user mode の `az login` 呼び出しは try/finally で `$ErrorActionPreference = 'Continue'` に一時変更
    (下記「stderr 警告対策」参照)
- Active info 表示のタグ: `-User -Graph` → `[user+graph]` / `-Graph` → `[graph]` / `-User` → `[user]`
- SP secret 期限チェックは user mode で **完全スキップ**(早期 exit 0)

### 2. `azl.ps1`

- `LOGIN FLAGS` に `-User` / `-Graph` の説明、`EXAMPLES` に3例
- ディスパッチャのフラグ正規化(先頭 `-` を末尾に回す既存ロジック)により、
  コード追加なしで `-User` / `-Graph` が透過的に `azl-login.ps1` へ届く

### 3. `README.md`

- `## User Mode(一時的な本人ログイン)` セクション。使い方・仕組み・挙動の違い表・セキュリティ考察

### stderr 警告対策(実装済み)

`az login --tenant` は az CLI が stderr に "Select the account..." 警告を出す。
これが `$ErrorActionPreference='Stop'` に拾われて NativeCommandError となりスクリプトが途中終了する。
(SP mode の `az login --service-principal` は stderr に何も書かないため発生しない。)
→ user mode のログイン呼び出しを try/finally で囲み、一時的に `'Continue'` にして回避
(既存 `azl-show.ps1` の credential list 呼び出しと同じパターン)。

## 動作確認(2026-07-01 実機確認済み ✅)

- `azl work -User` → 本人ログイン成功、`[user]` タグ表示、期限チェック行なし、`az account show` が本人 UPN
- `azl work -User -Graph` → `[user+graph]` タグ表示、stderr 警告で中断せず完走
  - **Graph 操作** `az ad app owner list --id <appId> -o table` → 成功
    (SP mode / `-User` 単独では `AccountUnusable` だったもの)
  - **ARM 操作** `az group list` → 同一セッションで成功(両スコープ生存を確認)
- `azl work` で SP に戻せることを確認

## セキュリティ考察

- 保存データに追加の秘密情報は増えない(`tenantId` は元々秘密でない)
- 本人トークンは az CLI キャッシュ(`%USERPROFILE%\.azure`)に載る → クリアは `az logout`
- 「本人権限をずっと張っておく」運用ではなく、**必要な時だけ切り替えて用が済んだら SP に戻す** のが想定
- 監査ログ名義: SP mode は SP 名、user mode は本人 UPN。
  「誰が何をしたか」は user mode の方が明快、ただし本人アカウントの権限が全操作に影響する

## 拡張余地(未実装・将来)

- **`azl current`** — 現在のアクティブエイリアス(と mode)を表示
- **`azl switch`** — 対話的にエイリアス一覧から選んでログイン
- **`--device-code`** — ブラウザを開けない環境向け(`az login --use-device-code`)
- **Managed Identity mode** — Azure VM/App Service 上で走らせる時用(`az login --identity`)
- **環境変数エクスポート** — `azl env work` で `ARM_CLIENT_ID` 等を吐く(Bicep/Terraform 用)

## 参考リンク

- `az login`: https://learn.microsoft.com/cli/azure/authenticate-azure-cli
- Graph スコープ指定: `az login --scope https://graph.microsoft.com//.default --tenant <ID>`
