# コントローラとルーティング

判断フローC の詳細。裏どりは `evidence.md` を参照。
コード例はすべて架空ドメイン（`Post` / `Invoice`）で書いた自作の最小例。

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
| ドラッグ＆ドロップで閉じる | `namespace :drops { resource :closure }` | `Posts::Drops::ClosuresController#create` |
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
    resources :comments
  end
end
```

- `scope module: :posts` で `app/controllers/posts/` 配下に置く
- 単数の状態は `resource`（`:id` を取らない）、集合は `resources`
- **ネストは 1 段まで**。それ以上深くなるなら `namespace` を切って浅く始める

```ruby
namespace :comments do
  resources :reactions, only: %i[ create destroy ]
end
```

## `*Scoped` concern で親と認可を解決する

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

**要点は「認可されたスコープから find する」こと。**
`Post.find(params[:post_id])` してから権限チェックするのではなく、
`Current.user.accessible_posts.find(...)` にすれば、権限が無ければ `RecordNotFound` になり、
チェック漏れが構造的に起きない。

複数のコントローラで共有するビュー用のヘルパ（Turbo Stream の再描画など）も
この concern に置ける。

## 認可は `ensure_*` の `before_action`

```ruby
class PostsController < ApplicationController
  before_action :set_post, only: %i[ show edit update destroy ]
  before_action :ensure_permission_to_administer_post, only: %i[ destroy ]

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
- **判定ロジックはモデル側**（`Current.user.can_administer?(post)`）。コントローラは呼ぶだけ
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

エンドレスメソッド定義（`def foo = bar`）に `unless` / `if` の修飾子を付けてはいけない。
`def ensure_admin = head :forbidden unless Current.user.admin?` は
`(def ensure_admin = head :forbidden) unless Current.user.admin?` と解釈され、
**メソッド定義そのものがクラス読み込み時の条件分岐になる**
（クラス定義時点の `Current.user` は nil なので起動時に `NoMethodError`）。
修飾子が要るときは通常の `def ... end` で書く。

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

トランザクション・イベント記録・関連レコードの後始末はすべてモデル側（`Post#publish`）に置く。
コントローラが知っているのは「誰の要求か」「何を呼ぶか」「どう返すか」の 3 つだけ。

**素の ActiveRecord 操作をそのまま書くのは許容。** `@post.comments.create!(comment_params)`
のような 1 行を `Post#add_comment` に包む必要はない。
モデルのメソッドに移すべきなのは、**複数の手続きが束になったとき**。

## 書き込みは bang メソッド

```ruby
def update
  @post.update! post_params        # 失敗＝バグなので 500 でよい
  redirect_to @post
end
```

バリデーション失敗を UI で扱う経路だけ、明示的に分岐する。

```ruby
if @signup.create
  redirect_to root_url
else
  render :new, status: :unprocessable_entity
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

- Rails 8 以降は `params.expect`。キーが無い／型が違うときに `ParameterMissing` を返し、
  `permit` の「黙って落とす」挙動を避けられる
- `wrap_parameters` をクラス冒頭に置いて、HTML フォームと JSON API の入力形を揃える
- ネストは `params.expect(post: [ :title, tag_ids: [] ])`

## 非同期は `_later`

```ruby
included do
  after_update_commit :reindex_later, if: :saved_change_to_body?
end

def reindex
  SearchEntry.find_or_initialize_by(searchable: self).update!(content: body.to_plain_text)
end

private
  def reindex_later
    Post::ReindexJob.perform_later(self)
  end
```

```ruby
class Post::ReindexJob < ApplicationJob
  def perform(post) = post.reindex
end
```

- ジョブクラスは 1 行。ロジックはモデルに置く
- キューに積むメソッドは `_later` サフィックス
- 同期版と非同期版が同名で衝突するときだけ `_now` を使う（実際にはほとんど起きない）

## レビューで見るところ

- [ ] `member do post :xxx end` が無いか
- [ ] コントローラ名が `Xxx::YyysController` の形になっているか
- [ ] `set_xxx` が認可済みスコープから find しているか（`Model.find` になっていないか）
- [ ] 認可が `ensure_*` の `before_action` に出ているか（アクション本体に埋まっていないか）
- [ ] アクションが 5 行を超えていないか。超えているならモデルに移せる塊がある
- [ ] 書き込みが bang か、失敗を扱う分岐があるか
