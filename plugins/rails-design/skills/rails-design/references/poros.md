# PORO の設計

ActiveRecord を継承しない普通の Ruby オブジェクト。裏どりは `evidence.md` を参照。
コード例はすべて架空ドメイン（`Post` / `Invoice`）で書いた自作の最小例。

## まず「主語テスト」

新しいロジックの置き場に迷ったら、**その処理の主語になれる既存モデルがあるか**を問う。

> 「〜が〜する」と言ったとき、最初の〜に来るのは誰か。

| 言い換え | 主語 | 置き場 |
|---|---|---|
| 「請求書が承認される」 | `Invoice` | `Invoice#approve`（モデル本体か concern） |
| 「記事が公開される」 | `Post` | `Post#publish` |
| 「ユーザーが記事にコメントする」 | `Comment` という行為の記録 | `Comment` モデル（イベント型） |
| 「新規登録する」 | ？ Account でも User でもない | `Signup` PORO |
| 「決済プロバイダに課金リクエストを送る」 | ？ 外部システムとの会話 | `Payment::Charge` PORO |
| 「月次売上を集計して表示する」 | ？ どのレコードでもない | `MonthlySalesReport` PORO |

主語が見つかったら PORO ではない。**`ApproveInvoiceService` を作りたくなったら、
それは `Invoice#approve` と書くべきというサイン。**

主語が見つからないときだけ PORO。そしてその PORO 自身が主語の名前を名乗る。

## 4 つの分類

### 1. 手続きの主体（複数モデルにまたがる 1 回きりの処理）

`ActiveModel::Model` を include して、バリデーションとエラーをコントローラに返せるようにする。

```ruby
# app/models/signup.rb
class Signup
  include ActiveModel::Model
  include ActiveModel::Attributes

  attribute :company_name, :string
  attribute :email_address, :string

  attr_reader :account, :user

  validates :company_name, presence: true, length: { maximum: 100 }
  validates :email_address, format: { with: URI::MailTo::EMAIL_REGEXP }

  def create
    return false unless valid?

    ActiveRecord::Base.transaction do
      @account = Account.create!(name: company_name)
      @user    = @account.users.create!(email_address: email_address, role: :owner)
      @account.seed_starter_content
    end

    true
  rescue ActiveRecord::RecordInvalid => error
    errors.add(:base, "アカウントを作成できませんでした")
    Rails.error.report(error)
    false
  end
end
```

コントローラは Service を挟まず、この PORO を直接呼ぶ。

```ruby
class SignupsController < ApplicationController
  def new
    @signup = Signup.new
  end

  def create
    @signup = Signup.new(signup_params)

    if @signup.create
      start_new_session_for @signup.user
      redirect_to root_url
    else
      render :new, status: :unprocessable_entity
    end
  end

  private
    def signup_params
      params.expect(signup: %i[ company_name email_address ])
    end
end
```

フェーズごとにバリデーションが違うなら `on:` コンテキストを使う。

```ruby
validates :email_address, presence: true, on: :identification
validates :company_name,  presence: true, on: :completion

# 呼び出し側
if signup.valid?(:identification)
```

### 2. 外部システムとの境界

HTTP・SDK・ファイル形式など、**アプリの外側との会話**を 1 クラスに閉じる。
ドメインモデルは入口だけを持ち、通信の詳細を知らない。

```ruby
# app/models/payment/charge.rb — 外部決済プロバイダとの会話だけを持つ
class Payment::Charge
  class Declined < StandardError; end
  class Unavailable < StandardError; end

  TIMEOUT = 10.seconds

  def initialize(amount_cents:, currency:, token:)
    @amount_cents, @currency, @token = amount_cents, currency, token
  end

  def execute
    response = post_to_provider

    case response.code.to_i
    when 200      then Payment::Receipt.new(**parse(response))
    when 402      then raise Declined, parse(response)[:reason]
    else               raise Unavailable, "provider returned #{response.code}"
    end
  rescue Net::OpenTimeout, Net::ReadTimeout
    raise Unavailable, "provider timed out"
  end

  private
    def post_to_provider
      # Net::HTTP / SDK の呼び出しをここに閉じる
    end

    def parse(response)
      # プロバイダ固有の JSON をアプリの語彙に翻訳する
    end
end
```

```ruby
# app/models/invoice/payable.rb — モデル側は入口だけ
module Invoice::Payable
  extend ActiveSupport::Concern

  included do
    has_one :payment, dependent: :destroy
  end

  def paid?
    payment.present?
  end

  def pay(token:)
    receipt = Payment::Charge.new(amount_cents:, currency:, token:).execute
    create_payment!(external_id: receipt.id, paid_at: receipt.completed_at)
  end
end
```

