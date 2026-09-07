# コントローラとルーティング

「この操作をどう公開するか」の判断。裏どりは `evidence.md` を参照。
コード例はすべて架空ドメイン（`Post` / `Invoice`）で書いた自作の最小例。

## 原則: カスタムアクションを足さず、新しいリソースを作る

```ruby
# 悪い
resources :posts do
  member do
    post :publish
    post :unpublish
    post :archive
  end
end
```

```ruby
# 良い
resources :posts do
  scope module: :posts do
    resource :publication   # POST = 公開、DELETE = 非公開
    resource :archival      # POST = アーカイブ、DELETE = 復帰
  end
end
```

7 つの標準アクション（index / show / new / create / edit / update / destroy）以外を
コントローラに書きたくなったら、**そこに新しい名詞が隠れている**。

## 動詞をリソース名詞に変換する

| やりたい操作 | リソース | コントローラ |
|---|---|---|
| 公開する／取り消す | `resource :publication` | `Posts::PublicationsController#create / #destroy` |
| アーカイブする／戻す | `resource :archival` | `Posts::ArchivalsController#create / #destroy` |
| 承認する | `resource :approval` | `Invoices::ApprovalsController#create` |
| ログイン／ログアウト | `resource :session` | `SessionsController#create / #destroy` |
| フォロー／解除 | `resources :follows` | `Users::FollowsController#create / #destroy` |
| いいね | `resources :reactions` | `Posts::ReactionsController` |
| 既読にする／戻す | `resource :reading` | `Notifications::ReadingsController#create / #destroy` |
| 上へ移動 | `resource :higher_position` | `Posts::HigherPositionsController#update` |
| 別のカテゴリへ移す | `resource :category` | `Posts::CategoriesController#update` |
| ドラッグ＆ドロップで閉じる | `namespace :drops { resource :closure }` | `Columns::Cards::Drops::ClosuresController#create` |
| 一括既読 | `resource :bulk_reading, only: :create` | `Notifications::BulkReadingsController#create` |
| 検索する | `resource :search` / `resources :queries` | `SearchesController#show` |
| 招待を再送する | `resources :invitations` の `create` をもう一度 | 同じリソースの再作成 |

**命名のコツ**: 動詞を名詞化する（publish → publication、close → closure、
archive → archival、read → reading、approve → approval）。
自然な名詞が無ければ、その操作が生む「もの」を探す（移動 → `move`、
ドロップ操作 → `drop`、切り替え → 切り替え先の名前そのもの）。

**トグルを 1 アクションにしない。** `POST /toggle` ではなく `create` と `destroy` に分ける。
冪等性が保て、UI 側でどちらを叩くかが状態から決まる。

## ネストの形

```ruby
resources :posts do
  scope module: :posts do
    resource  :publication
    resource  :archival
    resources :comments do
      resources :reactions, module: :comments
    end
  end
end
```

- `scope module: :posts` で `app/controllers/posts/` 配下に置く
- 単数の状態は `resource`（`:id` を取らない）、集合は `resources`
- **ネストは 1 段まで**。それ以上深くなるなら `namespace` を切って浅く始める

```ruby
# 深くなりすぎる場合はトップレベルの namespace に逃がす
namespace :comments do
  resources :reactions, only: %i[ create destroy ]
end
```

## `*Scoped` concern で親と認可を解決する

同じ親を持つコントローラ群は、親の解決を concern に括り出す。

```ruby
# app/controllers/concerns/post_scoped.rb
module PostScoped
  extend ActiveSupport::Concern

  included do
    before_action :set_post
  end

  private
    def set_post
      # 認可済みのスコープから引く: 引けた時点でアクセス権がある
      @post = Current.user.accessible_posts.find(params[:post_id])
    end

    def ensure_permission_to_administer_post
      head :forbidden unless Current.user.can_administer?(@post)
    end
end
```

```ruby
class Posts::ArchivalsController < ApplicationController
  include PostScoped

  def create
    @post.archive
    redirect_to @post
  end

  def destroy
    @post.unarchive
    redirect_to @post
  end
end
```

**要点は「認可されたスコープから find する」こと。**
`Post.find(params[:post_id])` してから権限チェックするのではなく、
`Current.user.accessible_posts.find(...)` にすれば、権限が無ければ `RecordNotFound` になる。
チェック漏れが構造的に起きない。

複数のコントローラで共有するビュー用のヘルパ（Turbo Stream の再描画など）も
この concern に置ける。

## 認可は `ensure_*` の `before_action`

```ruby
class PostsController < ApplicationController
  before_action :set_post, only: %i[ show edit update destroy ]
  before_action :ensure_permission_to_administer_post, only: %i[ destroy ]

  # ...

  private
    def set_post
      @post = Current.user.accessible_posts.find(params[:id])
    end

    def ensure_permission_to_administer_post
      head :forbidden unless Current.user.can_administer?(@post)
    end
end
```

- 名前は `ensure_*`。`check_*` / `authorize_*` ではなく「〜であることを保証する」
- 失敗は `head :forbidden`。例外 + `rescue_from` の間接経路を作らない
- **判定ロジックはモデル側**（`Current.user.can_administer?(post)`）。
  コントローラは呼ぶだけ
