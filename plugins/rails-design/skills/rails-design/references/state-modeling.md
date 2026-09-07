# 状態のモデリング

「この状態をどう持つか」の判断。裏どりは `evidence.md` を参照。
コード例はすべて架空ドメイン（`Post` / `Invoice`）で書いた自作の最小例。

## 判断フロー

上から順に当てはめ、最初に該当したものを採る。

```
1. 型ごとに振る舞いが違う？（メソッドの中身が分岐する）
   ├ 属性も違う  → delegated_type
   └ 属性は同じ  → STI
2. 「誰にとっての状態か」が主体ごとに違う？
   → ジョインモデル（has_many :through）に属性として持つ
3. 3 値以上のライフサイクル・設定値？
   → enum
4. 可逆なオン／オフで、付随する属性（誰が・いつ・キー・理由）が要る？
   → has_one レコード + resource
5. 可逆なオン／オフで、「いつ起きたか」だけ要る？
   → nullable timestamp（xxx_at）
6. 可逆なオン／オフで、何も付随しない？
   → boolean（NOT NULL + default）
```

**どの選択肢でも、操作の公開は名詞リソースの CRUD にする**（`controllers.md`）。
カラムの持ち方とエンドポイントの形は独立した判断。

---

## 1. STI / delegated_type — 振る舞いが違う

「`if type == :xxx` でメソッドの中身が分岐する」なら型が違う。

### STI: 同じカラム構成で振る舞いだけ違う

```ruby
# rooms テーブルに type カラム（string, null: false）
class Channel < ApplicationRecord
  scope :publics,  -> { where(type: "Channels::Public") }
  scope :privates, -> { where(type: "Channels::Private") }

  def public?  = is_a?(Channels::Public)
  def private? = is_a?(Channels::Private)

  # 型ごとに上書きされる既定値
  def default_notification_level = "mentions"
end

class Channels::Public < Channel
  after_save_commit :grant_membership_to_everyone, if: -> { type_previously_changed?(to: "Channels::Public") }
end

class Channels::Private < Channel
  def default_notification_level = "everything"
end
```

型の変更を許す／許さないは明示的にバリデーションで書く。

```ruby
validate :private_channels_keep_their_type, on: :update

private
  def private_channels_keep_their_type
    if type_changed? && type_was == "Channels::Private"
      errors.add :type, "は非公開チャンネルでは変更できません"
    end
  end
```

### delegated_type: 属性構成そのものが違う

```ruby
class Entry < ApplicationRecord
  delegated_type :entryable, types: %w[ Article Image Embed ], dependent: :destroy
  belongs_to :book

  delegate :searchable_content, to: :entryable
end

module Entryable
  extend ActiveSupport::Concern

  included do
    has_one :entry, as: :entryable, inverse_of: :entryable, touch: true
    delegate :title, to: :entry
  end

  def searchable_content = nil   # サブタイプが上書きする
end

class Article < ApplicationRecord
  include Entryable
  has_rich_text :body
  def searchable_content = body.to_plain_text
end

class Image < ApplicationRecord
  include Entryable
  has_one_attached :file
  def searchable_content = caption
end
```

共通のカラム（position, title, status）は `entries` に、
型固有のカラムは各テーブルに。STI の NULL だらけのテーブルを避けられる。

**STI にしないほうがいいケース**: 「振る舞いは同じで値が違うだけ」。それは enum。

---

## 2. ジョインモデルの属性 — 主体ごとに違う状態

「この記事は既読か」は記事の状態ではなく、**ユーザーと記事の関係の状態**。
`posts.read` のようなカラムは作れない。

