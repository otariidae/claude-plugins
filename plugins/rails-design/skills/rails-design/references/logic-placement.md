# ロジックの置き場（concern と PORO）

判断が変わる点だけ。

## concern は 2 種類

| | モデル固有 | 横断 |
|---|---|---|
| 置き場 | `app/models/post/publishable.rb` | `app/models/concerns/searchable.rb` |
| モジュール名 | `Post::Publishable` | `Searchable` |
| 使うモデル | 1 つだけ | 2 つ以上 |

**まずモデル固有。** 2 つ目が欲しがった時点で横断へ昇格。

## 1 concern = 1 機能

関連 + スコープ + 述語 + 操作 + コールバックが1ファイル。機構で切らない。

```ruby
# app/models/user/watchable.rb
module User::Watchable
  extend ActiveSupport::Concern

  included do
    has_many :watches, dependent: :destroy
    has_many :watched_posts, through: :watches, source: :post
    scope :watching, ->(post) { joins(:watches).where(watches: { post: post }) }
    after_create_commit :watch_welcome_post
  end

  def watching?(post) = watches.exists?(post: post)

  def watch(post)
    watches.find_or_create_by!(post: post)
  end

  def unwatch(post)
    watches.find_by(post: post)&.destroy!
  end

  private
    def watch_welcome_post = watch(Post.welcome)
end
```

命名は**形容詞か名詞**（動詞不可）。`-able` / 形容詞 / 複数形名詞。

## 横断 concern はテンプレートメソッド

骨格を横断に、埋め方を**同名のモデル固有concern**に。直接 include しない。

```ruby
# app/models/concerns/searchable.rb
module Searchable
  extend ActiveSupport::Concern
  included { after_update_commit :reindex_for_search }
  private
    # モデル側が実装: search_title, search_content
    def searchable? = true
end

# app/models/post/searchable.rb
module Post::Searchable
  extend ActiveSupport::Concern
  include ::Searchable       # `::` 必須（無いと自分を再帰参照）
  def search_title   = title
  def search_content = body.to_plain_text
  def searchable?    = published?
end
```

モデル差分が大きいときは `class_methods do` の DSL（`positioned_within :book, ...`）。
除外マクロ（`allow_unauthenticated_access`）も同じ。

**依存**: 横断が include 先に依存するならテンプレートメソッド経由のみ。相互参照は避ける。
クラスメソッドは `class_methods do`（`ClassMethods` 手書きしない）。

## PORO の 4 分類

主語になる既存モデルが無いときだけ。PORO 自身が主語の名前を名乗る。

| 分類 | 形 | 例 |
|---|---|---|
| 手続きの主体 | `ActiveModel::Model`。コントローラに errors を返す | `Signup`, `Import` |
| 外部境界 | 外側との会話を閉じる。モデルは入口だけ | `Payment::Charge` |
| 値・表現 | `Data.define` / `Struct` | `Money`, `Invoice::Summary` |
| 行為者 | オーナー名前空間下。入口は1行 | `Post::SlugGenerator` |

外部境界の翻訳先は `error-handling.md` §4。
試行を記録する外部通信は AR にしてよい（`Webhook::Delivery`）。
`on:` の罠は SKILL.md「個別の指針」。

**置き場は `app/models`。**
`-er` / `-or`（`Notifier`, `SlugGenerator`）は普通に使う。

| 症状 | 置き場 |
|---|---|
| DBに保存しない計算 | PORO（値） |
| 外部API | PORO（境界） |
| 「誰が何をした」という行為 | イベント型 AR |
| 画面ごとのバリデーション | フォームオブジェクト |
| 複数モデルの1回きり手続き | PORO（手続き） |

`self` がそのモデルであることに意味が無いなら concern ではなく別オブジェクト。
