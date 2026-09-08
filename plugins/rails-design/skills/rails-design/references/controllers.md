# コントローラとルーティング

判断フローC の詳細。
`respond_to` や strong parameters の書き方そのものは前提として、
**動詞をどの名詞にするか**と**判断が変わる点**だけを書いている。

## 動詞をリソース名詞に変換する

| やりたい操作 | リソース | コントローラ |
|---|---|---|
| 公開する／取り消す | `resource :publication` | `Posts::PublicationsController#create / #destroy` |
| アーカイブする／戻す | `resource :archival` | `Posts::ArchivalsController#create / #destroy` |
| 承認する | `resource :approval` | `Invoices::ApprovalsController#create` |
| 閉じる／再開する | `resource :closure` | `Posts::ClosuresController#create / #destroy` |
| ログイン／ログアウト | `resource :session` | `SessionsController#create / #destroy` |
| フォロー／解除 | `resources :follows` | `Users::FollowsController#create / #destroy` |
| いいね | `resources :reactions` | `Posts::ReactionsController` |
| 既読にする／戻す | `resource :reading` | `Notifications::ReadingsController#create / #destroy` |
| 一括既読 | `resource :bulk_reading, only: :create` | `Notifications::BulkReadingsController#create` |
| 上へ移動 | `resource :higher_position` | `Posts::HigherPositionsController#update` |
| 別のカテゴリへ移す | `resource :category` | `Posts::CategoriesController#update` |
| ドラッグ＆ドロップで閉じる | `namespace :drops { resource :closure }` | `Posts::Drops::ClosuresController#create` |
| 検索する | `resource :search` / `resources :queries` | `SearchesController#show` |
| 招待を再送する | `resources :invitations` の `create` をもう一度 | 同じリソースの再作成 |

**命名のコツ**: 動詞を名詞化する（publish → publication、close → closure、
archive → archival、read → reading、approve → approval）。
自然な名詞が無ければ、その操作が生む「もの」を探す（移動 → `move`、
ドロップ操作 → `drop`、切り替え → 切り替え先の名前そのもの）。

**トグルを1アクションにしない。** `POST /toggle` ではなく `create` と `destroy` に分ける。
冪等性が保て、UI側でどちらを叩くかが状態から決まる。

## ネストの形

- `scope module: :posts` で `app/controllers/posts/` 配下に置く
- 単数の状態は `resource`（`:id` を取らない）、集合は `resources`
- **ネストは1段まで**。それ以上深くなるなら `namespace` を切って浅く始める
  （`namespace :comments do resources :reactions end`）

## `*Scoped` concern で親と認可を解決する

同じ親を持つコントローラ群は、親の解決を concern に括り出す（`PostScoped`, `BoardScoped`）。
共有するビュー用ヘルパ（Turbo Streamの再描画など）もここに置ける。

**要点は「認可されたスコープから find する」こと。**

```ruby
# 良い: 権限が無ければ RecordNotFound になる。チェック漏れが構造的に起きない
@post = Current.user.accessible_posts.find(params[:post_id])

# 悪い: find してから権限チェック。チェックを書き忘れると通ってしまう
@post = Post.find(params[:post_id])
```

## 認可は `ensure_*` の `before_action`

- 名前は `ensure_*`。`check_*` / `authorize_*` ではなく「〜であることを保証する」
- 失敗は `head :forbidden`。例外 + `rescue_from` の間接経路を作らない
- **判定ロジックはモデル側**（`Current.user.can_administer?(post)`）。コントローラは呼ぶだけ
- 認可gem（Pundit / CanCanCan）は入れない。`Current.user.xxx_posts` のスコープと
  `can_*?` の述語メソッドで足りる
- アプリ全体に効く認可は `ApplicationController` に include する concern にし、
  除外用のクラスマクロ（`allow_unauthenticated_access`）を `class_methods do` で提供する

**エンドレスメソッド定義（`def foo = bar`）に `unless` / `if` の修飾子を付けてはいけない。**

```ruby
# 壊れる: (def ensure_admin = head :forbidden) unless Current.user.admin? と解釈される。
# メソッド定義そのものがクラス読み込み時の条件分岐になり、
# クラス定義時点の Current.user は nil なので起動時に NoMethodError
def ensure_admin = head :forbidden unless Current.user.admin?

# 正しい
def ensure_admin
  head :forbidden unless Current.user.admin?
end
```

## アクションは 1〜3 行

トランザクション・イベント記録・関連レコードの後始末はすべてモデル側（`Post#publish`）に置く。
コントローラが知っているのは「誰の要求か」「何を呼ぶか」「どう返すか」の3つだけ
（`@post.publish` してリダイレクトするだけ、が典型）。

1行に詰め込むのは狙わない。`@post.publish && redirect_to(@post)` のような書き方は、
`publish` が falsy を返したときにリダイレクトが起きない。

**素の ActiveRecord 操作をそのまま書くのは許容。** `@post.comments.create!(comment_params)`
のような1行を `Post#add_comment` に包む必要はない。
モデルのメソッドに移すべきなのは、**複数の手続きが束になったとき**。

## bang / strong parameters / 非同期

- **書き込みは bang**（`create!` / `update!` / `destroy!`）。失敗＝バグなので500でよい。
  バリデーション失敗をUIで扱う経路だけ `if @signup.create ... else render :new` と分岐する。
  「常にbang」ではなく「**失敗をユーザーに見せない経路はbang**」。
  `create` / `update` の戻り値を無視して成功扱いする、が最悪
- **Rails 8以降は `params.expect`**。キーが無い／型が違うときに `ParameterMissing` を返し、
  `permit` の「黙って落とす」挙動を避けられる。
  `wrap_parameters` をクラス冒頭に置いてHTMLフォームとJSON APIの入力形を揃える
- **非同期は `_later` サフィックス**。ジョブクラスは1行にしてモデルのメソッドを呼ぶだけにする。
  同期版と非同期版が同名で衝突するときだけ `_now` を使う（実際にはほとんど起きない）
