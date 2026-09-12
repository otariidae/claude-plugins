---
name: rails-design
description: Railsのモデル設計・コード設計の壁打ちとレビューに使う。モデリング／テーブル設計、concern・PORO・serviceの置き場、状態表現（enum・boolean・timestamp・has_one・STI）、RESTリソースとコントローラ、Current、エラー設計（rescue / retry_on / discard_on）、Railsコードレビューの際に使用する。
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
`Service` / `Manager` / `Handler` / `Processor` / `UseCase` は使わない。
`-er` / `-or` の行為者名詞（`Notifier`, `Post::SlugGenerator`）は普通に使う。

**concernは行数ではなく関心で切る**（`Post::Publishable`。`Post::Associations` のような機構分割はしない）。
**横断concernは直接includeしない**（同名のモデル固有concernを挟んで `include ::Searchable`）。

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
   → enum
4. 可逆なオン/オフで、付随する属性（誰が・いつ・キー・理由）が要る？
   → has_one レコード + resource
5. 可逆なオン/オフで、「いつ」だけ要る？
   → nullable timestamp（xxx_at）
6. 可逆なオン/オフで、何も付随しない？
   → boolean（NOT NULL + default 必須）
```

**booleanかhas_oneかを分ける3つの問い**（1つでもYesならレコード）

1. 「誰がやったか」を記録したいか？
2. 「いつやったか」を記録したいか？
3. その状態に固有の属性（理由・トークン・期限）が今あるか、将来ありそうか？

**直交性**: 同時に立ちうる状態は別カラム・別レコードに、同時に立ちえない値は1つのenumに。

詳細・実装例は `references/state-modeling.md`。

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
# 良い
 resources :posts do
   scope module: :posts do
     resource :publication
   end
 end
# 悪い
resources :posts do
  member { post :publish }
end
```

`Posts::PublicationsController#create` が公開、`#destroy` が公開解除。
**トグルを1アクションにしない**（`POST /toggle` にしない）。

**`set_post` は認可済みスコープから find する**（`Current.user.accessible_posts.find(...)`）。
認可gemは、スコープと `can_*?` 述語で足りるうちは入れない。

詳細は `references/controllers.md`。

---

## 5. 判断フローD: 失敗をどう扱うか

```
1. 誰の失敗か？
   ├ プログラマ（前提違反・到達しないはずの分岐・抽象メソッド）
   │   → raise "説明" / ArgumentError / NotImplementedError
   │     rescue しない。500 でよい
   ├ ユーザー入力（フォーム・パラメータ）
   │   → 例外にしない。errors.add + valid? / save の戻り値で if 分岐
   │     → render :new, status: :unprocessable_entity（フォーム無しなら head）
   ├ 権限・存在
   │   → 認可済みスコープの find（404）/ ensure_* の head :forbidden（403）
   └ 外部世界（ネットワーク・外部サービス・DB の競合・ファイル）
        2. 境界の PORO かレコードの中で捕まえ、外の例外クラスを外に出さない
           ├ 結果を保存・表示する → データにする（{ error: :timed_out } / failure_reason enum）
           ├ その後の対処・記録・見えるものが他と分岐する（別扱い）
           │   → オーナークラスに class Xxx < StandardError; end を1行
           │     手段: rescue / retry_on / discard_on / 翻訳先の分岐
           └ ベストエフォート（主処理を止めない付加。無しで成立する）
               → nil を返し、なぜ握るかをコメントに。必要なら logger.warn / Rails.error.report
        3. 失敗状態を持つレコードは、状態を保存してから raise し直す（failed! → raise）
        4. ジョブは宣言で決める。perform は1行、rescue は書かない
           ├ retry_on   → 一時的な原因を名指し（自前の例外か、境界を自分で持たない ActionMailer 配送の Net::OpenTimeout 等）
           └ discard_on → 恒久的な失敗。見えていてほしければ report: true（Rails 8.1+）
```

**既定は「何もしない」。** `ApplicationController` に `rescue_from` は置かず、Rails 既定の `rescue_responses` に任せる。
**「成立しなかった」は例外ではなく falsy。** 起きてはいけない失敗だけ bang で 500。
アクション直下の `rescue` は、その行が実際に投げるクラスだけ。`rescue => e` をコントローラに書かない。

詳細は `references/error-handling.md`。

---

## 6. 個別の指針

### フォームオブジェクト
画面ごとに違うバリデーション、複数モデルにまたがる入力は
`ActiveModel::Model` + `ActiveModel::Attributes` のPOROにし、**コントローラから直接呼ぶ**。

