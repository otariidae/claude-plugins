# 状態のモデリング

判断フローB の詳細。裏どりは `evidence.md`。
STI・enum・delegated_type の書き方そのものはRailsガイドの通りなので、
**どれを選ぶか**と**選んだときに追加で要る判断**だけを書いている。

`has_one` レコード方式の実装例は SKILL.md 判断フローB を参照。

**どの選択肢でも、操作の公開は名詞リソースのCRUDにする**（`controllers.md`）。
カラムの持ち方とエンドポイントの形は独立した判断。

## 1. STI / delegated_type — 振る舞いが違う

「`if type == :xxx` でメソッドの中身が分岐する」なら型が違う。
**「振る舞いは同じで値が違うだけ」ならenum。**

- **STI**: 同じカラム構成で振る舞いだけ違う（`Channels::Public` / `Channels::Private`）
- **delegated_type**: 属性構成そのものが違う（`Entry` + `Article` / `Image`）。
  共通カラムは親テーブルに、型固有カラムは各テーブルに置けるので、
  STIのNULLだらけのテーブルを避けられる

STIを選んだときに追加で決めることが2つある。

- **型の判定は `is_a?`**（`def public? = is_a?(Channels::Public)`）。
  `type` 文字列との比較をアプリ側に散らさない
- **型変更を許すか / 許さないかを明示的にバリデーションで書く**。
  「非公開→公開は不可」のような制約は `type_changed? && type_was == "..."` で明示する。
  書かないと `update!(type: ...)` で黙って通る

## 2. ジョインモデルの属性 — 主体ごとに違う状態

「この記事は既読か」は記事の状態ではなく、**ユーザーと記事の関係の状態**。
`posts.read` のようなカラムは作れない。`has_many :through` の中間モデルに属性を持たせる。

ここで**「レコードが無い＝オフ」で済ませるか、boolean属性を持つか**の判断がある。

- **区別が要らない** → `has_many :bookmarks` の有無だけで表す
- **「一度オンにして自分でオフにした」と「まだ触っていない」を区別したい**
  → 中間モデルに `subscribed` boolean を持ち、`first_or_create.update!` で立てる。
  自動購読のロジックが、明示的に解除した人を再購読させないために必要になる

`has_and_belongs_to_many` は使わない。関係そのものが属性
（いつ・どの役割で・どの通知設定で）を持てるようにする。

## 3. enum — 3 値以上のライフサイクル・設定値

```ruby
enum :status, %w[ pending processing completed failed ].index_by(&:itself), default: :pending
```

- **`%w[...].index_by(&:itself)` でDBに文字列を入れる**。整数だと後から値を差し込めない
- `null: false` + `default:` をDB側にも入れる
- **2値でもenumにしてよい場合**: 値が増える見込みがあるとき、または各値が「否定」ではなく
  それ自体で一段階を成すとき（`drafted` は「publishedでない」ではなく下書きという段階）
- `case status when ... end` がモデルの中に何度も出てきたらSTIを疑う

## 4. has_one レコード + resource — 付随する属性がある可逆状態

判断は次の3問で、**1つでもYesならレコード**。

1. 「誰がやったか」を記録したいか？
2. 「いつやったか」を記録したいか？
3. その状態に固有の属性（理由・トークン・期限）が今あるか、将来ありそうか？

得られるもの:

- 「誰が」「いつ」がタダで付く（`archivals.user_id` と `created_at`）
- 付随属性（`reason`, `expires_at`）を後から足してもメインテーブルは無傷
- `joins(:archival)` / `where.missing(:archival)` で素直にクエリできる。
  `where(archived: true)` と違ってNULLの三値論理を踏まない
- 期間・実行者での絞り込みが書ける（`where(archivals: { created_at: 1.week.ago.. })`）
- `create` / `destroy` がそのままarchive / unarchiveになり、リソースとして自然に公開できる

払うもの: テーブルとファイルが1セット増える / 一覧ではpreloadが必要 /
「archivedな一覧」にJOINが要る（インデックスは張れる）。

## 5. nullable timestamp — 「いつ」だけ要る

「誰が」が既に文脈から確定していて、付随属性が要らないケース
（`notifications.read_at` — `notifications.user_id` で誰が読んだかは一意に決まる）。
`scope :unread, -> { where(read_at: nil) }` と `read` / `unread` / `read?` を置く。

**timestampにしないほうがいいケース**: 「誰が」が可変（複数の人が同じレコードを閉じうる）。
その場合は 4 の has_one レコードへ。

## 6. boolean — 何も付随しない設定

- **必ず `null: false` + `default:`** を付ける。三値論理を持ち込まない
- 「機能のオン／オフ」「設定」「所有者しか変えない静的なフラグ」に向く
- 絞り込み条件になるならインデックスを張る
- **booleanでも操作はリソースで公開してよい**。writebook は `books.published` boolean を
  `Books::PublicationsController#update` で変える。「booleanかrecordか」と
  「リソース化するか」は独立した判断

## 「状態カラムを増やす」前のチェック

| つい書きたくなるもの | だいたい正しい形 |
|---|---|
| `posts.archived` (boolean) | 「誰が・いつ」が要るなら `has_one :archival` |
| `posts.status` に可逆トグルを足す | 直交する状態は別カラム／別レコードに分ける |
| `posts.deleted` | 論理削除。`has_one :trashing` か、そもそも本当に消す |
| `posts.published` + `posts.published_at` | どちらか一方。timestampがあればbooleanは導出できる |
| `users.read_post_ids` (配列/JSON) | ジョインモデル |
| 状態AとBが同時に立てない | enum 1本にまとめる |
| 状態AとBが独立に立つ | カラム／レコードを分ける（enumにまとめない） |

**直交性の確認は必ずやる。** `drafted / published / archived / closed` を1つのenumに
まとめると「公開済みでアーカイブ済み」が表せなくなる。逆に、同時に立ちえない値を
別カラムにすると不整合が入る。

## 状態遷移の書き方

- **冪等にする**。`unless archived?` で二重実行を吸収し、コントローラ側で存在チェックしない
- **状態間の依存はモデル側に書く**（「アーカイブしたら公開を解く」）
- 遷移の副作用は `transaction do` で束ねる
- 状態機械gem（AASM等）は、遷移が本当に複雑（5状態 × 条件分岐）になるまで入れない
