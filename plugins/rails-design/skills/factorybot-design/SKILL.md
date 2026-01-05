---
name: factorybot-design
description: このスキルはFactoryBotを用いたテストコードの相談やレビューで使用する。FactoryBotのファクトリ定義、trait設計、パフォーマンス最適化、ベストプラクティスに基づいた壁打ち・レビューを行う。
---

# FactoryBot テストデータ設計アドバイザー

FactoryBotを使ったテストデータ設計のレビューと改善提案を行います。

## 基本原則

### 1. 最小限のファクトリ

**バリデーションを通過する最小限の属性のみ定義する**

```ruby
# Bad: 不要な属性、固定値、自動設定される属性
factory :user do
  name { "John Doe" }
  email { "john@example.com" }  # 固定値は複数回実行でエラー
  age { 30 }
  created_at { Time.current }    # 自動設定されるので不要
end

# Good: 必須属性のみ、動的な値
factory :user do
  sequence(:email) { |n| "user#{n}@example.com" }
  password { "password123" }
end
```

動的な値の生成:
- `sequence` でユニーク値
- ブロックでランダム値 (`SecureRandom.alphanumeric(12)`, `rand(18..80).years.ago`)
- Faker gem（バリデーション制約に注意）

### 2. build vs create の使い分け

**ビルド戦略の特性**

- **build**: `initialize_with` に従いインスタンス生成（デフォルトは `.new`）、`after_build` 実行
- **create**: build 後に永続化（デフォルトは `#save!`）、`after_build` → `before_create` → `to_create` → `after_create`
- **build_stubbed**: 偽のActiveRecordオブジェクト、`id` と `persisted?` はセット済み、実際は未保存
- **attributes_for**: 属性ハッシュのみ返す、フック実行なし

**使い分け**

- build で十分: バリデーション、ロジック、属性アクセス、プレゼンテーション
- create が必要: DB制約、関連取得、スコープ、コールバック
- build_stubbed: 最速（仮ID付与、関連取得不可）

```ruby
# バリデーションは build
user = build(:user, email: nil)
expect(user).not_to be_valid

# ユニーク制約は create 必要
create(:user, email: "test@example.com")
user = build(:user, email: "test@example.com")
expect(user).not_to be_valid

# ロジックのみは build_stubbed
article = build_stubbed(:article, title: "Test")
presenter = ArticlePresenter.new(article)
```

### 3. 関連付けの扱い

**必須のbelongs_to関連はデフォルト、任意関連はtraitで**

```ruby
# 必須のbelongs_to関連は association で定義
factory :comment do
  content { "Comment" }
  association :post  # 必須関連
  association :user  # 必須関連
end

# 任意の関連（has_many, has_oneなど）は trait で
factory :post do
  title { "Post" }
  association :author, factory: :user  # 必須

  trait :with_comments do
    transient { comments_count { 3 } }
    after(:create) { |post, ev| create_list(:comment, ev.comments_count, post:) }
  end
end
```

`association`を使う理由:
- `build_stubbed(:comment)` で関連も `build_stubbed` される
- `user { create(:user) }` だと `build(:comment)` でも create が走る

**has_many 関連: 重複生成を避ける**

親が子を持つ場合、ナイーブな定義では子の生成時に親が再生成されてしまう問題がある

**推奨: `instance` 参照で重複回避**
```ruby
factory :author do
  trait :with_post do
    post { association(:post, author: instance) }
  end
end
```

**原則: ファクトリで子を作りすぎない**

関連のカスタマイズはテストコードで明示が無難:
```ruby
# Good: シンプルなファクトリ
factory :author do
  name { "Author" }
end

# テストで関連を明示的に構築
let(:author) { create(:author) }
let!(:published_post) { create(:post, :published, author:) }
let!(:draft_post) { create(:post, :draft, author:) }
```

代替: ヘルパーメソッド
```ruby
def author_with_posts(published: 1, draft: 0)
  create(:author).tap do |author|
    create_list(:post, published, :published, author:)
    create_list(:post, draft, :draft, author:)
  end
end
```

**相互接続関連の `instance` 参照**
```ruby
factory :student do
  school
  profile { association(:profile, student: instance, school:) }
end
```

