---
name: conflict-check
description: PR のマージコンフリクト状態を確認し、結果（コンフリクトなし / コンフリクトあり＋ファイル一覧）を返す観測専用スキル。「コンフリクトある？」「マージできる？」「conflict 確認して」「コンフリクト確認」、PR 作成・push 直後の確認等で使用する。PR 番号・URL を指定することも可能（省略時はカレントブランチの PR を自動検出）。
---

# conflict-check

現在ブランチに紐づく PR のマージコンフリクト状態を確認し、結果を報告するスキル。**修正・rebase・merge はしない**。検知と影響ファイルの特定までが責務。

## 手順

### 1. PR 解決

`gh pr view [<番号またはURL>] --json number,headRefName,state,url,baseRefName` で PR を取得。PR 番号と `baseRefName` を控えておく。
- PR なし → 停止
- state が `OPEN` 以外 → 確認
- 自動検出かつ現在ブランチが headRef と異なる → 警告

### 2. マージ可否＋コンフリクト確認

UNKNOWN 待ち（最大 4 回 × 30 秒）と、CONFLICTING 時のコンフリクトファイル特定はスクリプトに任せる。通常 1〜2 分以内に解決するためフォアグラウンドで待ってよい。ローカル判定は `git merge-tree --write-tree`（git 2.38+）を使う。

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/conflict-check/scripts/check-conflicts.sh" <PR番号> [<baseRefName>]
```

`INTERVAL_SEC` / `MAX_ATTEMPTS` / `REMOTE` で調整可。stdout に JSON が 1 オブジェクト出る:

| フィールド | 意味 |
|-----------|------|
| `mergeable` | `MERGEABLE` / `CONFLICTING` / `UNKNOWN` など |
| `mergeStateStatus` | `CLEAN` / `BEHIND` / `DIRTY` など |
| `baseRefName` | ベースブランチ |
| `conflictFiles` | コンフリクトファイルパスの配列（該当時のみ非空） |
| `localCheck` | `skipped`（API が CONFLICTING 以外）/ `conflicts` / `clean`（API と不一致）/ `error` |

### 3. 結果報告

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

rebase で解消する？

**mergeable が UNKNOWN のまま:**
⚠️ マージ可否確認タイムアウト (PR #<番号>) — GitHub がまだ計算中の可能性あり。再確認は conflict-check を再実行。

## 制約

このスキルの手順上の制約（ユーザーからの別依頼は通常通り対応してよい）:
- rebase・merge・コード修正・commit・push は行わない（`git merge-tree` は読み取り専用のため OK）
- 作業ツリーを変更する操作（`git merge --no-commit`・ブランチ切り替え等）は行わない
