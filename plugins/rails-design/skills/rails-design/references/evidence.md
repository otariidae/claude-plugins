# 裏どり結果（37signals リファレンス実装）

このスキルの 37signals 由来の主張が、実際の公開コードで裏付けられるかを確認した記録。

## 検証対象と時点

| リポジトリ | SHA | 日付 | ライセンス |
|---|---|---|---|
| basecamp/fizzy | `ebfb0671c3e85aa73b0b3f08a216febfcdca657c` | 2026-09-07 | O'Saasy License（独自・OSS ではない） |
| basecamp/once-campfire | `ef147d17dbb2a21059a7e6a16fb6bc8afb61a785` | 2026-09-01 | MIT |
| basecamp/writebook | `3f98703069512a8b01f99ed039266bac4a62ad26` | 2026-09-01 | ソース公開だが OSS ではない |

ライセンス上、`references/*.md` のコード例はすべて自作の架空ドメイン（`Post` / `Invoice` 等）で書き、
実装の所在はこのファイルの `repo path:line` 参照で示す。逐語コピーはしない。

判定の凡例: **確認** = 主張どおり / **部分的に修正** = 条件付きで成立 / **反証** = 主張が誤り。

---

## concern は「モデル固有」が圧倒的多数で、横断 concern は少数

- 判定: 確認
- 根拠:
  - fizzy: `app/models/concerns/` は 8 ファイル（`attachments.rb`, `eventable.rb`, `filterable.rb`, `mentions.rb`, `notifiable.rb`, `searchable.rb`, `storage/totaled.rb`, `storage/tracked.rb`）。
    対してモデル名前空間下の `extend ActiveSupport::Concern` は 69 ファイル
  - once-campfire: `app/models/concerns/` ディレクトリが**存在しない**。concern は 12 件すべてモデル名前空間下（`app/models/user/role.rb`, `app/models/message/broadcasts.rb` 等）
  - writebook: `app/models/concerns/` は 2 件（`authorization.rb`, `positionable.rb`）、モデル名前空間下は 8 件
- メモ: 「まず `app/models/<model>/*.rb` に置き、2 モデル目が要求してはじめて `concerns/` に上げる」という順序が
  3 リポジトリすべてで数の上でも裏付けられた。

## モデル固有 concern の置き場は `app/models/<model>/<concern>.rb`

- 判定: 確認
- 根拠: fizzy `app/models/card.rb:2-4` が `Accessible, Assignable, ..., Watchable` を include し、
  実体は `app/models/card/accessible.rb`, `app/models/card/closeable.rb` … と Card 名前空間下に置かれる。
  `Card` クラスは 95 行（`app/models/card.rb`）に収まり、23 concern に分割されている
- メモ: 名前空間が一致するため `include Closeable` のように短く書ける（`Card::Closeable` の解決）。

## 横断 concern はテンプレートメソッドで、モデル固有 concern がそれを埋める

- 判定: 確認（下書きの言う「hook 方式」はこの形）
- 根拠:
  - fizzy `app/models/concerns/searchable.rb:56-62` — 「Models must implement these methods」として
    `search_title` / `search_content` / `searchable?` 等を列挙するコメントを持つ
  - fizzy `app/models/card/searchable.rb:4-31` — `include ::Searchable` した上で `search_title` 等を実装
  - fizzy `app/models/concerns/mentions.rb:49-56` — `# Template method` コメント付きで `mentionable?` / `should_check_mentions?` にデフォルト実装
  - fizzy `app/models/card/mentions.rb:6-13` — `include ::Mentions` して両方を上書き
  - fizzy `app/models/concerns/eventable.rb:17-24` — `should_track_event?` のデフォルトは `true`。
    `app/models/card/eventable.rb:25-27` が `published?` に、`app/models/comment/eventable.rb:15-17` が `!creator.system?` に上書き