注意: `initialize_with` 内で `instance` 参照は `nil` になる

### 4. Trait の活用

**関連属性セットと振る舞いをグループ化**

用途: ステータス、オプショナル関連、属性パターン
命名: `with_` (関連), enum値, 形容詞 (`published`)
特性: 合成可能、ネスト可能、親属性を上書き可能、transientと組み合わせ可能

```ruby
factory :article do
  sequence(:title) { |n| "Article #{n}" }
  content { "Content" }

  trait :published do
    status { :published }
    published_at { Time.current }
  end

  trait :with_comments do
    transient { comments_count { 3 } }
    after(:create) { |article, ev| create_list(:comment, ev.comments_count, article:) }
  end

  # trait のネスト
  trait :featured do
    published  # 他の trait を含められる
    featured_at { Time.current }
  end
end

# 組み合わせ可能
create(:article, :published, :with_comments, comments_count: 5)
```

**Fat Factory を避ける**

判断基準:
- 複数のテストで再利用 → trait
- 1〜2箇所のみ → テストコードに直接
- 関連の詳細カスタマイズ → テストコード

```ruby
# Bad: 関連のバリエーション全カバー
trait :with_post
trait :with_new_post
trait :with_published_post
# ...増え続ける

# Good: 基本のみ trait、詳細はテストで
trait :with_posts do
  transient { posts_count { 3 } }
  after(:create) { |user, ev| create_list(:post, ev.posts_count, author: user) }
end

# テストで詳細制御
let(:user) { create(:user) }
before { create(:post, :published, author: user, title: "Important") }
```

### 5. 高度なテクニック

**Transient 属性**

オブジェクトに永続化されず、ファクトリロジックのみで使用:
- コールバックでの条件付きセットアップに便利
- `attributes_for` ではフィルタされる
- 複雑な関連構築を永続化せずに実現

```ruby
trait :with_members do
  transient do
    members_count { 5 }
    member_roles { [:developer] }
  end
  after(:create) do |team, ev|
    ev.members_count.times { |i| create(:membership, team:, role: ev.member_roles[i % ev.member_roles.length]) }
  end
end

create(:team, :with_members, members_count: 10, member_roles: [:admin, :developer])
```

**コールバック**

利用可能: `before_all`, `after_build`, `before_create`, `after_create`, `after_stub`, `after_all`
- 複数定義可能、定義順に実行
- 親ファクトリから継承、親が先に実行
- ブロックは `|instance, evaluator|` を受け取る

```ruby
after(:create) do |user, context|
  user.send_welcome_email if context.send_email
end
```

**継承とネスト**

```ruby
# ネスト推奨（共通バリエーション）
factory :user do
  sequence(:email) { |n| "user#{n}@example.com" }

  factory :admin do
    role { :admin }
  end
end

create(:user)   # 通常
create(:admin)  # 管理者
```

使い分け: 明確に異なるエンティティ → 子ファクトリ、状態の違い → trait

## アンチパターン

1. **ビジネスロジック混入**: ファクトリは単純なデータ生成のみ
2. **デフォルト値過剰**: 必須属性のみ、テスト固有値はテストで設定
3. **build で DB アクセス**: `user { create(:user) }` ではなく `association :user`
4. **無駄な create**: build で済むなら build
5. **名前の不一致**: ファクトリ名とモデル名を一致
6. **同名ファクトリの重複定義**: エラーになる
7. **build_stubbed の誤用**: `Marshal.dump` 不可、関連取得不可に注意

## 黄金律

- **自己完結性**: パラメータなしで有効なレコード生成
- **最小性**: 必要最小限の属性
- **明示性**: 重要な値はテストで明示
- **関心の分離**: 各ファクトリは自身のタイプに集中
- **Fat Factory 回避**: 無理にカバーせずテストコードで構築

## 対話の進め方

1. 既存定義とテストコードでの使われ方を確認
2. 問題特定（パフォーマンス、保守性、不安定性）
3. ガイドラインに基づく改善案提示（複数案あれば提示）
4. Before/After で具体例、理由とトレードオフを説明
5. テストコード修正方法と影響を説明

プロジェクトの文脈を考慮し、段階的な移行方法も提示する。
