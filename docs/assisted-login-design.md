# azl Assisted Login — 設計と思想

> 2026-07-02 実装。`azl`(引数なし)の新コア。

## 原点への立ち返り

azl を作ったきっかけ:

1. **ログインがつらい** — LLM 連携時にテナントが選べておらず「うまく動かん!」が連発
2. SP にすればログイン自体を消せて、テナントも確定できる → SP エイリアス機構(初期実装)

その後 provision(SP 自動作成)まで作りかけたが、ロール選択 UX などで az/ポータルの
複雑さを azl が再発明しかけていることに気づき、方針を確定:

**azl = 「正しく認証済みの状態を作る」だけの薄い層。**
SP 作成・ロール割当・シークレット管理などは、ログイン後に素の `az ...` を
(LLM と対話しながら)使えばよい。個々の管理機能を azl に抱え込まない。
→ provision は削除(git 履歴 `a9e74c2` に残存)。renew は「vault の中身を新鮮に保つ」
保存層の管理なので維持。

## 2ルート構成

| ルート | 用途 | 認証 |
|---|---|---|
| `azl` (assisted login) | 人が対話で作業 | 本人・ブラウザ |
| `azl <name>` (SP エイリアス) | LLM/CI の無人実行 | SP・非対話 |

## Assisted Login の設計(テナントファースト)

### 問題: plain `az login` は home テナントしか認証しない

実測(12テナント所属アカウント)で、`az login` は home 以外の11テナント全てが
`AccountUnusable` になり、サブスク選択画面には home のサブスクしか出ない。
az 自身が「`az login --tenant <ID>` を使え」と案内してくる。
**つまり選ぶべきはサブスクではなくテナント。**

### フロー

```
azl [-Graph]
  1. az login                  # ブラウザでアカウント選択(まず home で入る)
  2. GET /tenants (az rest)    # 所属テナント一覧を名前+ドメインで取得
  3. 番号で選択
  4. az login --tenant <選択>  # ← AccountUnusable がここで解消
  5. (-Graph 時) Graph スコープも取得
  6. サブスク選択(1個なら自動、0個なら「ディレクトリ操作のみ可」と表示)
  7. az account set → Active 表示
```

### 実装ポイント

- テナント一覧は `az account tenant list` ではなく
  `az rest GET https://management.azure.com/tenants?api-version=2022-12-01` を使用。
  前者は account 拡張が必要で、この環境では pip クラッシュで入らない。後者は拡張不要で
  displayName / defaultDomain が取れる(同名「既定のディレクトリ」もドメインで判別可能)
- 同名テナント対策として一覧に defaultDomain を併記
- `-User` は no-op スイッチとして受理(assisted は常に本人ログインのため)
- PowerShell 5.1 互換必須(bin/azl.cmd は powershell.exe で起動)。三項演算子など 7+ 構文は使わない

### ディスパッチャの割り当て

- `azl`(引数なし) → assisted login(旧: ヘルプ表示)
- `azl -Graph` 等フラグのみ → assisted login にフラグごと委譲
- ヘルプは `azl -help` / `--help` / `-h` / `azl help`

## 動作確認(2026-07-02 実機)

- 多テナント所属アカウント(12テナント)で、home から同名の「既定のディレクトリ」を
  ドメイン表記で判別して選択し、ログイン成功
- そのテナントの従量課金サブスクに `az account set` され、
  `az webapp list` で App Service 9件を正常取得
- plain `az login` では到達不能だったテナントに、azl 経由で到達できることを確認
