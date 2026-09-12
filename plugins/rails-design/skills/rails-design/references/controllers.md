# コントローラとルーティング

判断フローC の詳細。**動詞をどの名詞にするか**と判断が変わる点だけ。

## 動詞 → リソース名詞

| 操作 | リソース | コントローラ |
|---|---|---|
| 公開／取消 | `resource :publication` | `Posts::PublicationsController#create / #destroy` |
| アーカイブ／戻す | `resource :archival` | `Posts::ArchivalsController#create / #destroy` |
| 承認 | `resource :approval` | `Invoices::ApprovalsController#create` |
| 閉じる／再開 | `resource :closure` | `Posts::ClosuresController#create / #destroy` |
| ログイン／ログアウト | `resource :session` | `SessionsController#create / #destroy` |
| フォロー／解除 | `resources :follows` | `Users::FollowsController#create / #destroy` |
| いいね | `resources :reactions` | `Posts::ReactionsController` |
| 既読／戻す | `resource :reading` | `Notifications::ReadingsController#create / #destroy` |
| 一括既読 | `resource :bulk_reading, only: :create` | `Notifications::BulkReadingsController#create` |
| 上へ移動 | `resource :higher_position` | `Posts::HigherPositionsController#update` |
| カテゴリ変更 | `resource :category` | `Posts::CategoriesController#update` |
| DnD で閉じる | `namespace :drops { resource :closure }` | `Posts::Drops::ClosuresController#create` |
| 検索 | `resource :search` | `SearchesController#show` |
| 招待再送 | 同じ `invitations#create` | 再作成 |

動詞を名詞化（publish → publication）。無ければ操作が生む「もの」を探す。
**トグルを1アクションにしない**（`create` / `destroy` に分ける）。

## ネスト

`scope module: :posts`。単数状態は `resource`、集合は `resources`。
**ネストは1段まで**（深くなるなら `namespace` で浅く）。

## 認可

親の解決は `*Scoped` concern。**認可済みスコープから find**。

```ruby
@post = Current.user.accessible_posts.find(params[:post_id])  # 良い
@post = Post.find(params[:post_id])                            # 悪い
```

追加認可は `ensure_*` の `before_action` → `head :forbidden`。判定はモデル側。
認可gemはスコープ + `can_*?` で足りるうちは入れない。
全体認可は ApplicationController の concern + `class_methods` の除外マクロ。

**エンドレスメソッドに `if` / `unless` 修飾子を付けない**（定義自体が読み込み時分岐になる）。

```ruby
# 壊れる
def ensure_admin = head :forbidden unless Current.user.admin?

# 正しい
def ensure_admin
  head :forbidden unless Current.user.admin?
end
```

## アクションは 1〜3 行

トランザクション・後始末はモデル側。コントローラは「誰の要求か / 何を呼ぶか / どう返すか」。
`@post.publish && redirect_to(@post)` は falsy 時にリダイレクトしないので避ける。
素の AR 1行（`@post.comments.create!(...)`）は包まなくてよい。束になったらモデルへ。

## bang / params / 非同期

- **失敗をユーザーに見せない経路は bang**。見せる経路だけ `if`
- Rails 8+: `params.expect`。`wrap_parameters` で HTML/JSON の入力形を揃える
- 非同期は `_later`。ジョブは1行。同名衝突時だけ `_now`