- 認可 gem（Pundit / CanCanCan）は入れない。`Current.user.xxx_posts` のスコープと
  `can_*?` の述語メソッドで足りる

アプリ全体に効く認可は `ApplicationController` に include する concern にし、
除外用のクラスマクロを提供する。

```ruby
module Authorization
  extend ActiveSupport::Concern

  included do
    before_action :ensure_authenticated
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :ensure_authenticated, **options
    end
  end

  private
    def ensure_admin
      head :forbidden unless Current.user.admin?
    end
end
```

エンドレスメソッド定義（`def foo = bar`）に `unless` / `if` の修飾子を付けてはいけません。
`def ensure_admin = head :forbidden unless Current.user.admin?` は
`(def ensure_admin = head :forbidden) unless Current.user.admin?` と解釈され、
**メソッド定義そのものがクラス読み込み時の条件分岐になります**
（クラス定義時点の `Current.user` は nil なので起動時に `NoMethodError`）。
修飾子が要るときは通常の `def ... end` で書きます。

## アクションは 1〜3 行

```ruby
class Posts::PublicationsController < ApplicationController
  include PostScoped

  def create
    @post.publish

    respond_to do |format|
      format.turbo_stream
      format.json { head :no_content }
    end
  end

  def destroy
    @post.unpublish

    respond_to do |format|
      format.turbo_stream
      format.json { head :no_content }
    end
  end
end
```

トランザクション・イベント記録・関連レコードの後始末はすべてモデル側
（`Post#publish`）に置く。コントローラが知っているのは
「誰の要求か」「何を呼ぶか」「どう返すか」の 3 つだけ。

**素の ActiveRecord 操作をそのまま書くのは許容**。

```ruby
def create
  @comment = @post.comments.create!(comment_params)
end
```

モデルのメソッドに移すべきなのは、**複数の手続きが束になったとき**。
1 行の `create!` を `Post#add_comment` に包む必要はない。

## 書き込みは bang メソッド

```ruby
def update
  @post.update! post_params        # 失敗＝バグなので 500 でよい
  redirect_to @post
end
```

バリデーション失敗を UI で扱う経路だけ、明示的に分岐する。

```ruby
def create
  @signup = Signup.new(signup_params)

  if @signup.create
    redirect_to root_url
  else
    render :new, status: :unprocessable_entity
  end
end
```

「常に bang」ではなく「**失敗をユーザーに見せない経路は bang**」。
`create` / `update` の戻り値を無視して成功扱いする、が最悪。

## strong parameters

```ruby
class PostsController < ApplicationController
  wrap_parameters :post, include: %i[ title body category_id ]

  private
    def post_params
      params.expect(post: %i[ title body category_id ])
    end
end
```

- Rails 8 以降は `params.expect`（`require(...).permit(...)` の置き換え）。
  キーが無い／型が違うときに `ParameterMissing` を返し、
  `permit` の「黙って落とす」挙動を避けられる
- `wrap_parameters` をクラス冒頭に置いて、HTML フォームと JSON API の入力形を揃える
- ネストは `params.expect(post: [ :title, tag_ids: [] ])`

## `Current` の使い方

```ruby
class Current < ActiveSupport::CurrentAttributes
  attribute :session, :user, :account
  attribute :request_id, :user_agent, :ip_address

  def session=(value)
    super
    self.user = value&.user
  end
end
```

- 入れるのは**認証コンテキストとリクエストメタ情報だけ**。ドメインの状態は入れない
- セットするのは認証の concern（`before_action`）1 箇所
- モデル側は `belongs_to :author, default: -> { Current.user }` や
  `def archive(user: Current.user)` のようにデフォルト値として参照する。
  引数で上書きできる形にしておくと、ジョブやテストから使える
- ジョブは `Current` を引き継がない。必要なら明示的にシリアライズして復元する

## 非同期は `_later`

```ruby
module Post::Indexable
  extend ActiveSupport::Concern

  included do
    after_update_commit :reindex_later, if: :saved_change_to_body?
  end

  def reindex
    SearchIndex.upsert!(searchable: self, content: body.to_plain_text)
  end

  private
    def reindex_later
      Post::ReindexJob.perform_later(self)
    end
end
```

```ruby
class Post::ReindexJob < ApplicationJob
  def perform(post)
    post.reindex
  end
end
```

- ジョブクラスは 1 行。ロジックはモデルに置く
- キューに積むメソッドは `_later` サフィックス
- 同期版と非同期版が同名で衝突するときだけ `_now` を使う
  （実際にはほとんど起きない。素の名前のままでよい）

## レビューで見るところ

- [ ] `member do post :xxx end` が無いか
- [ ] コントローラ名が `Xxx::YyysController` の形になっているか
- [ ] `set_xxx` が認可済みスコープから find しているか（`Model.find` になっていないか）
- [ ] 認可が `ensure_*` の `before_action` に出ているか（アクション本体に埋まっていないか）
- [ ] アクションが 5 行を超えていないか。超えているならモデルに移せる塊がある
- [ ] 書き込みが bang か、失敗を扱う分岐があるか
- [ ] `params.permit` の結果を検証せずに `new` に渡していないか
