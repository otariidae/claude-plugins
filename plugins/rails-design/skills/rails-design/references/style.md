# コードスタイル（37signals 流）

fizzy の `STYLE.md` に書かれた規約の要約と、実装で確認した実態。
裏どりは `evidence.md` を参照。

**これはあくまで 37signals のハウススタイル。** 一般的な Ruby スタイルガイドや
rubocop のデフォルトと食い違うものが含まれる。自分のリポジトリに持ち込むかは
チームの判断。持ち込まないなら、少なくとも「なぜそう書くのか」の理由だけ拾えばいい。

## ガード節より展開した条件分岐

**よく誤解されるが、37signals はガード節を推奨していない。逆。**

```ruby
# 彼らの Bad
def visible_tags
  ids = params[:tag_ids]
  return [] unless ids
  Tag.where(id: ids.split(","))
end

# 彼らの Good
def visible_tags
  if ids = params[:tag_ids]
    Tag.where(id: ids.split(","))
  else
    []
  end
end
```

理由は「ガード節はネストすると読みにくい」。両方の分岐が式として並ぶほうが、
何が返るかを一目で追える。

**例外として early return を認めるのは 2 つだけ:**

1. メソッドの**冒頭**での return
2. メソッド本体が自明でなく、数行以上ある場合

```ruby
def after_recorded(record)
  return if record.parent.was_created?

  if record.was_created?
    broadcast_new(record)
  else
    broadcast_change(record)
  end
end
```

状態遷移メソッドも `unless xxx?` で本体を包む形が多い。

```ruby
def archive(user: Current.user)
  unless archived?
    transaction do
      create_archival!(user: user)
      track_event :archived, creator: user
    end
  end
end
```

## 可視性修飾子の下はインデント

```ruby
class Post < ApplicationRecord
  def publish
    # ...
  end

  private
    def assign_slug
      # ...
    end

    def notify_subscribers
      # ...
    end
end
```

- `private` の直下に空行を入れない
- 中身を 1 段インデントする

private メソッドしか持たない module は、先頭で宣言して**インデントしない**。

```ruby
module Post::Indexing
  private

  def reindex_later
    # ...
  end
end
```

rubocop のデフォルト（`Layout/IndentationConsistency: normal`）と衝突する。
採用するなら `EnforcedStyle: indented_internal_methods` を設定する。

## メソッドの並び順

1. クラスメソッド（`class << self` / `def self.xxx`）
2. public メソッド（`initialize` を先頭に）
3. private メソッド

そして **private の中は呼び出し順に縦に並べる**。

```ruby
class Post < ApplicationRecord
  def publish
    validate_publishable
    create_publication
  end

  private
    def validate_publishable
      check_title
      check_body
    end

    def check_title
    end

    def check_body
    end

    def create_publication
    end
end
```

上から読むと処理の流れがそのまま追える。呼び出し元より上に呼び出し先を書かない。

## `!` を付ける基準

**`!` は「同名の非 bang メソッドが存在するとき」だけ付ける。**
破壊的だから付ける、危険だから付ける、ではない。

```ruby
# 良い: save / save!、update / update! の対がある
@post.update!(post_params)

# 良い: 破壊的だが対が無いので ! を付けない
@post.destroy_all_drafts
@archival.destroy
```

Ruby / Rails 自体にも `!` の付かない破壊的メソッドは多い（`Array#push`, `delete`）。
`!` は「危険信号」ではなく「同名の穏やかな版がある」という目印。

## 非同期は `_later`、対になる同期版があるときだけ `_now`

```ruby
module Event::Relaying
  extend ActiveSupport::Concern

  included do
    after_create_commit :relay_later
  end

  def relay_later
    Event::RelayJob.perform_later(self)
  end

  def relay_now
    # 実処理
  end
end

class Event::RelayJob < ApplicationJob
  def perform(event) = event.relay_now
end
```

`_now` が要るのは「非同期版と同期版が同じ名前になってしまう」ときだけ。
別の自然な名前があるなら素の名前でよい。

```ruby
def reindex           # 同期版
def reindex_later     # ジョブに積む
```

実際、リファレンス実装 3 つのアプリコードに `_now` は 1 件も無く、
`_later` だけが広く使われている。

## コントローラとモデルの関係

`STYLE.md` の原文の要点:

- thin controller から rich domain model を直接呼ぶ（vanilla Rails）
- 両者をつなぐための service やその他の仕掛けは使わない
- 素の ActiveRecord 操作をコントローラに書くのは問題ない
- 複雑な振る舞いは、意図が読める名前のモデル API にしてコントローラから直接呼ぶ
- 正当化できるなら service やフォームオブジェクトを使ってもよいが、
  **それらを特別な存在として扱わない**（`app/services` を作らない、
  すべての操作を通す規約にしない）

詳細は `controllers.md` と `poros.md`。

## CRUD コントローラ

エンドポイントはリソースの CRUD としてモデル化する。
標準の CRUD 動詞にきれいに収まらないアクションが出てきたら、
カスタムアクションを足すのではなく**新しいリソースを導入する**。

詳細は `controllers.md`。

## 一行メソッドのエンドレス定義

Ruby 3 のエンドレスメソッド定義を、述語や委譲のような短いメソッドで使う。

```ruby
def published?  = publication.present?
def archived_at = archival&.created_at
def search_title = title
```

複数行になるものには使わない。

## Ruby の新しい記法を使う

- ブロック引数の暗黙変数 `it`（Ruby 3.4）
  ```ruby
  leaves.map { it.leafable.markable }
  ```
- ハッシュの値省略
  ```ruby
  Payment::Charge.new(amount_cents:, currency:, token:)
  ```
- `Data.define` を値オブジェクトに
- パターンマッチは、条件分岐が構造に依存するときだけ

## 全体の姿勢

`STYLE.md` の冒頭が言っているのは要するに:

- 読んで気持ちのいいコードを書くこと自体が仕事の一部
- 迷ったら周りの似たコードを探して合わせる
- 書き方に迷ったら Pull Request で聞く

つまり**一貫性 > 個人の好み**。既存コードと違う書き方をするときは理由が要る。
