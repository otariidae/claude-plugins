---
name: rails-design
description: このスキルはRailsのモデル設計・コード設計の相談やレビューで使用する。モデリングやテーブル設計が関連する機能追加や改修、モデル構造・関連付け・マイグレーション・バリデーションの検討、concernへの分割、POROやservice/フォームオブジェクトの是非、状態の表現方法（enum・boolean・timestamp・has_one・STI）、RESTリソース（resource / resources）やコントローラの設計、Currentの扱い、およびRailsコードのレビューの際に、Railsのベストプラクティスの知識に基づいて壁打ち・レビューを行う。
---

# Rails モデル設計アドバイザー

Railsのモデル設計の壁打ち相手・レビュアーとして振る舞う。
一般的なRailsの書き方は前提として、**デフォルトの直感と違う判断**だけをここに置いている。

## 1. モデルを見つける

### リソースとイベントの区別
- **リソース系**（物）: `customers`, `products` — 状態や属性を持つ「存在」そのもの
- **イベント系**（こと）: `orders`, `arrivals`, `reservations`
  - 判定: 「〜する」という動詞が成立する / 「〜日」と言える（予約日、注文日）

置き場に迷う処理は、まず**その行為自体をイベント型モデルにできないか**を疑う。
「誰が」「何を」「どうする」を名詞に分解する（注文 → `Order`, `Customer`, `Product`）。

### 命名
クラス名は「返すオブジェクトの名前」を名詞で付ける。ActiveRecordを継承しないPOROでも同じ。

### 主キーに意味を持たせない
主キーは無機質な識別子（ID）。意味のあるコードは別カラムにする。
主キーに意味を載せると、意味が変わったときに関連付け全体に波及する。

---

## 2. 判断フローA: 新しいロジックをどこに置くか

```
1. その処理の主語になれる既存モデルがあるか？
   （「〜が〜する」と言ったときの最初の〜）
   │
   ├ ある → そのモデルのメソッドにする
   │        ├ 本体が薄い / 関心が中心的 → app/models/post.rb に直接
   │        └ 既に他の関心で埋まっている → app/models/post/publishable.rb
   │             └ 2つ目のモデルが同じ仕組みを欲しがったら
   │                → app/models/concerns/publishable.rb に昇格
   │
   └ ない → PORO（app/models 配下。app/services は作らない）
            ├ 複数モデルにまたがる1回きりの手続き → ActiveModel::Model
            ├ 外部システムとの通信 → 境界POROに閉じ、モデルは入口だけ
            ├ 計算結果・表現 → 値オブジェクト（Data.define / Struct）
            └ モデルの持ち物だが重い仕事 → オーナー名前空間下のPORO
```

**主語テスト**

| 言い方 | 主語 | 置き場 |
|---|---|---|
| 「請求書が承認される」 | `Invoice` | `Invoice#approve` |
| 「記事が公開される」 | `Post` | `Post#publish`（`Post::Publishable`） |
| 「ユーザーが記事にコメントする」 | 行為の記録 | `Comment` モデル |
| 「新規登録する」 | 無い | `Signup` PORO |
| 「決済プロバイダに課金する」 | 無い（外部との会話） | `Payment::Charge` PORO |

`ApproveInvoiceService` を作りたくなったら、`Invoice#approve` と書くべきというサイン。
`Service` / `Manager` / `Handler` / `Processor` / `UseCase` は中身を説明していないので使わない。
`-er` / `-or` の行為者名詞（`Notifier`, `Post::SlugGenerator`）は普通に使う。

**concernは行数ではなく関心で切る**。`Post::Associations` / `Post::Validations` のような
Railsの機構での分割は、機能追加のたびに全ファイルを触ることになる。
`Post::Publishable` のように 1機能 = 1ファイル、消すときはファイルごと消せる状態にする。

**横断concernは直接includeしない**。骨格を横断concernにテンプレートメソッドとして書き、
同名のモデル固有concernを挟んで `include ::Searchable` する。

詳細は `references/logic-placement.md`。

---

## 3. 判断フローB: 新しい状態をどう表すか

```
1. 型ごとに振る舞いが違う？（メソッドの中身が分岐する）
   ├ 属性構成も違う → delegated_type
   └ 属性は同じ     → STI
2. 「誰にとっての状態か」が主体ごとに違う？
   → ジョインモデル（has_many :through）の属性にする
3. 3値以上のライフサイクル・設定値？
   → enum（文字列で保存: %w[...].index_by(&:itself)）
4. 可逆なオン/オフで、付随する属性（誰が・いつ・キー・理由）が要る？
   → has_one レコード + resource
5. 可逆なオン/オフで、「いつ」だけ要る？
   → nullable timestamp（xxx_at）
6. 可逆なオン/オフで、何も付随しない？
   → boolean（NOT NULL + default 必須）
```

**booleanかhas_oneレコードかを分ける3つの問い**

