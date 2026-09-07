# ロジックの置き場（concern と PORO）

判断フローA の詳細。裏どりは `evidence.md` を参照。
コード例はすべて架空ドメイン（`Post` / `Invoice`）で書いた自作の最小例。

## concern は 2 種類ある

| | モデル固有 concern | 横断 concern |
|---|---|---|
| 置き場 | `app/models/post/publishable.rb` | `app/models/concerns/searchable.rb` |
| モジュール名 | `Post::Publishable` | `Searchable` |
| 使うモデル | 1 つだけ | 2 つ以上 |
| 数 | 多い（リファレンス実装では 8 対 69） | 少ない |

**まず必ずモデル固有として書く。** 2 つ目のモデルが同じものを欲しがった時点で、はじめて
`app/models/concerns/` に引き上げる。最初から横断 concern に置くと、1 モデルしか使わない
汎用化されたコードという最悪の形になる。

`Post` 名前空間下にあるので、`Post` 側は `include Publishable` と短く書ける。

```ruby
class Post < ApplicationRecord
  include Archivable, Commentable, Publishable, Searchable, Taggable

  belongs_to :author, class_name: "User", default: -> { Current.user }
end
```

## 何が 1 つの concern になるか

**1 つのユーザーから見える機能 = 1 concern。** 関連 + スコープ + 述語メソッド +
操作メソッド + コールバックが 1 ファイルに揃い、その機能を消すときはファイルごと消せる状態。

| 良い切り方 | 悪い切り方 |
|---|---|
| `Post::Publishable` — 公開／非公開 | `Post::Associations` / `Post::Validations` / `Post::Callbacks` — Rails の**機構**で切っている。機能追加のたびに全ファイルを触る |
| `Post::Archivable` — アーカイブ | `Post::Helpers` / `Post::Utils` — 中身を説明していない |
| `Post::Commentable` — コメント | `Post::Part1` — 行数だけで切った証拠 |
| `Post::Searchable` — 検索インデックス連携 | |

### 命名

すべて**形容詞か名詞**。動詞にしない。

| 形 | 意味 | 例 |
|---|---|---|
| `-able` | その振る舞いを持てる | `Publishable`, `Archivable`, `Assignable` |
| 形容詞 | その性質を帯びる | `Golden`, `Colored`, `Positioned` |
| 複数形名詞 | その集合を持つ | `Comments`, `Mentions`, `Statuses` |

`Post::DoPublish` や `Post::PublishingLogic` のような動詞・説明句は使わない。

## 横断 concern はテンプレートメソッドで書く

骨格を横断 concern に、モデル固有の埋め方を**同名のモデル固有 concern**に置く。

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

```ruby
# app/models/post/searchable.rb
module Post::Searchable
  extend ActiveSupport::Concern

  include ::Searchable          # `::` を付けないと自分自身を再帰的に指す

  def search_title   = title
  def search_content = body.to_plain_text
  def searchable?    = published?   # Post ではドラフトを索引しない
end
```

**利点**: `Post` のクラス定義は `include Searchable` 1 行のまま。Post 固有の検索の都合は
`Post::Searchable` に閉じ、横断 concern を汚さない。別モデル（`Comment::Searchable`）は
別の埋め方をする。

「モデル側が実装するもの」はコメントで列挙し、デフォルトを与えられるものは
`# テンプレートメソッド` と書いてデフォルト実装を置く。
スコープを同時に足すときは `included do ... include ::Searchable ... end` の形になる。

### パラメータ化するときは class_methods の DSL

モデルごとに「親の辿り方」が違うような横断 concern は、宣言用のクラスメソッドを提供する。

```ruby
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
end

class Chapter < ApplicationRecord
  include Positionable
  positioned_within :book, association: :chapters
end
```

### 依存の向き

- モデル固有 concern は、本体のカラム・関連を参照してよい
- 横断 concern が include 先の実装に依存するときは、**必ずテンプレートメソッド経由**。
  `Searchable` の中に `post.title` と直接書いてはいけない
- concern 同士の相互参照は避ける。include 順を変えると壊れる状態になったら設計が間違っている
- クラスメソッドを増やすときは `class_methods do`。`ClassMethods` を手書きしない

---

## PORO — 主語が見つからないとき

主語テスト（SKILL.md 判断フローA）で主語になる既存モデルが見つからないときだけ PORO。
そしてその PORO 自身が主語の名前を名乗る。

### 1. 手続きの主体（複数モデルにまたがる 1 回きりの処理）

`ActiveModel::Model` を include して、バリデーションとエラーをコントローラに返せるようにする。
実装例は SKILL.md 判断フローA の `Signup`。

`on:` コンテキストを使うときは注意が要る。`valid?(:completion)` が走らせるのは
**「`on:` の無い検証」と「`on: :completion` の検証」だけ**で、`on: :identification` の検証は
素通りする。フェーズを分けるなら各フェーズの入口でそれぞれの `valid?` を呼ぶこと。
1 つのメソッドで全部やるなら `on:` を付けてはいけない（宣言したのに一度も走らない検証ができ、
未検証の値がそのまま保存される）。

### 2. 外部システムとの境界

HTTP・SDK・ファイル形式など、**アプリの外側との会話**を 1 クラスに閉じる。
ドメインモデルは入口だけを持ち、通信の詳細を知らない。