- メモ: 「横断 concern を直接 include する」のではなく、**同名のモデル固有 concern を挟んで include する**のが定型。
  `Card::Searchable` → `::Searchable`、`Card::Mentions` → `::Mentions`、`Card::Eventable` → `::Eventable`。

## 横断 concern をパラメータ化するときは `class_methods do` の DSL

- 判定: 確認
- 根拠: writebook `app/models/concerns/positionable.rb:17-33` — `positioned_within(parent, association:, filter:)` を
  `class_methods` で定義し、`define_method` で親の辿り方を注入する。
  利用側は writebook `app/models/leaf.rb:6`（`positioned_within :book, association: :leaves, filter: :active`）
- メモ: fizzy `app/controllers/concerns/authorization.rb:8-17` も同型（`allow_unauthorized_access` 等の宣言 DSL）。

## 可逆な状態は「boolean カラム」ではなく `has_one` レコード + `resource`

- 判定: 確認
- 根拠:
  - fizzy `app/models/card/closeable.rb:5-8` — `has_one :closure`、`scope :closed, -> { joins(:closure) }`、
    `scope :open, -> { where.missing(:closure) }`。`closed?` は `closure.present?`（同 15-17）
  - `Closure` は `app/models/closure.rb:1-5` の 5 行。`user`（誰が閉じたか）を持ち、`created_at` が「いつ閉じたか」になる
  - 公開は `config/routes.rb` の `resource :closure`、`app/controllers/cards/closures_controller.rb:4-23` の `create` / `destroy`
  - 同型: `Card::Golden` + `Card::Goldness`、`Card::Postponable` + `Card::NotNow`、`Board::Publishable` + `Board::Publication`、
    `Card::Stallable` + `Card::ActivitySpike`
- メモ: レコードにする実利がはっきりしている。`closures.user_id` で「誰が」、`created_at` で「いつ」が無料で付き、
  `closed_by` / `closed_at` / `closed_at_window` / `closed_by(users)` といったスコープが素直に書ける
  （`app/models/card/closeable.rb:10-12, 23-29`）。boolean だと同じことに 2〜3 カラム増える。

## ただし「属性が要らない可逆状態」は boolean のままでよい

- 判定: 部分的に修正（「常にレコード化」は言い過ぎ）
- 根拠:
  - writebook `db/schema.rb:79` — `books.published` は `boolean, default: false, null: false`。
    モデル側も `app/models/book.rb:8` の `scope :published, -> { where(published: true) }` だけ
  - 一方 fizzy の `Board` は `Board::Publication` レコード。理由は `app/models/board/publication.rb:5` の
    `has_secure_token :key` — 公開 URL 用のトークンという**publication 自身の属性**が要るから
- メモ: 判断の分かれ目は「その状態に付随する属性（誰が・いつ・トークン・理由）が要るか」。
  要らないなら boolean、要るならレコード。writebook でも公開の操作自体は
  `Books::PublicationsController`（`app/controllers/books/publications_controller.rb`）という
  **リソース名のコントローラ**で、boolean を `update` している。つまり「boolean か record か」と
  「リソースとして公開するか」は独立した判断。

## 「いつ起きたか」だけの一過性の状態は nullable timestamp

- 判定: 確認
- 根拠:
  - fizzy `db/schema.rb:418` `notifications.read_at`。`app/models/notification.rb:10-11` の
    `scope :unread, -> { where(read_at: nil) }` / `scope :read`、同 42-52 の `read` / `unread` / `read?`
  - once-campfire `db/schema.rb:83,88` `memberships.connected_at` / `unread_at`
- メモ: 通知の既読も「Reading」レコードにはしていない。誰が読んだかは `notifications.user_id` で既に確定していて
  追加属性が無いため。公開はやはりリソース（`app/controllers/notifications/readings_controller.rb` の `create` / `destroy`）。

## 多値のライフサイクルは enum、可逆トグルには使わない

