---
name: pr-review-watch
description: PR に付くレビューコメント（人間・bot 両方）をバックグラウンドで待ち受け、新着があれば要約して報告する観測専用スキル。監視中もチャットはブロックしない。「レビュー来てない？」「レビューついたら教えて」「PR のレビュー見といて」、PR 作成・push 直後の確認等で使用する。PR 番号・URL を指定することも可能（省略時はカレントブランチの PR を自動検出）。
---

# pr-review-watch

現在ブランチに紐づく PR の新着レビューコメントを待ち受け、要約して報告するスキル。**返信・修正はしない**。検知と内容の要約までが責務。

レビューコメントに完了イベントはないため、ベースライン時刻を記録 → バックグラウンドでポーリング → 新着検知で報告という方式を取る。主目的は bot レビューの検知（push 後数分で返る）のため、監視ウィンドウは 30 分で打ち切る。

## レビューコメントの3つの取得元

| 種別 | API | 主なフィールド |
|------|-----|--------------|
| レビュー総評（APPROVED / CHANGES_REQUESTED / COMMENTED） | `pulls/{n}/reviews` | `state`, `body`, `submitted_at`, `user.login` |
| インラインのコード行コメント | `pulls/{n}/comments` | `path`, `line`, `body`, `created_at`, `user.login` |
| 会話欄の一般コメント | `issues/{n}/comments` | `body`, `created_at`, `user.login` |

bot（CodeRabbit 等）も検知対象。

## 手順

### 1. PR 解決

`gh pr view [<番号またはURL>] --json number,headRefName,state,url` で PR を取得。
- PR なし → 停止
- state が `OPEN` 以外 → 確認
- 自動検出かつ現在ブランチが headRef と異なる → 警告

### 2. ベースライン決定

最後の push 時刻をベースラインにする（これより後のコメントを「新着」とする）:
```bash
gh pr view <PR番号> --json commits --jq '.commits[-1].committedDate'
```
取得できない場合は現在時刻（`date -u +%Y-%m-%dT%H:%M:%SZ`）を使う。

### 3. バックグラウンド監視（`run_in_background: true` 必須）

フォアグラウンドで回さないこと（チャットがブロックされ、10 分でタイムアウトする）。

ポーリングはスクリプトに任せる（60s × 30 = 最大 30 分。`INTERVAL_SEC` / `MAX_ATTEMPTS` で変更可）:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/pr-review-watch/scripts/watch-new-comments.sh" <PR番号> '<ベースライン ISO8601 UTC>'
```

新着があれば JSON 行を stdout に出して終了。なければ `TIMEOUT: 監視ウィンドウ内に新着コメントなし` を出して終了。

起動したら「レビュー監視をバックグラウンドで開始した」とユーザーに伝えてターンを終える。

### 4. 新着検知後の報告

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

## 要約ルール

- body が巨大・コメントが多い場合は Explore サブエージェントに委任して要約だけ受け取る
- コードブロックの長い引用・diff 提案は要点のみ（全文は link 参照）
- 同種軽微指摘が多数なら最初の 1〜2 件 + 「他 N 件同種」
- nit / suggestion / must-fix のニュアンスが読み取れれば付記

## 制約

このスキルの手順上の制約（監視中のユーザーからの別依頼は通常通り対応してよい）:
- レビューへの返信・コード修正・commit・push・resolve / approve は行わない
- 1 回の新着検知（または TIMEOUT）で終了。自発的に再起動しない
- コメント全文をそのまま会話に出さない
- ブランチ切り替え・rebase・merge は行わない
