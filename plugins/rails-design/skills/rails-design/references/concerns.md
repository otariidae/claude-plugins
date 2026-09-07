# concern の設計

モデルが太ってきたときの分割単位。裏どりは `evidence.md` を参照。
コード例はすべて架空ドメイン（`Post` / `Invoice`）で書いた自作の最小例。

## 2 種類ある

| | モデル固有 concern | 横断 concern |
|---|---|---|
| 置き場 | `app/models/post/publishable.rb` | `app/models/concerns/searchable.rb` |
| モジュール名 | `Post::Publishable` | `Searchable` |
| 使うモデル | 1 つだけ | 2 つ以上 |
| 目的 | Post の関心事を分ける | 複数モデルに同じ仕組みを配る |
| 数 | 多い（リファレンス実装では 8 対 69） | 少ない |

**まず必ずモデル固有として書く。** 2 つ目のモデルが同じものを欲しがった時点で、はじめて
`app/models/concerns/` に引き上げる。最初から横断 concern に置くと、1 モデルしか使わない
汎用化されたコードという最悪の形になる。

## モデル固有 concern

`Post` が太ってきたら、行数ではなく**関心の単位**で切る。

```ruby
# app/models/post.rb
class Post < ApplicationRecord
  include Archivable, Commentable, Publishable, Searchable, Taggable

  belongs_to :author, class_name: "User", default: -> { Current.user }

  scope :recent, -> { order(created_at: :desc) }
end
```

```ruby
# app/models/post/publishable.rb
module Post::Publishable
  extend ActiveSupport::Concern

  included do
    has_one :publication, class_name: "Post::Publication", dependent: :destroy

    scope :published, -> { joins(:publication) }
    scope :draft,     -> { where.missing(:publication) }
  end

  def published?
    publication.present?
  end

  def publish
    create_publication! unless published?
  end

  def unpublish
    publication&.destroy
  end
end
```

`Post` 名前空間下にあるので `include Publishable` と短く書ける（`Post::Publishable` が解決される）。

### 何が 1 つの concern になるか

**1 つのユーザーから見える機能 = 1 concern** が目安。関連 + スコープ + 述語メソッド +
操作メソッド + コールバックが 1 ファイルに揃い、その機能を消すときはファイルごと消せる状態。

良い切り方の例（Post に対して）:

- `Post::Publishable` — 公開／非公開
- `Post::Archivable` — アーカイブ
- `Post::Commentable` — コメント
- `Post::Taggable` — タグ付け
- `Post::Searchable` — 検索インデックス連携
- `Post::Broadcastable` — Turbo Stream 配信

悪い切り方:

- `Post::Associations` / `Post::Validations` / `Post::Callbacks` / `Post::Scopes`
  — Rails の**機構**で切っている。関心で切れていないので、機能追加のたびに全ファイルを触る
- `Post::Helpers` / `Post::Utils` — 中身を説明していない
- `Post::Part1` — 行数だけで切った証拠

### 命名

すべて**形容詞か名詞**。動詞にしない。

| 形 | 意味 | 例 |
|---|---|---|
| `-able` | その振る舞いを持てる | `Publishable`, `Archivable`, `Commentable`, `Assignable` |
| 形容詞 | その性質を帯びる | `Golden`, `Colored`, `Positioned` |
| 複数形名詞 | その集合を持つ | `Comments`, `Mentions`, `Statuses`, `Attachments` |

`Post::DoPublish` や `Post::PublishingLogic` のような動詞・説明句は使わない。

## 横断 concern

2 モデル目が同じ仕組みを要求してから作る。置き場は `app/models/concerns/`。

### テンプレートメソッド方式

横断 concern は「骨格 + 埋めるべき穴」として書き、穴はモデル側が埋める。