- 判定: 確認
- 根拠: 3 リポジトリの `enum` 宣言は全 19 件。すべて 2 値以上のライフサイクル or 設定値で、トグル用途は無い
  - ライフサイクル: fizzy `app/models/export.rb:7`（pending/processing/completed/failed）、
    `app/models/account/import.rb:15`、`app/models/webhook/delivery.rb:18`、
    `app/models/notification/bundle.rb:5`、writebook `app/models/leaf.rb:10`（active/trashed）
  - 権限・役割: fizzy `app/models/user/role.rb:5`、`app/models/identity/access_token.rb:5`、
    once-campfire `app/models/user/role.rb:5`、writebook `app/models/access.rb:2`
  - ユーザー設定（多段階）: fizzy `app/models/user/settings.rb:5`（never/every_few_hours/daily/weekly）、
    once-campfire `app/models/membership.rb:9`（invisible/nothing/mentions/everything）、
    fizzy `app/models/access.rb:6`（access_only/watching）
  - 例外的に 2 値の enum: fizzy `app/models/card/statuses.rb:5`（drafted/published）、
    writebook `app/models/edit.rb:5`（revision/trash）
- メモ: `drafted/published` が boolean でなく enum なのは、下書きが「published の否定」ではなく
  それ自体が一段階だから（`app/models/cards/drafts_controller.rb` という専用の画面を持つ）。
  値が増える見込みがあるなら 2 値でも enum、というのが実装の姿勢。

## 振る舞いが型ごとに違うときは STI / delegated_type

- 判定: 確認
- 根拠:
  - STI: once-campfire `db/schema.rb:123` の `rooms.type`（`null: false`）。
    `app/models/rooms/open.rb` / `closed.rb` / `direct.rb` がサブクラス。
    差分は本当に振る舞い — `Rooms::Direct.find_or_create_for(users)`、`Rooms::Open` の `grant_access_to_all_users` コールバック、
    `default_involvement` の上書き（`rooms/direct.rb`）
  - `Room` 側は型を state として扱わない: `app/models/room.rb:53-63` は `is_a?(Rooms::Open)` で判定し、
    `app/models/room.rb:73-77` で「Direct からの型変更」だけを禁止するバリデーション
  - delegated_type: writebook `app/models/leaf.rb:5` — `delegated_type :leafable, types: Leafable::TYPES`。
    `Page` / `Section` / `Picture` は**カラム構成そのものが違う**（`app/models/page.rb`, `section.rb`, `picture.rb`）
- メモ: STI は「同じテーブルで振る舞いだけ違う」、delegated_type は「属性も違う」。
  fizzy `db/schema.rb:320` の `exports.type` も STI（`Account::Export` / `User::DataExport`）。

## Service クラス・`app/services` は存在しない

- 判定: 確認
- 根拠:
  - 3 リポジトリいずれも `app/services` ディレクトリが無い
  - `Service` を含むクラス名は 0 件（`ZipFile` 内のコメント語と JS ファイル名のみヒット）
  - fizzy `STYLE.md`「Controller and model interactions」節が
    「we favor a vanilla Rails approach with thin controllers directly invoking a rich domain model.
    We don't use services or other artifacts to connect the two.」と明記
- メモ: ただし同節は「When justified, it is fine to use services or form objects, but don't treat those as special artifacts」
  とも書き、`Signup.new(email_address: ...).create_identity` を例に挙げる。禁止ではなく「特別扱いしない」。

## PORO は `app/models` に置き、名詞（多くは行為者名詞）で名付ける