```ruby
class Post < ApplicationRecord
  has_many :subscriptions, dependent: :destroy
  has_many :subscribers, -> { merge(Subscription.subscribed) }, through: :subscriptions, source: :user

  def subscribed_by?(user)   = subscription_for(user)&.subscribed?
  def subscription_for(user) = subscriptions.find_by(user: user)

  def subscribe(user)   = subscriptions.where(user: user).first_or_create.update!(subscribed: true)
  def unsubscribe(user) = subscriptions.where(user: user).first_or_create.update!(subscribed: false)
end

class Subscription < ApplicationRecord
  belongs_to :user
  belongs_to :post, touch: true

  scope :subscribed,   -> { where(subscribed: true) }
  scope :unsubscribed, -> { where(subscribed: false) }
end
```

ここで `subscribed` を **boolean にして「レコードが無い＝未購読」にしない**理由:
「一度購読して自分で解除した」と「まだ触っていない」を区別する必要があるから
（自動購読のロジックが、明示的に解除した人を再購読させないため）。
区別が要らないなら `has_many :bookmarks` の有無だけで表す。

`has_many :through` を使い、`has_and_belongs_to_many` は使わない。
関係そのものが属性（いつ・どの役割で・どの通知設定で）を持てるようにする。

---

## 3. enum — 3 値以上のライフサイクル・設定値

```ruby
class Import < ApplicationRecord
  enum :status, %w[ pending processing completed failed ].index_by(&:itself), default: :pending
end

class User::Settings < ApplicationRecord
  enum :digest_frequency, %i[ never daily weekly monthly ], default: :weekly
end
```

- `%w[ ... ].index_by(&:itself)` で DB に文字列を入れる（整数だと後から値を差し込めない）
- スコープが不要なら `scopes: false`、名前が衝突するなら `prefix:` / `suffix:`
- `null: false` + `default:` を DB 側にも入れる

**2 値でも enum にしてよい場合**: 値が増える見込みがあるとき、
または各値が「否定」ではなくそれ自体で一段階を成すとき。

```ruby
# drafted は「published でない」ではなく、それ自体が下書きという段階
enum :status, %w[ drafted published ].index_by(&:itself)
```

**enum にしないほうがいいケース**: 値ごとにメソッドの中身が変わる → STI。
`case status when ... end` がモデルの中に何度も出てきたら enum を疑う。

---

## 4. has_one レコード + resource — 付随する属性がある可逆状態

これが 37signals 流でいちばん特徴的な形。

```ruby
# app/models/post/archivable.rb
module Post::Archivable
  extend ActiveSupport::Concern

  included do
    has_one :archival, class_name: "Post::Archival", dependent: :destroy

    scope :archived, -> { joins(:archival) }
    scope :active,   -> { where.missing(:archival) }
  end

  def archived?    = archival.present?
  def archived_at  = archival&.created_at
  def archived_by  = archival&.user

  def archive(user: Current.user, reason: nil)
    unless archived?
      transaction do
        create_archival!(user: user, reason: reason)
        track_event :archived, creator: user
      end
    end
  end

  def unarchive(user: Current.user)
    if archived?
      transaction do
        archival.destroy
        track_event :unarchived, creator: user
      end
    end
  end
end
```

```ruby
# app/models/post/archival.rb — 数行で済む
class Post::Archival < ApplicationRecord
  belongs_to :post, touch: true
  belongs_to :user, optional: true

  validates :reason, length: { maximum: 500 }
end
```

```ruby
# config/routes.rb
resources :posts do
  resource :archival, module: :posts   # POST で archive、DELETE で unarchive
end
```

### 何が得られるか

- **「誰が」「いつ」がタダで付く** — `archivals.user_id` と `created_at`
- **付随属性を足せる** — `reason`, `expires_at` などを後から追加してもメインテーブルは無傷
- **クエリが素直** — `joins(:archival)` / `where.missing(:archival)`。
  `where(archived: true)` と違って NULL の三値論理を踏まない
- **期間・実行者での絞り込み** — `where(archivals: { created_at: 1.week.ago.. })`
- **リソースとして自然に公開できる** — `create` / `destroy` がそのまま archive / unarchive

### 何を払うか

