# 状態のモデリング

判断フローB の詳細。
STI・enum・delegated_type の書き方そのものはRailsガイドの通りなので、
**どれを選ぶか**と**選んだときに追加で要る判断**だけを書いている。

**どの選択肢でも、操作の公開は名詞リソースのCRUDにする**（`controllers.md`）。
カラムの持ち方とエンドポイントの形は独立した判断。

## 1. STI / delegated_type — 振る舞いが違う

「`if type == :xxx` でメソッドの中身が分岐する」なら型が違う。
**「振る舞いは同じで値が違うだけ」ならenum。**

- **STI**: 同じカラム構成で振る舞いだけ違う（`Channels::Public` / `Channels::Private`）
- **delegated_type**: 属性構成そのものが違う（`Entry` + `Article` / `Image`）。
  共通カラムは親テーブルに、型固有カラムは各テーブルに置ける

STIを選んだときに追加で決めること:

- **型の判定は `is_a?`**（`def public? = is_a?(Channels::Public)`）。`type` 文字列比較を散らさない
- **型変更を許すか / 許さないかをバリデーションで明示する**。書かないと `update!(type: ...)` で黙って通る

## 2. ジョインモデルの属性 — 主体ごとに違う状態

「この記事は既読か」は記事の状態ではなく、**ユーザーと記事の関係の状態**。
`has_many :through` の中間モデルに属性を持たせる。

- **区別が要らない** → `has_many :bookmarks` の有無だけで表す
- **「一度オンにして自分でオフにした」と「まだ触っていない」を区別したい**
  → 中間モデルに `subscribed` boolean を持ち、`first_or_create.update!` で立てる

`has_and_belongs_to_many` は使わない。

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

SKILL.md の3問で、**1つでもYesならレコード**。

```ruby
module Post::Archivable
  extend ActiveSupport::Concern

  included do
    has_one :archival, class_name: "Post::Archival", dependent: :destroy

    scope :archived, -> { joins(:archival) }
    scope :active,   -> { where.missing(:archival) }
  end

  def archived? = archival.present?

  def archive(user: Current.user)
    unless archived?          # 冪等にする。コントローラで存在チェックしない
      transaction do
        unpublish             # 状態間の依存はモデル側に書く
        create_archival!(user: user)
      end
    end
  end
end
```

`archived_at` / `archived_by` は `archival&.created_at` / `archival&.user` に委譲する。
条件付きの操作をエンドレスメソッドで書いてはいけない（`controllers.md` の罠を参照）。

得られるもの: 「誰が・いつ」がタダで付く / 付随属性を後から足してもメインテーブルは無傷 /
`joins(:archival)` / `where.missing(:archival)` で素直にクエリできる /
`create` / `destroy` がそのまま archive / unarchive になる。

払うもの: テーブルとファイルが1セット / 一覧では preload が必要。

## 5. nullable timestamp — 「いつ」だけ要る

「誰が」が既に文脈から確定していて、付随属性が要らないケース
（`notifications.read_at` — `notifications.user_id` で誰が読んだかは一意に決まる）。
`scope :unread, -> { where(read_at: nil) }` と `read` / `unread` / `read?` を置く。

「誰が」が可変なら 4 の has_one レコードへ。

## 6. boolean — 何も付随しない設定

- **必ず `null: false` + `default:`**
- 「機能のオン／オフ」「設定」「所有者しか変えない静的なフラグ」に向く
- 絞り込み条件になるならインデックスを張る
- **booleanでも操作はリソースで公開してよい**。「booleanかrecordか」と「リソース化するか」は独立

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

**直交性の確認は必ずやる。** 同時に立ちうる値を1つのenumにまとめると表せなくなる。
逆に、同時に立ちえない値を別カラムにすると不整合が入る。

## 状態遷移の書き方

- **冪等にする**。`unless archived?` で二重実行を吸収し、コントローラ側で存在チェックしない
- **状態間の依存はモデル側に書く**（「アーカイブしたら公開を解く」）
- 遷移の副作用は `transaction do` で束ねる
- 状態機械gem（AASM等）は、遷移が本当に複雑（5状態 × 条件分岐）になるまで入れない
