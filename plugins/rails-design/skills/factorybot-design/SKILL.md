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

**DB保存不要なら build を優先**

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
    after(:create) { |post, ev| create_list(:comment, ev.comments_count, post: post) }
  end
end
```

`association`を使う理由:
- `build_stubbed(:comment)` で関連も `build_stubbed` される
- `user { create(:user) }` だと `build(:comment)` でも create が走る

**逆関連の重複問題**

親から子へ逆方向の関連を定義する場合、inline definitionを使う:
```ruby
factory :post do
  title { "Post" }
  comments { [association(:comment, post: nil)] }  # inline definition
end
```

または trait で柔軟に制御:
```ruby
trait :with_comments do
  transient { comments_count { 3 } }
  after(:create) { |post, ev| create_list(:comment, ev.comments_count, post: post) }
end
```

### 4. Trait の活用

**状態のバリエーション表現に使用**

用途: ステータス、オプショナル関連、属性パターン
命名: `with_` (関連), enum値, 形容詞 (`published`)

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
    after(:create) { |article, ev| create_list(:comment, ev.comments_count, article: article) }
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

**Transient + コールバック**

```ruby
trait :with_members do
  transient do
    members_count { 5 }
    member_roles { [:developer] }
  end
  after(:create) do |team, ev|
    ev.members_count.times { |i| create(:membership, team: team, role: ev.member_roles[i % ev.member_roles.length]) }
  end
end

create(:team, :with_members, members_count: 10, member_roles: [:admin, :developer])
```

**継承とネスト**

```ruby
# ネスト推奨
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
