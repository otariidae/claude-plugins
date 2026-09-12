# 状態のモデリング

判断フローB の詳細。**どれを選ぶか**と追加判断だけ。
操作の公開は名詞リソースのCRUD（`controllers.md`）。カラムとエンドポイントは独立。

## 1. STI / delegated_type — 振る舞いが違う

メソッドの中身が `if type` で分岐するなら型が違う。値だけ違うなら enum。

- **STI**: カラム構成は同じ（`Channels::Public` / `Private`）
- **delegated_type**: 属性構成が違う（`Entry` + `Article` / `Image`）

追加判断: 型判定は `is_a?` / 型変更の可否はバリデーションで明示（書かないと黙って通る）。

## 2. ジョインモデル — 主体ごとに違う状態

「既読か」は記事の状態ではなく、ユーザーと記事の関係。中間モデルに持つ。

- 区別不要 → 関連の有無だけ（`has_many :bookmarks`）
- 「オフにした」と「未操作」を区別 → 中間に boolean + `first_or_create.update!`

HABTM は使わない。

## 3. enum — 3 値以上のライフサイクル・設定値

```ruby
enum :status, %w[ pending processing completed failed ].index_by(&:itself), default: :pending
```

文字列保存（整数は差し込み不可）。DB にも `null: false` + `default:`。
2値でも、増える見込みがあるか、各値が否定ではなく一段階なら enum 可。
`case status` が何度も出たら STI を疑う。

## 4. has_one レコード — 付随属性がある可逆状態

SKILL.md の3問で1つでも Yes ならレコード。

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
    unless archived?
      transaction do
        unpublish
        create_archival!(user: user)
      end
    end
  end
end
```

`archived_at` / `archived_by` は `archival` に委譲。エンドレスメソッドに条件修飾子を付けない（`controllers.md`）。

## 5. timestamp / boolean

- **timestamp**: 「いつ」だけ。誰が文脈から一意（`notifications.read_at`）。誰が可変なら §4
- **boolean**: 付随なし。必ず `null: false` + `default:`。操作のリソース化は独立判断

## 状態カラムを増やす前

| つい書きたくなるもの | だいたい正しい形 |
|---|---|
| `archived` boolean / status に可逆トグル | 誰が・いつ要るなら `has_one`。直交は別カラム・別レコード |
| `deleted` | `has_one :trashing` か本当に消す |
| `published` + `published_at` | どちらか一方（timestamp があれば boolean は導出） |
| `read_post_ids` (配列/JSON) | ジョインモデル |
| 同時に立てない / 独立に立つ | enum 1本 / カラム・レコードを分ける |

## 状態遷移

冪等（`unless archived?`。コントローラで存在チェックしない）/
依存はモデル側 / 副作用は `transaction` /
状態機械gemは本当に複雑になるまで入れない。