```ruby
# app/models/payment/charge.rb — 外部との会話だけを持つ
class Payment::Charge
  class Declined < StandardError; end
  class Unavailable < StandardError; end

  def initialize(amount_cents:, currency:, token:)
    @amount_cents, @currency, @token = amount_cents, currency, token
  end

  def execute
    response = post_to_provider

    case response.code.to_i
    when 200 then Payment::Receipt.new(**parse(response))
    when 402 then raise Declined, parse(response)[:reason]
    else          raise Unavailable, "provider returned #{response.code}"
    end
  rescue Net::OpenTimeout, Net::ReadTimeout
    raise Unavailable, "provider timed out"
  end

  private
    def post_to_provider = # Net::HTTP / SDK の呼び出しをここに閉じる
    def parse(response)  = # プロバイダ固有の JSON をアプリの語彙に翻訳する
end
```

```ruby
# app/models/invoice/payable.rb — モデル側は入口だけ
module Invoice::Payable
  extend ActiveSupport::Concern

  included do
    has_one :payment, dependent: :destroy
  end

  def paid? = payment.present?

  def pay(token:)
    receipt = Payment::Charge.new(amount_cents:, currency:, token:).execute
    create_payment!(external_id: receipt.id, paid_at: receipt.completed_at)
  end
end
```

プロバイダが複数あるなら抽象基底 + サブクラスにし、基底の公開メソッドは
`raise NotImplementedError` で穴を開けておく。

**例外**: 「試行そのものを記録に残す」要件がある外部通信は AR モデルにしてよい。
リトライ・レスポンス保存・状態遷移が必要な Webhook 配送などは、
`Webhook::Delivery < ApplicationRecord` が state の enum を持ち自分で HTTP も打つ形が自然。

### 3. 値・表現

不変の値、外部レスポンスの表現、ビューに渡す組み立て済みデータ。
`Struct` / `Data.define` / 素のクラスで十分。

```ruby
Money = Data.define(:cents, :currency) do
  def to_s     = format("%.2f %s", cents / 100.0, currency)
  def +(other) = with(cents: cents + other.cents)
end

class Invoice::Summary
  def initialize(invoices)
    @invoices = invoices
  end

  def total   = Money.new(cents: @invoices.sum(:amount_cents), currency: "JPY")
  def overdue = @invoices.select(&:overdue?)
  def count   = @invoices.size

  # エンドレスメソッドに if / unless 修飾子は付けない（定義そのものが条件分岐になる）
  def average
    Money.new(cents: total.cents / count, currency: "JPY") if count.positive?
  end
end
```

### 4. 行為者（ある仕事に特化した小さな道具）

1 つのモデルの一部と言うには重すぎるが、モデルの持ち物ではある処理。
**オーナーモデルの名前空間下**に置き、モデルからの入口は 1 行にする。

```ruby
# app/models/post/slug_generator.rb
class Post::SlugGenerator
  def initialize(post)
    @post = post
  end

  def generate
    base = @post.title.parameterize.presence || "post"
    return base unless taken?(base)

    (2..).lazy.map { "#{base}-#{it}" }.reject { taken?(it) }.first
  end

  private
    def taken?(slug)
      Post.where.not(id: @post.id).exists?(slug: slug)
    end
end
```

```ruby
# app/models/post/sluggable.rb
module Post::Sluggable
  extend ActiveSupport::Concern

  included do
    before_validation :assign_slug, if: -> { slug.blank? }
  end

  private
    def assign_slug
      self.slug = Post::SlugGenerator.new(self).generate
    end
end
```

## 命名と置き場

| 良い | 理由 |
|---|---|
| `Signup` | 「新規登録」という行為そのもの |
| `Invoice::Summary` | 集計結果という値 |
| `Post::SlugGenerator` / `Notifier` / `Account::Seeder` | 行為者名詞（`-er` / `-or`）は普通に使う |
| `Payment::Charge` | 課金という 1 回の試み |

| 避ける | 理由 |
|---|---|
| `ApproveInvoiceService` | 動詞句 + `Service`。主語が `Invoice` なのでモデルのメソッドにできる |
| `InvoiceManager` / `PaymentHandler` / `SignupProcessor` | 「管理する」「扱う」「処理する」は情報量ゼロ |
| `InvoiceUseCase` / `InvoiceInteractor` | Rails の語彙ではない層を持ち込んでいる |

`Service` / `Manager` / `Handler` / `Processor` / `UseCase` は中身を説明していないので使わない。
`-er` は「何をする役か」を言えているので問題ない。

**置き場は `app/models`。** `app/services` / `app/interactors` / `app/use_cases` は作らない。
`app/models` は「ActiveRecord のディレクトリ」ではなく「ドメインのディレクトリ」で、
PORO も AR も同じ場所に並ぶことで「モデルにできないか」を先に考える圧力がかかる。
オーナーが明確なら名前空間下（`Invoice::Summary`）、アプリ全体の概念ならトップレベル（`Signup`）。

## concern にしないほうがいいもの

| 症状 | 正しい置き場 |
|---|---|
| DB に保存しない計算・組み立て | PORO（値・表現） |
| 外部 API との通信 | PORO（外部境界） |
| 「誰が何をした」という行為そのもの | イベント型モデル（AR レコード） |
| 画面ごとに違うバリデーション | フォームオブジェクト（`ActiveModel::Model`） |
| 2 モデル以上にまたがる 1 回きりの手続き | PORO（手続きの主体） |

concern は「そのモデルの一部として振る舞う」ものだけ。
`self` がそのモデルであることに意味が無いなら、concern ではなく別のオブジェクト。
