---
name: babysit-pr
description: このスキルは git push や gh pr create の直後で PR が存在するとき、または明示的な起動で使用する。所与の PR に張り付いて CI/レビュー/コンフリクトを監視・解消する。「CI 通った？」「CI 落ちたら教えて」「レビュー来てない？」「レビューついたら教えて」「コンフリクトある？」「マージできる？」等の観測専用の指示でも使用する。PR 番号・URL を指定することも可能（省略時はカレントブランチの PR を自動検出）。
---

所与の PR を監視し、問題が発生するたびに修正・push してクリーンな状態を維持する。
PR が存在しない場合は終了する。

## モード判定

ユーザー意図で分岐する:

| モード | 判定 | 振る舞い |
|--------|------|----------|
| **張り付き**（デフォルト） | babysit / 張り付き / push・PR 作成直後の面倒見 / 明示なし | merge まで監視し、問題を修正→commit→push。push 後は該当監視を再起動 |
| **観測のみ** | 「CI 通った？」「レビュー来てない？」「コンフリクトある？」等、報告だけを求める指示 | 該当セクションの手順で報告して終了。修正・commit・push はしない |

観測のみで対象が複数ある場合（例: 「CI とコンフリクト見て」）は、指定されたセクションだけ実行する。

## PR の指定

対象 PR は以下のいずれかで指定する。指定がない場合はカレントブランチの PR を自動検出する。

- PR 番号: `123`
- PR URL: `https://github.com/owner/repo/pull/123`
- カレントブランチ: 省略（`gh pr view` が自動検出）

## PR 解決

`gh pr view [<番号またはURL>] --json number,headRefName,state,url,baseRefName` で PR を取得。
- PR なし → 停止
- state が `OPEN` 以外 → 確認
- 自動検出かつ現在ブランチが headRef と異なる → 警告

以降の手順で使う PR 番号・`baseRefName` を控えておく。

---

## CI

CI 完了を待ち、結果（green / failure + ログ要約）を返す。観測モードではここで終了。張り付きモードでは失敗時に修正へ進む。

### 手順

#### 1. CI 監視（`run_in_background: true` 必須）

フォアグラウンドで実行しないこと（チャットがブロックされ、10 分でタイムアウトする）。

1. `gh pr checks <PR番号> --json name,state,bucket` で現状確認
   - 全チェック完了済みなら watch 不要、結果報告へ
   - 「no checks reported」なら 30 秒待って 1〜2 回リトライ
2. `gh pr checks <PR番号> --watch --interval 30 --fail-fast` をバックグラウンド起動。「CI 監視を開始した」とユーザーに伝えてターンを終える
3. 起動時に `gh pr view --json headRefOid` で監視対象コミットを控えておく
4. 終了通知後: `gh pr checks <PR番号> --json name,state,bucket,link,workflow` で結果取得
   - headRefOid が変わっていたら「古いコミットの結果」と明記し、再監視するか確認
   - 別作業中に通知が来たら、簡潔に挟んでから元の作業に戻る

#### 2. 結果報告