```ruby
# app/models/concerns/searchable.rb
module Searchable
  extend ActiveSupport::Concern

  included do
    after_create_commit  :index_for_search
    after_update_commit  :reindex_for_search
    after_destroy_commit :remove_from_search_index
  end

  private
    def index_for_search
      search_entry.update!(search_entry_attributes) if searchable?
    end

    def reindex_for_search
      if searchable?
        search_entry.update!(search_entry_attributes)
      else
        remove_from_search_index
      end
    end

    def remove_from_search_index
      SearchEntry.find_by(searchable: self)&.destroy
    end

    def search_entry
      SearchEntry.find_or_initialize_by(searchable: self)
    end

    def search_entry_attributes
      { title: search_title, content: search_content }
    end

    # 以下は include するモデル側が実装する
    # - search_title:   検索結果に出す見出し
    # - search_content: 全文検索の対象本文

    # テンプレートメソッド（デフォルトあり）
    def searchable?
      true
    end
end
```

「モデル側が実装するもの」はコメントで列挙し、デフォルトを与えられるものは
`# テンプレートメソッド` と書いてデフォルト実装を置く。

### 横断 concern は直接 include せず、同名のモデル固有 concern で挟む

これがリファレンス実装で一貫している形。

```ruby
# app/models/post/searchable.rb
module Post::Searchable
  extend ActiveSupport::Concern

  include ::Searchable          # 横断 concern を取り込む

  def search_title
    title
  end

  def search_content
    body.to_plain_text
  end

  def searchable?
    published?                  # Post ではドラフトを索引しない
  end
end
```

```ruby
# app/models/comment/searchable.rb — 別モデルは別の埋め方をする
module Comment::Searchable
  extend ActiveSupport::Concern

  include ::Searchable

  def search_title  = nil
  def search_content = body.to_plain_text
  def searchable?    = post.published?
end
```

**利点**: `Post` のクラス定義は `include Searchable` 1 行のまま。
Post 固有の検索の都合（ドラフトは索引しない、本文は rich text）は `Post::Searchable` に閉じ、
横断 concern を汚さない。`::` を付けてトップレベルの `Searchable` を指す点に注意
（付けないと `Post::Searchable` 自身を再帰的に指す）。

`included do ... end` の中で `include ::Searchable` してもよい。スコープを同時に足すときはこの形になる。

### パラメータ化するときは class_methods の DSL

モデルごとに「親の辿り方」が違うような横断 concern は、宣言用のクラスメソッドを提供する。

```ruby
# app/models/concerns/positionable.rb
module Positionable
  extend ActiveSupport::Concern

  included do
    scope :positioned, -> { order(:position, :id) }
  end

  class_methods do
    def positioned_within(parent, association:)
      define_method :positioned_siblings do
        public_send(parent).public_send(association).positioned
      end

      private :positioned_siblings
    end
  end

  def move_after(other)
    # positioned_siblings を使った並び替え
  end
end
```

```ruby
class Chapter < ApplicationRecord
  include Positionable
  positioned_within :book, association: :chapters
end
```

コントローラ側の `before_action` を注入する concern も同じ形になる（`controllers.md` 参照）。

## 依存の向き

- **モデル固有 concern → 本体のカラム・関連を参照してよい**。`Post::Publishable` が
  `Post` の `published_at` を触るのは正常
- **横断 concern → include 先の実装に依存するときは、テンプレートメソッド経由にする**。
  `Searchable` の中で `post.title` と直接書いてはいけない
- **concern 同士の相互参照は避ける**。`Post::Archivable` が `Post::Publishable` の
  `published?` を呼ぶ程度は許容（同じ `Post` のインスタンスメソッドなので）だが、
  順序依存（include 順を変えると壊れる）が生まれたら設計が間違っている
- **concern がクラスメソッドを増やすときは `class_methods do`**。`ClassMethods` モジュールを
  手書きしない（`ActiveSupport::Concern` が用意している）

## concern にしないほうがいいもの

| 症状 | 正しい置き場 |
|---|---|
| DB に保存しない計算・組み立て | PORO（`poros.md`） |
| 外部 API との通信 | PORO（`poros.md`） |
| 「誰が何をした」という行為そのもの | イベント型モデル（AR レコード） |
| 画面ごとに違うバリデーション | フォームオブジェクト（`ActiveModel::Model` の PORO） |
| 2 モデル以上にまたがる 1 回きりの手続き | PORO |

concern は「そのモデルの一部として振る舞う」ものだけ。`self` がそのモデルであることに
意味が無いなら、concern ではなく別のオブジェクト。