- 判定: 確認
- 根拠: fizzy `app/models` 配下の非 ActiveRecord クラスは 40 件超。すべて `app/models` 直下か
  オーナーモデルの名前空間下。`app/models/poros` のような専用ディレクトリは無い
  - 行為の主体: `Signup`（`app/models/signup.rb`）、`Notifier`（`notifier.rb`）、
    `Signup::AccountNameGenerator`、`Card::ActivitySpike::Detector`、`Card::Eventable::SystemCommenter`、
    `Account::Seeder`、`Search::Highlighter`、once-campfire `Room::MessagePusher`、writebook `HtmlScrubber`
  - 値・表現: `Color = Struct.new(:name, :value)`（`app/models/color.rb`）、
    `Passkey::Authenticator < Data.define(...)`、`Notification::DefaultPayload`、`Event::Description`
  - 外部境界: once-campfire `Opengraph::Fetch`（`app/models/opengraph/fetch.rb`）、
    `Opengraph::Location`、`Opengraph::Document`、fizzy `Notification::PushTarget::Web`、`ZipFile::RemoteIO`
  - ビュー向け組み立て: `User::Filtering`、`User::DayTimeline`、`Filter::Summarized`
- メモ: `-er` / `-or` の行為者名詞は普通に使う（`Notifier`, `Detector`, `Seeder`, `Pusher`）。
  避けられているのは `Service` / `Manager` / `Handler` / `Processor` のような**中身を説明しない**接尾辞。

## 複数モデルにまたがり、主語になるモデルが無い処理は ActiveModel の PORO

- 判定: 確認
- 根拠:
  - fizzy `app/models/signup.rb:1-5` — `ActiveModel::Model` / `Attributes` / `Validations` を include。
    `complete`（同 24-44）が Account 作成・オーナー User 作成・テンプレート投入を 1 トランザクション的に束ね、失敗時は自前でロールバック
  - コンテキスト付きバリデーション: 同 9-11 の `on: :identity_creation` / `on: :completion`
  - コントローラは PORO を直接呼ぶ: `app/controllers/signups_controller.rb:17-22`（`Signup.new(...).create_identity`）、
    `app/controllers/signups/completions_controller.rb:13-19`（`@signup.complete`）
  - writebook も同型: `app/models/first_run.rb:4-10`（`FirstRun.create!`）を
    `app/controllers/first_runs_controller.rb:11` が直接呼ぶ
- メモ: 「Service を介さずコントローラから直接」が実際の姿。`Signup` は AR ではないが `app/models` に居る。

## 外部サービス境界は PORO に閉じ、モデル側は入口だけ

- 判定: 確認
- 根拠:
  - once-campfire `app/models/opengraph/fetch.rb` — HTTP・リダイレクト・サイズ制限・SSRF ガードを全部持つ。
    ドメイン側は `Opengraph::Metadata`（`app/models/opengraph/metadata.rb`、`ActiveModel::Model`）が
    `Fetching` concern 経由で `from_url` を呼ぶだけ
  - fizzy `app/models/notification/pushable.rb` → `Notification::PushTarget`（`app/models/notification/push_target.rb:6-16`、
    `process` は `NotImplementedError`）→ `Notification::PushTarget::Web`。プロバイダごとにサブクラス
- メモ: `Webhook::Delivery`（fizzy `app/models/webhook/delivery.rb`）は AR モデルで HTTP も打つ例外。
  「配送の試行そのものを記録に残す」要件があるので、境界が AR レコードになっている（state enum・レスポンス保存・リトライ）。

## エンドポイントは名詞リソースの CRUD にする（カスタムアクションを足さない）

- 判定: 確認
- 根拠:
  - fizzy `STYLE.md`「CRUD controllers」節が `post :close` / `post :reopen` を Bad、
    `resource :closure` を Good として明示
  - fizzy `config/routes.rb` の `resources :cards` ブロックは
    `resource :closure` / `:goldness` / `:not_now` / `:pin` / `:publish` / `:triage` / `:watch` / `:reading` / `:board` / `:column` 等の
    ネストしたリソースだけで構成され、`member do post :xxx end` は 1 件も無い
  - 動詞に見える操作もリソース化: 並び替えは `resource :left_position` / `:right_position`
    （`config/routes.rb`、`app/controllers/columns/left_positions_controller.rb`）、
    ドラッグ＆ドロップは `namespace :drops` 下の `resource :closure` / `:column` / `:not_now` / `:stream`
  - once-campfire `config/routes.rb` も同様（`resource :involvement`, `resource :refresh`, `resources :boosts`）