- テーブルとファイルが 1 セット増える
- 一覧で使うなら preload 必須（`preload(:archival)`）
- 「archived な Post 一覧」に JOIN が要る（インデックスは張れる）

### boolean にするか判断する 3 つの問い

1. 「誰がやったか」を記録したいか？
2. 「いつやったか」を記録したいか？
3. その状態に固有の属性（理由・トークン・期限）が今あるか、将来ありそうか？

**1 つでも yes ならレコード。全部 no なら boolean。**

---

## 5. nullable timestamp — 「いつ」だけ要る

「誰が」が既に文脈から確定していて、付随属性が要らないケース。

```ruby
class Notification < ApplicationRecord
  belongs_to :user   # 「誰が」はここで確定している

  scope :unread, -> { where(read_at: nil) }
  scope :read,   -> { where.not(read_at: nil) }

  def read?  = read_at.present?
  def read   = update!(read_at: Time.current)
  def unread = update!(read_at: nil)
end
```

`Notification::Reading` レコードを作らないのは、`notifications.user_id` で
「誰が読んだか」が既に一意に決まっており、追加の属性が無いから。

公開はやはりリソース。

```ruby
resources :notifications do
  resource :reading, module: :notifications, only: %i[ create destroy ]
end
```

**timestamp にしないほうがいいケース**: 「誰が」が可変（複数の人が同じレコードを閉じうる）。
その場合は 4 の has_one レコードへ。

---

## 6. boolean — 何も付随しない設定

```ruby
# books.published: boolean, default: false, null: false, index
class Book < ApplicationRecord
  scope :published, -> { where(published: true) }
end
```

- **必ず `null: false` + `default:`** を付ける。三値論理を持ち込まない
- 「機能のオン／オフ」「設定」「所有者しか変えない静的なフラグ」に向く
- 絞り込み条件になるならインデックスを張る

boolean でも操作はリソースで公開してよい。

```ruby
resources :books do
  resource :publication, module: :books, only: %i[ show edit update ]
end
```

```ruby
class Books::PublicationsController < ApplicationController
  include BookScoped
  before_action :ensure_editable, only: %i[ edit update ]

  def update
    @book.update! book_params
    redirect_to @book
  end

  private
    def book_params = params.expect(book: %i[ published slug ])
end
```

---

## 「状態カラムを増やす」前のチェック

| つい書きたくなるもの | だいたい正しい形 |
|---|---|
| `posts.archived` (boolean) | 「誰が・いつ」が要るなら `has_one :archival` |
| `posts.status` に可逆トグルを足す | 直交する状態は別カラム／別レコードに分ける |
| `posts.deleted` | 論理削除。`has_one :trashing` か、そもそも本当に消す |
| `posts.published` + `posts.published_at` | どちらか一方。timestamp があれば boolean は導出できる |
| `users.read_post_ids` (配列/JSON) | ジョインモデル |
| 状態 A と状態 B が同時に立てない | enum 1 本にまとめる |
| 状態 A と状態 B が独立に立つ | カラム／レコードを分ける（enum にまとめない） |

**直交性の確認は必ずやる。** `drafted / published / archived / closed` を 1 つの enum に
まとめると「公開済みでアーカイブ済み」が表せなくなる。逆に、同時に立ちえない値を
別カラムにすると不整合が入る。

## 状態遷移の書き方

状態を変えるメソッドは、**冪等にして、遷移の副作用を transaction で束ねる**。

```ruby
def archive(user: Current.user)
  unless archived?                     # 冪等: 2 回呼んでも 1 回分
    transaction do
      unpublish                        # 前提となる他の状態を整える
      create_archival!(user: user)
      track_event :archived, creator: user
    end
  end
end
```

- `unless archived?` で二重実行を吸収する。コントローラ側で存在チェックしない
- 「アーカイブしたら公開を解く」のような**状態間の依存はモデル側に書く**
- 状態機械 gem（AASM 等）は、遷移が本当に複雑（5 状態 × 条件分岐）になるまで入れない