**プロバイダが複数あるなら抽象基底 + サブクラス**にする。基底の公開メソッドは
`raise NotImplementedError` で穴を開けておく。

```ruby
class Payment::Gateway
  def self.for(provider) = const_get(provider.to_s.camelize).new
  def charge(...)        = raise NotImplementedError
end

class Payment::Gateway::Stripe < Payment::Gateway
  def charge(...) = # ...
end
```

**例外**: 「試行そのものを記録に残す」要件がある外部通信は、AR モデルにしてよい。
Webhook の配信のようにリトライ・レスポンス保存・状態遷移が必要なら、
`Webhook::Delivery < ApplicationRecord` が enum の state を持ち、自分で HTTP も打つ形が自然。

### 3. 値・表現

不変の値、外部レスポンスの表現、ビューに渡す組み立て済みデータ。
`Struct` / `Data.define` / 素のクラスで十分。

```ruby
# app/models/money.rb
Money = Data.define(:cents, :currency) do
  def to_s = format("%.2f %s", cents / 100.0, currency)
  def +(other) = with(cents: cents + other.cents)
end

# app/models/invoice/summary.rb — ビューに渡す組み立て済みの塊
class Invoice::Summary
  def initialize(invoices)
    @invoices = invoices
  end

  def total       = Money.new(cents: @invoices.sum(:amount_cents), currency: "JPY")
  def overdue     = @invoices.select(&:overdue?)
  def average     = Money.new(cents: total.cents / count, currency: "JPY") if count.positive?
  def count       = @invoices.size
end
```

### 4. 行為者（ある仕事に特化した小さな道具）

1 つのモデルの一部と言うには重すぎるが、モデルの持ち物ではある処理。
**オーナーモデルの名前空間下**に置く。

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
# app/models/post/sluggable.rb — モデルからの入口は 1 行
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

## 命名

**返すもの・演じる役割を名詞で。**

| 良い | 理由 |
|---|---|
| `Signup` | 「新規登録」という行為そのもの |
| `Invoice::Summary` | 集計結果という値 |
| `Post::SlugGenerator` | slug を作る役 |
| `Payment::Charge` | 課金という 1 回の試み |
| `Notifier` / `Post::ActivityDetector` / `Account::Seeder` | 行為者名詞（`-er` / `-or`）は普通に使う |

| 避ける | 理由 |
|---|---|
| `ApproveInvoiceService` | 動詞句 + `Service`。主語が `Invoice` なのでモデルのメソッドにできる |
| `InvoiceManager` | 何を管理するのか説明していない |
| `PaymentHandler` / `SignupProcessor` | 「扱う」「処理する」は情報量ゼロ |
| `InvoiceUseCase` / `InvoiceInteractor` | Rails の語彙ではない層を持ち込んでいる |

`Service` / `Manager` / `Handler` / `Processor` / `UseCase` は、**中身を説明していない**ので使わない。
`-er` は「何をする役か」を言えているので問題ない。

## 置き場

**`app/models` に置く。** `app/services` / `app/interactors` / `app/use_cases` は作らない。

```
app/models/
├── invoice.rb                    # AR モデル
├── invoice/
│   ├── payable.rb                # concern
│   ├── summary.rb                # PORO（値）
│   └── overdue_reminder.rb       # PORO（行為者）
├── payment/
│   ├── charge.rb                 # PORO（外部境界）
│   └── gateway.rb
├── signup.rb                     # PORO（手続きの主体）
└── money.rb                      # PORO（値）
```

`app/models` は「ActiveRecord のディレクトリ」ではなく「ドメインのディレクトリ」。
PORO も AR も同じ場所に並ぶことで、「モデルにできないか」を先に考える圧力がかかる。

オーナーが明確なら名前空間下（`Invoice::Summary`）、
アプリ全体の概念ならトップレベル（`Signup`, `Money`）。

## 入口はモデル、が原則

外から見た呼び出し口は、できるだけドメインモデルのメソッドにする。

```ruby
# 良い: コントローラはモデルのメソッドを呼ぶ。PORO はその内側
@invoice.send_overdue_reminder

# 良い: 主語になるモデルが無いので PORO を直接呼ぶ
@signup = Signup.new(signup_params)
@signup.create

# 悪い: 主語が Invoice なのに PORO を経由させている
InvoiceReminderService.new(@invoice).call
```

PORO をコントローラから直接呼ぶのは、**その PORO 自身が主語のとき**だけ。
`Signup`, `FirstRun`, `Import` のように、行為そのものが名前になっているケース。