**全て成功:**
✅ CI green (PR #<番号>) — N チェック pass

**失敗あり:**
❌ CI failed (PR #<番号>)

fail-fast で抜けているため pending が残る可能性あり。`bucket` が `pending` のチェックがあれば「他 N 件 pending」と併記する。

失敗ジョブごとに出力:
- <ジョブ名> / <workflow>
  - run URL: <link>
  - ログ要約: `<重要箇所のみ抜粋>`
  - 推測カテゴリ: lint / formatter / type-check / unit test / integration test / build / generated-file mismatch / dependency / その他

PRとは無関係と思われる失敗は、別ですでに修正済みの可能性があるため最新のベースブランチを確認する。

### ログ取得

`gh run view <run-id> --log-failed` で取得。run-id は link の `…/actions/runs/<run-id>/…` から抜く。

コンテキスト汚染防止のため:
- `tail -n 150` や `grep -iE 'error|fail|FAILED'` で絞ってから読む
- ログが巨大 / 失敗ジョブ多数の場合は Explore サブエージェントに委任して要約だけ受け取る

ログ要約ルール:
- タイムスタンプ・装飾行・冗長スタック中間は除く
- エラーメッセージ本文・ファイルパス・行番号を残す
- 1 ジョブ 5〜30 行。スタックは浅いユーザーコード行 + ライブラリ境界 2〜3 行
- 同種失敗が大量なら最初の 1〜2 件 + 「他 N 件同種」

### 観測モードの制約

- コード修正・commit・push・lint --fix 等は行わない
- 1 回の CI 完了を見届けたら終了。自発的に再起動しない
- ログ全文をそのまま会話に出さない
- ブランチ切り替え・rebase・merge は行わない

---

## レビュー

新着レビューコメント（人間・bot 両方）を待ち受け、要約して報告する。観測モードではここで終了。張り付きモードでは指摘に応じて修正またはユーザーに諮る。

レビューコメントに完了イベントはないため、ベースライン時刻を記録 → バックグラウンドでポーリング → 新着検知で報告という方式を取る。主目的は bot レビューの検知（push 後数分で返る）のため、監視ウィンドウは 30 分で打ち切る。

### レビューコメントの3つの取得元

| 種別 | API | 主なフィールド |
|------|-----|--------------|
| レビュー総評（APPROVED / CHANGES_REQUESTED / COMMENTED） | `pulls/{n}/reviews` | `state`, `body`, `submitted_at`, `user.login` |
| インラインのコード行コメント | `pulls/{n}/comments` | `path`, `line`, `body`, `created_at`, `user.login` |
| 会話欄の一般コメント | `issues/{n}/comments` | `body`, `created_at`, `user.login` |

bot（CodeRabbit 等）も検知対象。

### 手順

#### 1. ベースライン決定

最後の push 時刻をベースラインにする（これより後のコメントを「新着」とする）:
```bash
gh pr view <PR番号> --json commits --jq '.commits[-1].committedDate'
```
取得できない場合は現在時刻（`date -u +%Y-%m-%dT%H:%M:%SZ`）を使う。

#### 2. バックグラウンド監視（`run_in_background: true` 必須）

フォアグラウンドで回さないこと（チャットがブロックされ、10 分でタイムアウトする）。

ポーリングはスクリプトに任せる（60s × 30 = 最大 30 分。`INTERVAL_SEC` / `MAX_ATTEMPTS` で変更可）:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/babysit-pr/scripts/watch-new-comments.sh" <PR番号> '<ベースライン ISO8601 UTC>'
```

新着があれば JSON 行を stdout に出して終了。なければ `TIMEOUT: 監視ウィンドウ内に新着コメントなし` を出して終了。

起動したら「レビュー監視をバックグラウンドで開始した」とユーザーに伝えてターンを終える。

#### 3. 新着検知後の報告

別作業中に通知が来たら、簡潔に挟んでから元の作業に戻る。`TIMEOUT` なら「監視ウィンドウ内に新着なし」と伝えて終了。

**新着があった場合:**

💬 新着レビュー (PR #<番号>)

レビュアー / bot ごと、コメント種別ごとにまとめて出力:
- **<author>** (<人間 or bot>) — <kind>
  - state（review の場合）: APPROVED / CHANGES_REQUESTED / COMMENTED
  - 位置（inline の場合）: `<path>:<line>`
  - 要点: <body の要約。原文が短ければそのまま、長ければ要約>
  - link: <url>

最後に総括を一行（例: 「CHANGES_REQUESTED が 1 件、インライン指摘 3 件。対応する？」、人間/bot 内訳等）

### 要約ルール

- body が巨大・コメントが多い場合は Explore サブエージェントに委任して要約だけ受け取る
- コードブロックの長い引用・diff 提案は要点のみ（全文は link 参照）
- 同種軽微指摘が多数なら最初の 1〜2 件 + 「他 N 件同種」
- nit / suggestion / must-fix のニュアンスが読み取れれば付記

### 観測モードの制約

- レビューへの返信・コード修正・commit・push・resolve / approve は行わない
- 1 回の新着検知（または TIMEOUT）で終了。自発的に再起動しない
- コメント全文をそのまま会話に出さない
- ブランチ切り替え・rebase・merge は行わない

---

## コンフリクト

マージコンフリクト状態を確認し、結果を報告する。観測モードではここで終了。張り付きモードではコンフリクトがあれば解消へ進む。

### 手順

UNKNOWN 待ち（最大 4 回 × 30 秒）と、CONFLICTING 時のコンフリクトファイル特定はスクリプトに任せる。通常 1〜2 分以内に解決するためフォアグラウンドで待ってよい。ローカル判定は `git merge-tree --write-tree`（git 2.38+）を使う。

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/babysit-pr/scripts/check-conflicts.sh" <PR番号> [<baseRefName>]
```

`INTERVAL_SEC` / `MAX_ATTEMPTS` / `REMOTE` で調整可。stdout に JSON が 1 オブジェクト出る:

| フィールド | 意味 |
|-----------|------|
| `mergeable` | `MERGEABLE` / `CONFLICTING` / `UNKNOWN` など |
| `mergeStateStatus` | `CLEAN` / `BEHIND` / `DIRTY` など |
| `baseRefName` | ベースブランチ |
| `conflictFiles` | コンフリクトファイルパスの配列（該当時のみ非空） |
| `localCheck` | `skipped`（API が CONFLICTING 以外）/ `conflicts` / `clean`（API と不一致）/ `error` |

### 結果報告

**mergeable が MERGEABLE:**
✅ コンフリクトなし (PR #<番号>) — `<baseRefName>` へマージ可能
mergeStateStatus が `BEHIND` なら「ベースより遅れているがコンフリクトはなし」と併記。

**mergeable が CONFLICTING:**
- `localCheck: conflicts` → ファイル一覧を報告
- `localCheck: clean` → 「GitHub API と不一致、コンフリクトなし」と伝える
- `localCheck: error` → fetch / merge-tree 失敗。再実行を促す

❌ コンフリクトあり (PR #<番号>)
コンフリクトしているファイル:
- `<ファイルパス>`
- ...

rebase で解消する？（観測モードでは提案のみ。張り付きモードでは解消へ進む）

**mergeable が UNKNOWN のまま:**
⚠️ マージ可否確認タイムアウト (PR #<番号>) — GitHub がまだ計算中の可能性あり。再確認する。

### 観測モードの制約

- rebase・merge・コード修正・commit・push は行わない（`git merge-tree` は読み取り専用のため OK）
- 作業ツリーを変更する操作（`git merge --no-commit`・ブランチ切り替え等）は行わない

---

## 張り付きループ

張り付きモードでは、CI / レビュー / コンフリクトを並行または順次監視し、問題が出るたびに解消してクリーンな状態を維持する。
PR が merge されるまで監視を継続し、merge を確認したらユーザーに伝えて完了とする。

監視中のユーザーからの別依頼は通常通り対応してよい。

### CI

上記「CI」セクションでバックグラウンド監視する。失敗が報告されたらログ要約から原因を特定し、修正→commit→push。push 後は CI が再走するので CI 監視を再起動して再監視する。
PRとは無関係と思われる失敗は別ですでに修正済みの可能性があるため最新のベースブランチを確認する。

### レビュー

上記「レビュー」セクションでバックグラウンド監視する（CI 監視と並行で起動してよい）。監視・解消対象は AI や Bot からも含む。新着指摘が来たら:
- バグ・規約違反・must-fix → 修正→commit→push
- nit / 好み / 判断に迷うもの → 方針を簡潔に提示してユーザーに諮る

レビュー監視は 1 回の検知で終了するので、まだ来てなければ再起動して待つこと。

### コンフリクト

上記「コンフリクト」セクションで確認する。コンフリクトがあれば解消→commit→push。