- メモ: fizzy 全 119 コントローラのうち 100 件以上が `Xxx::YyysController` 形式のネスト。
  例外は `get "tray", to: "trays#show"`（`config/routes.rb` の notifications 内）程度。

## コントローラは薄く、`before_action` で親の解決と認可を済ませる

- 判定: 確認
- 根拠:
  - `*Scoped` concern: fizzy `app/controllers/concerns/card_scoped.rb:4-15` が
    `before_action :set_card, :set_board` を注入し、`set_card` は `Current.user.accessible_cards.find_by!(...)`。
    **認可されたスコープから引く**ので、引けた時点でアクセス権がある
  - 同型: `board_scoped.rb`, `column_scoped.rb`, `filter_scoped.rb`, `day_timelines_scoped.rb`、
    writebook `book_scoped.rb` / `page_leaf_scoped.rb` / `user_scoped.rb`
  - `ensure_*` による認可: `app/controllers/concerns/authorization.rb:20-39`（`ensure_admin`, `ensure_staff`,
    `ensure_can_access_account`）、`app/controllers/cards_controller.rb:9,66-68`
    （`before_action :ensure_permission_to_administer_card, only: %i[ destroy ]`）、
    `app/controllers/concerns/board_scoped.rb:13-17`（`ensure_permission_to_admin_board`）
  - 失敗は `head :forbidden`。例外を投げて rescue_from で拾う形は取っていない
- メモ: 認可 gem（Pundit / CanCanCan）は 3 リポジトリとも不使用。
  権限判定の本体はモデル側（`Current.user.can_administer_card?`）にあり、コントローラはそれを呼ぶだけ。

## アクションの本体は 1〜3 行。ロジックはモデルのメソッド

- 判定: 確認
- 根拠:
  - fizzy `app/controllers/cards/goldnesses_controller.rb:4-20` — `create` は `@card.gild`、`destroy` は `@card.ungild`
  - `app/controllers/cards/closures_controller.rb:4-23` — `@card.close` / `@card.reopen`。
    トランザクション・イベント記録・`not_now` の破棄はすべて `app/models/card/closeable.rb:31-48` 側
  - `app/controllers/cards/watches_controller.rb:8-24` — `@card.watch_by Current.user`
  - `app/controllers/notifications/readings_controller.rb:3-20` — `@notification.read` / `.unread`
- メモ: 素の AR 操作をそのまま書くのも許容（`STYLE.md` の `@card.comments.create!(comment_params)`、
  実例は `app/controllers/cards_controller.rb:23,36,45`）。「モデルに移すべき」なのは**複数手続きが束になったとき**。

## 書き込みは bang メソッド

- 判定: 確認
- 根拠: fizzy の全コントローラで `create!` / `update!` / `destroy!` は 33 箇所。
  `app/controllers/cards_controller.rb:23,36,45`、`app/models/card/closeable.rb:35`（`create_closure!`）、
  `app/models/board/publishable.rb:21`（`create_publication!`）
- メモ: 保存失敗が想定内のとき（フォーム再表示）は `valid?` / `save` を明示的に分岐させる
  （`app/controllers/signups/completions_controller.rb:15-19`）。「常に bang」ではなく
  「バリデーション失敗を UI で扱わない経路は bang」。

## `params.expect` を使う（Rails 8）

- 判定: 確認
- 根拠: fizzy の strong parameters 28 箇所中 24 箇所が `params.expect`
  （`app/controllers/cards_controller.rb:71`, `app/controllers/signups_controller.rb:35`）。
  writebook はまだ `params.require(...).permit(...)`（`app/controllers/books/publications_controller.rb:19`）