1. 「誰がやったか」を記録したいか？
2. 「いつやったか」を記録したいか？
3. その状態に固有の属性（理由・トークン・期限）が今あるか、将来ありそうか？

1つでもYesならレコード、全部Noならboolean。

```ruby
module Post::Archivable
  extend ActiveSupport::Concern

  included do
    has_one :archival, class_name: "Post::Archival", dependent: :destroy

    scope :archived, -> { joins(:archival) }
    scope :active,   -> { where.missing(:archival) }
  end

  def archived? = archival.present?

  def archive(user: Current.user)
    unless archived?          # 冪等にする。コントローラで存在チェックしない
      transaction do
        unpublish             # 状態間の依存はモデル側に書く
        create_archival!(user: user)
      end
    end
  end
end
```

`archived_at` / `archived_by` は `archival&.created_at` / `archival&.user` に委譲する。
条件付きの操作をエンドレスメソッドで書いてはいけない（`controllers.md` の罠を参照）。

レコードにすると「誰が・いつ」がタダで付き、付随属性を後から足してもメインテーブルは無傷。
`where(archived: true)` と違ってNULLの三値論理を踏まず、期間や実行者で絞り込める。
払うのはテーブル1セットとpreloadの手間。

**必ず直交性を確認する**。`drafted / published / archived` を1つのenumにまとめると
「公開済みでアーカイブ済み」が表せなくなる。同時に立ちうる状態は別カラム・別レコードに、
同時に立ちえない値は1つのenumに。

詳細は `references/state-modeling.md`。

---

## 4. 判断フローC: 新しい操作をどう公開するか

```
1. 7つの標準アクション（index/show/new/create/edit/update/destroy）に収まるか？
   ├ 収まる   → 既存のリソースコントローラに書く
   └ 収まらない → そこに新しい名詞が隠れている
        2. 動詞を名詞化する
           publish → publication / close → closure / archive → archival
        3. リソースを追加する（単数の状態は resource、集合は resources）
        4. コントローラは Xxx::YyysController
        5. 親の解決と認可は *Scoped concern に括り出す
        6. 追加の認可は ensure_* の before_action、失敗は head :forbidden
        7. 書き込みは bang。失敗をUIで扱う経路だけ if で分岐
```

```ruby
# 悪い                              # 良い
resources :posts do                 resources :posts do
  member { post :publish }            scope module: :posts do
end                                     resource :publication
                                      end
                                    end
```

`Posts::PublicationsController#create` が公開、`#destroy` が公開解除。
**トグルを1アクションにしない**（`POST /toggle` にしない）。冪等性が保てる。

**`set_post` は認可済みスコープから find する**。
`Post.find(params[:id])` してから権限チェックするのではなく
`Current.user.accessible_posts.find(...)` にすれば、権限が無ければ `RecordNotFound` になり、
チェック漏れが構造的に起きない。認可gem（Pundit / CanCanCan）は、
スコープと `can_*?` 述語で足りるうちは入れない。

動詞→名詞の変換表と詳細は `references/controllers.md`。

---

## 5. 個別の指針

### フォームオブジェクト
画面ごとに違うバリデーション、複数モデルにまたがる入力は
`ActiveModel::Model` + `ActiveModel::Attributes` のPOROにし、**コントローラから直接呼ぶ**。

**`on:` コンテキストの罠**: `valid?(:completion)` が走らせるのは「`on:` の無い検証」と
「`on: :completion` の検証」だけで、`on: :identification` の検証は素通りする。
フェーズを分けるなら各フェーズの入口でそれぞれの `valid?` を呼ぶこと。
1つのメソッドで全部やるなら `on:` を付けてはいけない
（宣言したのに一度も走らない検証ができ、未検証の値がそのまま保存される）。

### アイデンティティ（存在）の最小化
モデルの本質はその「存在」。中心となるテーブルは主キー中心に構成し、
属性は性質ごとに別テーブルへ切り出す。分割の判断基準は
**変更頻度が違う / 秘匿性のレベルが違う / 必須・任意が違う**。
NULL許容カラムが減り、セキュリティ境界が明確になる。

### アイデンティティプールの分離
目的や利用方法が根本的に異なる主体はテーブルを分ける
（一般ユーザーと管理スタッフ、法人顧客と個人顧客）。権限管理の複雑さが大幅に減る。

### プロセスの分離
「登録中のデータ」などフロー完了まで発生しないエンティティは専用テーブルで管理し、
完了時に本テーブルへ作る。不完全なデータが本テーブルに混ざらず、ロールバックも容易。

### 多対多は has_many :through
HABTMは避ける。関連自体が独立したイベントエンティティになり、
「いつ・どの役割で」といった属性を持てる。

### Current の使い方
- 入れるのは**認証コンテキストとリクエストメタ情報だけ**。ドメインの状態は入れない
- モデル側はデフォルト値として参照し、引数で上書きできる形にする
  （`default: -> { Current.user }` / `def archive(user: Current.user)`）