**`on:` コンテキストの罠**: `valid?(:completion)` が走らせるのは「`on:` の無い検証」と
「`on: :completion` の検証」だけ。フェーズを分けるなら各入口でそれぞれの `valid?` を呼ぶ。
1つのメソッドで全部やるなら `on:` を付けない。

### アイデンティティ（存在）の最小化
中心テーブルは主キー中心に、属性は性質ごとに別テーブルへ。
分割基準: **変更頻度が違う / 秘匿性のレベルが違う / 必須・任意が違う**。

### アイデンティティプールの分離
目的や利用方法が根本的に異なる主体はテーブルを分ける
（一般ユーザーと管理スタッフ、法人顧客と個人顧客）。

### プロセスの分離
フロー完了まで発生しないエンティティは専用テーブルで管理し、完了時に本テーブルへ作る。

### 多対多は has_many :through
HABTMは避ける。関連自体に「いつ・どの役割で」を持てるようにする。

### Current の使い方
- 入れるのは**認証コンテキストとリクエストメタ情報だけ**。ドメインの状態は入れない
- モデル側はデフォルト値として参照し、引数で上書きできる形にする
  （`default: -> { Current.user }` / `def archive(user: Current.user)`）
- ジョブは `Current` を引き継がないので、必要なら明示的に渡す

---

## レビュー時に探す匂い

まず下を走査する。詳細は各 `references/*.md`。

- `*Service` / `*Processor` / `app/services/` → 主語モデルのメソッド、または `Signup` のような PORO（`app/models/`）
- `post.rb` に全部 / 最初から `app/models/concerns/` → 関心ごとのモデル固有concern → 2モデル目で昇格
- 横断concernを直接include → 同名のモデル固有concernを挟んで `include ::Xxx`
- `archived` boolean / status に可逆トグル → 誰が・いつ要るなら `has_one :archival`。直交する状態は別カラム・別レコード
- `deleted` → `has_one :trashing` か本当に消す
- `published` + `published_at` → どちらか一方（timestamp があれば boolean は導出）
- `read_*_ids`（配列/JSON） → ジョインモデル
- 同時に立てない値を別カラムに / 独立に立つ値を1つのenumに → enum 1本 / カラム・レコードを分ける
- `if type == :direct` の分岐が増える → STI / delegated_type
- boolean に `null: false` + `default:` が無い → 付ける
- `post :publish` / `toggle_*` → `resource :publication`（create/destroy）
- `Post.find` してから権限チェック / 最初から Pundit → 認可済みスコープの `find` + `can_*?` + `ensure_*`
- コントローラでトランザクション / ジョブにロジック → モデルのメソッドへ。ジョブは1行
- アクションが5行超 → モデルに移せる塊がある
- 戻り値を無視した `save` / `update` → bang、または失敗を扱う `if`
- `params.require(...).permit(...)` → `params.expect(...)`（Rails 8+）
- `app/errors/` + `ApplicationError` / 原因が違うだけの例外クラス → オーナー内1行。対処が同じなら `raise "説明"`
- `rescue_from StandardError` / 各層で `rescue => e; nil` → 書かない。境界1箇所で翻訳
- `Result.failure` / 入力失敗を `raise` / 「成立しなかった」を例外 → 失敗レコードか素の例外 / `errors.add` + falsy
- `perform` に `rescue; retry_job` / 握ってジョブ成功 → `retry_on` / `discard_on`。`failed!` してから `raise`
- `transaction` 内で `failed!` / 事前 `exists?` / `alert: e.message` → rescue は外。一意制約 + `RecordNotUnique`。固定文

## コードスタイルの注意

世間の常識と違うものだけ。残りは fizzy の `STYLE.md`。

- **ガード節は非推奨**（`if ... else ... end` を好む）。例外は冒頭 early return と本体が数行以上のときだけ
- **`!` は同名の非bangがあるときだけ**（破壊的だからではない）
- **`_now` は同名衝突時だけ**。普通は `reindex` / `reindex_later`
- **エンドレスメソッドに `if` / `unless` 修飾子を付けない**（`controllers.md`）
- 可視性修飾子下のインデントは rubocop デフォルトと衝突。持ち込むかはチーム判断

## 対話の進め方

行為の主体と対象をヒアリング → リソース/イベントの識別 → 判断フローA/B/C/D（上から順）→
実装イメージの提示。特に**「なんでもレコード化」は過剰設計**。
既存コードの慣習・チームの合意・Railsのバージョンを優先する。

## references

- `references/logic-placement.md` / `state-modeling.md` / `controllers.md` / `error-handling.md`
  （判断フローA–D。裏どり元のSHAはREADME）