- メモ: `wrap_parameters :card, include: %i[ ... ]` をクラス冒頭に置いて JSON API の入力も揃えている
  （`app/controllers/cards_controller.rb:2`）。

## `Current` は認証コンテキストの置き場で、モデルの default に使う

- 判定: 確認
- 根拠:
  - fizzy `app/models/current.rb:1-27` — `ActiveSupport::CurrentAttributes`。
    `session=` が `identity` を、`identity=` が `user` を連鎖的に解決（同 5-19）
  - モデルの `belongs_to ... default:` から参照: `app/models/card.rb:8`、`app/models/comment.rb:6`、
    `app/models/board.rb:4`、`app/models/reaction.rb:4`、`app/models/tag.rb:4`、`app/models/filter.rb:4-5`
  - ドメインメソッドのデフォルト引数にも: `app/models/card/closeable.rb:31`（`def close(user: Current.user)`）、
    `app/models/concerns/eventable.rb:8`
- メモ: `Current` に入れているのは session / user / identity / account とリクエストメタ情報だけ。
  ドメインの状態は入れていない。

## 非同期は `_later` サフィックスの薄いジョブ

- 判定: 部分的に修正
- 根拠:
  - `_later` は確認: fizzy モデル内に 13 件（`app/models/card/stallable.rb:40`,
    `app/models/concerns/mentions.rb:45`, `app/models/webhook/delivery.rb:29`,
    `app/models/notification/pushable.rb:26` 等）。
    ジョブ本体は 1 行でモデルに委譲（`app/models/card/stallable.rb:41` → `Card::ActivitySpike::DetectionJob`）
  - **`_now` は 3 リポジトリのアプリコードに 1 件も無い**。`STYLE.md`「Run async operations in jobs」節の
    説明例（`relay_later` / `relay_now`）にのみ登場する
- メモ: `_now` は「同名の同期版が必要になったときの命名規約」であって、常に対で書く決まりではない。
  実際は `detect_activity_spikes` / `detect_activity_spikes_later` のように、同期版は素の名前のまま。

## ガード節よりも展開した条件分岐を好む

- 判定: 反証（一般に流布する「37signals = ガード節」という理解と逆）
- 根拠: fizzy `STYLE.md`「Conditional returns」節が
  「In general, we prefer to use expanded conditionals over guard clauses.」と明記し、
  `return [] unless ids` を Bad、`if ids = ... else [] end` を Good としている。
  例外として認めるのは (1) メソッド冒頭の early return、(2) 本体が数行以上ある場合の 2 つだけ
- メモ: 実装側も一致。`app/models/card/closeable.rb:32,42` は `unless closed?` / `if closed?` で本体を包む形で、
  ガード節での early return を使っていない。`app/models/concerns/searchable.rb:17-29` も同様。

## 可視性修飾子の下はインデントする

- 判定: 確認
- 根拠: fizzy `STYLE.md`「Visibility modifiers」節。`private` の下に空行を入れず、中身を 1 段インデント。
  実装も全面的に従っている（`app/models/card.rb:70-94`, `app/controllers/cards_controller.rb:53-72`）。
  例外として「private メソッドしか持たない module は先頭で `private` を宣言し、空行を入れてインデントしない」
- メモ: 標準的な Ruby スタイルガイド（rubocop の `Layout/IndentationConsistency` デフォルト）とは異なる。
  自分のリポジトリに持ち込むかは別判断。

## メソッドは呼び出し順に縦に並べる

- 判定: 確認
- 根拠: fizzy `STYLE.md`「Methods ordering」「Invocation order」節。
  実装例は `app/models/card.rb:70-94`（`handle_board_change` → `track_board_change_event` の順）、
  `app/models/notifier.rb:15-52`
- メモ: クラスメソッド → public（`initialize` が先頭） → private の順。