- ジョブは `Current` を引き継がないので、必要なら明示的に渡す

---

## レビュー時チェックリスト

1. **`XxxService` / `app/services` が無いか** — 主語になるモデルがあればそのメソッドに移す
2. **concernが関心単位で切れているか** — `Validations` / `Callbacks` のような機構での分割になっていないか
3. **1モデルしか使わない横断concernが `app/models/concerns/` に無いか** — モデル名前空間下に戻す
4. **新しいboolean/statusカラムに「誰が・いつ」が要らないか** — 要るなら `has_one` レコード
5. **enumに同時に立ちうる状態を詰め込んでいないか** — 直交する状態は別に持つ
6. **booleanに `null: false` + `default:` があるか**
7. **`member do post :xxx end` が無いか** — 名詞リソースに変換する
8. **`set_xxx` が認可済みスコープから find しているか** — `Model.find` の後で権限チェックになっていないか
9. **コントローラのアクションが5行を超えていないか** — 超えているならモデルに移せる塊がある
10. **書き込みがbangか、失敗を扱う分岐があるか** — 戻り値を無視した `save` / `update` が最悪

## 「惰性 → リファレンス実装」対照表

| つい書いてしまう形 | 37signals 流 |
|---|---|
| `ApproveInvoiceService.new(invoice).call` | `invoice.approve` |
| `app/services/` に置く | `app/models/` に置く（POROもモデル） |
| `SignupProcessor` / `PaymentHandler` | `Signup` / `Payment::Charge`（役割を名乗る名詞） |
| `post.rb` に全部書いて800行 | `app/models/post/*.rb` に関心ごとのconcern |
| 最初から `app/models/concerns/` | まずモデル固有concern、2モデル目で昇格 |
| 横断concernを直接include | 同名のモデル固有concernを挟んで `include ::Xxx` |
| `posts.archived` (boolean) | `has_one :archival`（誰が・いつが要るなら） |
| `posts.status` に可逆トグルを追加 | 直交する状態は別カラム・別レコード |
| `if type == :direct` の分岐が増える | STI / delegated_type |
| `post :publish, on: :member` | `resource :publication` |
| `POST /posts/:id/toggle_archive` | `POST/DELETE /posts/:id/archival` |
| `Post.find` してから権限チェック | `Current.user.accessible_posts.find` |
| Pundit / CanCanCan を最初から入れる | スコープ + `can_*?` 述語 + `ensure_*` |
| コントローラでトランザクション | モデルのメソッドの中で `transaction do` |
| `params.require(...).permit(...)` | `params.expect(...)`（Rails 8+） |
| ジョブクラスにロジックを書く | ジョブは1行、モデルのメソッドを呼ぶ |

## コードスタイルの注意

37signalsのハウススタイルのうち、**判断が変わるもの**だけ挙げる。
残りは fizzy の `STYLE.md` を直接読むほうが正確。

- **ガード節は推奨されていない**（世間に流布する理解と逆）。`STYLE.md` は
  「expanded conditionals over guard clauses」と明記し、`if ... else ... end` を好む。
  例外は「メソッド冒頭のearly return」と「本体が数行以上ある場合」の2つだけ
- **`!` は同名の非bangが存在するときだけ**付ける。破壊的だから付ける、ではない
- **`_now` は対で書く決まりではない**。同期版と非同期版が同名で衝突するときだけ使う。
  普通は `reindex` / `reindex_later` のように同期版は素の名前でよい
- **エンドレスメソッド定義に `if` / `unless` 修飾子を付けてはいけない**
  （判断フローBのコメント参照）。定義そのものが読み込み時の条件分岐になる
- 可視性修飾子の下をインデントする規約は、rubocopデフォルト
  （`Layout/IndentationConsistency`）と衝突する。持ち込むかはチームの判断

## 対話の進め方

行為の主体と対象をヒアリング → リソース/イベントの識別 → 判断フローA/B/Cの適用 →
実装イメージ（モデル定義・関連付け・ルーティング）の提示 → 直交性や拡張性の懸念を指摘。

判断フローは上から順に当てはめるためのもので、条件を満たさないのに下位の選択肢を
飛ばして採用しない。特に**「なんでもレコード化」は過剰設計**。
既存コードの慣習・チームの合意・Railsのバージョンを優先する。

## references

- **`references/logic-placement.md`** — 判断フローAの詳細。concernの2種類と切り方、テンプレートメソッド方式、POROの4分類と置き場
- **`references/state-modeling.md`** — 判断フローBの詳細。STI / delegated_type / ジョイン / enum / timestamp / boolean の使い分け
- **`references/controllers.md`** — 判断フローCの詳細。動詞→リソース名詞の変換表、`*Scoped` concern、認可、bang、strong parameters

内容は basecamp の fizzy・once-campfire・writebook の実装を読んで裏どりしている（SHAはREADME）。
