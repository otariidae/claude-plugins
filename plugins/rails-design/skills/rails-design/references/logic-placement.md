# ロジックの置き場（concern と PORO）

判断フローA の詳細。
一般的なRailsの書き方は前提とし、判断が変わる点だけを書いている。

## concern は 2 種類ある

| | モデル固有 concern | 横断 concern |
|---|---|---|
| 置き場 | `app/models/post/publishable.rb` | `app/models/concerns/searchable.rb` |
| モジュール名 | `Post::Publishable` | `Searchable` |
| 使うモデル | 1 つだけ | 2 つ以上 |
| 数 | 多い | 少ない |

**まず必ずモデル固有として書く。** 2 つ目のモデルが同じものを欲しがった時点で、はじめて
`app/models/concerns/` に引き上げる。

モデル名前空間下にあるので、`Post` 側は `include Publishable` と短く書ける。

## 何が 1 つの concern になるか

**1つのユーザーから見える機能 = 1 concern。** 関連 + スコープ + 述語 + 操作 + コールバックが1ファイルに揃い、消すときはファイルごと消せる。

| 良い切り方 | 悪い切り方 |
|---|---|
| `Post::Publishable` / `Post::Archivable` — 1機能 | `Post::Associations` / `Post::Validations` — Railsの**機構**で切っている |
| | `Post::Helpers` / `Post::Utils` — 中身を説明していない |
| | `Post::Part1` — 行数だけで切った証拠 |

### 命名

すべて**形容詞か名詞**。動詞にしない（`Post::DoPublish` は不可）。

| 形 | 意味 | 例 |
|---|---|---|
| `-able` | その振る舞いを持てる | `Publishable`, `Archivable`, `Assignable` |
| 形容詞 | その性質を帯びる | `Golden`, `Colored`, `Positioned` |
| 複数形名詞 | その集合を持つ | `Comments`, `Mentions`, `Statuses` |

## 横断 concern はテンプレートメソッドで書く

骨格を横断concernに、モデル固有の埋め方を**同名のモデル固有concern**に置く。
横断concernを `Post` から直接includeしない。

```ruby
# app/models/concerns/searchable.rb — 骨格と穴
module Searchable
  extend ActiveSupport::Concern

  included do
    after_update_commit :reindex_for_search
  end

  private
    # 以下は include するモデル側が実装する
    # - search_title:   検索結果に出す見出し
    # - search_content: 全文検索の対象本文

    def searchable? = true   # テンプレートメソッド（デフォルトあり）
end

# app/models/post/searchable.rb — 穴を埋める
module Post::Searchable
  extend ActiveSupport::Concern

  include ::Searchable       # `::` を付けないと自分自身を再帰的に指す

  def search_title   = title
  def search_content = body.to_plain_text
  def searchable?    = published?   # Post ではドラフトを索引しない
end
```

「モデル側が実装するもの」はコメントで列挙し、デフォルトを与えられるものは
`# テンプレートメソッド` と書いてデフォルト実装を置く。
スコープを同時に足すときは `included do ... include ::Searchable ... end` の形になる。

### パラメータ化するときは class_methods の DSL

モデルごとに「親の辿り方」が違うような横断concernは、`class_methods do` に宣言用マクロを置き、
`define_method` でモデルごとの差分を注入する
（`positioned_within :book, association: :chapters` のような呼び出し形）。
コントローラ側の除外マクロ（`allow_unauthenticated_access`）も同じ形。

### 依存の向き

- モデル固有concernは、本体のカラム・関連を参照してよい
- 横断concernがinclude先の実装に依存するときは、**必ずテンプレートメソッド経由**
- concern同士の相互参照は避ける
- クラスメソッドを増やすときは `class_methods do`。`ClassMethods` を手書きしない

---

## PORO の 4 分類

主語テスト（SKILL.md 判断フローA）で主語になる既存モデルが見つからないときだけPORO。
そのPORO自身が主語の名前を名乗る。

### 1. 手続きの主体

複数モデルにまたがる1回きりの処理。`ActiveModel::Model` を include して、
バリデーションとエラーをコントローラに返せるようにする（`Signup`, `Import`, `FirstRun`）。
`on:` コンテキストの罠は SKILL.md「個別の指針」を参照。

### 2. 外部システムとの境界

HTTP・SDK・ファイル形式など、**アプリの外側との会話**を1クラスに閉じる。
ドメインモデルは入口だけを持ち、通信の詳細を知らない。

`Payment::Charge` が HTTP・タイムアウト・プロバイダ固有のレスポンス解釈を持ち、
プロバイダのエラーをアプリの語彙に翻訳する（選び方は `error-handling.md` §4）。
`Invoice::Payable#pay` は `Payment::Charge.new(...).execute` を呼んで結果を保存するだけ。

プロバイダが複数あるなら抽象基底 + サブクラスにし、基底の公開メソッドは
`raise NotImplementedError` で穴を開ける。

**例外**: 「試行そのものを記録に残す」要件がある外部通信はARモデルにしてよい
（`Webhook::Delivery < ApplicationRecord` が state の enum を持ち自分でHTTPも打つ）。

### 3. 値・表現

不変の値、外部レスポンスの表現、ビューに渡す組み立て済みデータ。
`Data.define` / `Struct` / 素のクラスで十分（`Money`, `Invoice::Summary`）。

### 4. 行為者

1つのモデルの一部と言うには重すぎるが、モデルの持ち物ではある処理。
**オーナーモデルの名前空間下**に置き、モデルからの入口は1行にする
（`Post::SlugGenerator` を `Post::Sluggable` の `before_validation` から呼ぶ）。

## 命名と置き場

| 良い | 理由 |
|---|---|
| `Signup` | 「新規登録」という行為そのもの |
| `Invoice::Summary` | 集計結果という値 |
| `Post::SlugGenerator` / `Notifier` / `Account::Seeder` | 行為者名詞（`-er` / `-or`）は普通に使う |
| `Payment::Charge` | 課金という1回の試み |

| 避ける | 理由 |
|---|---|
| `ApproveInvoiceService` | 動詞句 + `Service`。主語が `Invoice` なのでモデルのメソッドにできる |
| `InvoiceManager` / `PaymentHandler` / `SignupProcessor` | 「管理する」「扱う」「処理する」は情報量ゼロ |
| `InvoiceUseCase` / `InvoiceInteractor` | Railsの語彙ではない層を持ち込んでいる |

**置き場は `app/models`。** `app/services` / `app/interactors` / `app/use_cases` は作らない。
オーナーが明確なら名前空間下（`Invoice::Summary`）、アプリ全体の概念ならトップレベル（`Signup`）。

## concern にしないほうがいいもの

| 症状 | 正しい置き場 |
|---|---|
| DBに保存しない計算・組み立て | PORO（値・表現） |
| 外部APIとの通信 | PORO（外部境界） |
| 「誰が何をした」という行為そのもの | イベント型モデル（ARレコード） |
| 画面ごとに違うバリデーション | フォームオブジェクト |
| 2モデル以上にまたがる1回きりの手続き | PORO（手続きの主体） |

concernは「そのモデルの一部として振る舞う」ものだけ。
`self` がそのモデルであることに意味が無いなら、concernではなく別のオブジェクト。
