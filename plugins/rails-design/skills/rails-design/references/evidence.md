# 裏どり結果（37signals リファレンス実装）

このスキルの 37signals 由来の主張を、公開実装で確認した記録。

| リポジトリ | 検証時 SHA | ライセンス |
|---|---|---|
| basecamp/fizzy | `ebfb0671c3e85aa73b0b3f08a216febfcdca657c` | O'Saasy License（独自・OSS ではない） |
| basecamp/once-campfire | `ef147d17dbb2a21059a7e6a16fb6bc8afb61a785` | MIT |
| basecamp/writebook | `3f98703069512a8b01f99ed039266bac4a62ad26` | ソース公開だが OSS ではない |

ライセンス上、`references/*.md` のコード例はすべて架空ドメインで書いた自作の最小例。
逐語コピーは含まず、実装の所在はこの表の `path:line` 参照で示す。
パスは断りがなければ fizzy。

## 判定一覧

| # | 主張 | 判定 | 根拠 |
|---|---|---|---|
| 1 | concern はモデル固有が圧倒的多数、横断は少数 | 確認 | `app/models/concerns/` は 8 件、モデル名前空間下の concern は 69 件。campfire は `concerns/` 自体が無く 12 件すべて名前空間下。writebook は 2 対 8 |
| 2 | モデル固有 concern は `app/models/<model>/<concern>.rb` | 確認 | `app/models/card.rb:2-4` が 23 concern を include し、本体は 95 行。実体は `app/models/card/*.rb` |
| 3 | 横断 concern はテンプレートメソッドで、モデル固有側が埋める | 確認 | `app/models/concerns/searchable.rb:56-62`（実装すべきメソッドの列挙コメント）↔ `app/models/card/searchable.rb:4-31`。`concerns/mentions.rb:49-56`（`# Template method`）↔ `card/mentions.rb:6-13`。`concerns/eventable.rb:17-24` ↔ `card/eventable.rb:25-27` / `comment/eventable.rb:15-17` |
| 4 | 横断 concern は同名のモデル固有 concern を挟んで include する | 確認 | `card/searchable.rb:5`, `card/mentions.rb:6`, `card/eventable.rb:4` がいずれも `include ::Xxx` |
| 5 | 横断 concern のパラメータ化は `class_methods do` の DSL | 確認 | writebook `app/models/concerns/positionable.rb:17-33`（`positioned_within`）、利用側 `app/models/leaf.rb:6`。同型は `app/controllers/concerns/authorization.rb:8-17` |
| 6 | 可逆な状態は boolean でなく `has_one` レコード + `resource` | 確認 | `app/models/card/closeable.rb:5-12`（`has_one :closure` / `joins` / `where.missing`）、`app/models/closure.rb`（全 5 行）、`config/routes.rb` の `resource :closure`、`app/controllers/cards/closures_controller.rb:4-23`。同型 4 例: `card/golden.rb`+`card/goldness.rb`、`card/postponable.rb`+`card/not_now.rb`、`board/publishable.rb`+`board/publication.rb`、`card/stallable.rb`+`card/activity_spike.rb` |
| 7 | レコード化の実利は「誰が・いつ」と派生スコープ | 確認 | `card/closeable.rb:10-12`（`recently_closed_first` / `closed_at_window` / `closed_by`）、`:23-29`（`closed_by` / `closed_at`）。boolean だと同じことに 2〜3 カラム要る |
| 8 | **「常にレコード化」は言い過ぎ** | **部分的に修正** | writebook `db/schema.rb:79` の `books.published` は boolean のまま（モデル側も `app/models/book.rb:8` の scope だけ）。fizzy が `Board::Publication` をレコードにするのは `app/models/board/publication.rb:5` の `has_secure_token :key` という publication 固有の属性が要るから。**分かれ目は「その状態に付随する属性が要るか」** |
| 9 | boolean でもエンドポイントはリソースにする | 確認 | writebook `app/controllers/books/publications_controller.rb` が boolean を `update` する。「boolean か record か」と「リソース化するか」は独立した判断 |
| 10 | 「いつ」だけの状態は nullable timestamp | 確認 | `db/schema.rb:418` の `notifications.read_at`、`app/models/notification.rb:10-11,42-52`。campfire `db/schema.rb:83,88`（`connected_at` / `unread_at`）。公開は `app/controllers/notifications/readings_controller.rb` の create/destroy |
| 11 | 多値のライフサイクルは enum、可逆トグルには使わない | 確認 | 3 リポジトリの `enum` 宣言は全 19 件、トグル用途は 0 件。ライフサイクル系 `app/models/export.rb:7`, `account/import.rb:15`, `webhook/delivery.rb:18`, writebook `leaf.rb:10`。役割系 `user/role.rb:5`, `identity/access_token.rb:5`。多段設定 `user/settings.rb:5`, campfire `membership.rb:9`, `access.rb:6` |
| 12 | 2 値でも enum にする場合がある | 確認 | `app/models/card/statuses.rb:5`（drafted/published）。下書きは「published の否定」ではなく一段階で、`app/controllers/cards/drafts_controller.rb` という専用画面を持つ |
| 13 | 振る舞いが型ごとに違うなら STI | 確認 | campfire `db/schema.rb:123` の `rooms.type`（`null: false`）、`app/models/rooms/{open,closed,direct}.rb`。差分は本当に振る舞い（`Rooms::Direct.find_or_create_for`、`Rooms::Open` の付与コールバック、`default_involvement` の上書き）。`app/models/room.rb:53-63` は `is_a?` で判定し、`:73-77` で Direct からの型変更のみ禁止 |
| 14 | 属性構成も違うなら delegated_type | 確認 | writebook `app/models/leaf.rb:5`（`delegated_type :leafable`）、`app/models/leafable.rb`、`page.rb` / `section.rb` / `picture.rb` はカラム構成が異なる。fizzy `db/schema.rb:320` の `exports.type` は STI |
| 15 | Service クラス・`app/services` は存在しない | 確認 | 3 リポジトリいずれも `app/services` 無し、`*Service` クラス 0 件。fizzy `STYLE.md`「Controller and model interactions」が「We don't use services or other artifacts to connect the two.」と明記。ただし同節は「When justified, it is fine to use services or form objects, but don't treat those as special artifacts」とも書く（禁止ではなく特別扱いしない） |
| 16 | PORO は `app/models` に置き、名詞で名付ける | 確認 | 非 AR クラスは fizzy `app/models` 配下に 40 件超、専用ディレクトリ無し。行為者: `signup.rb`, `notifier.rb`, `signup/account_name_generator.rb`, `card/activity_spike/detector.rb`, `card/eventable/system_commenter.rb`, `account/seeder.rb`, campfire `room/message_pusher.rb`。値: `color.rb`（`Struct`）, `passkey/authenticator.rb`（`Data.define`）, `notification/default_payload.rb`。`-er` / `-or` は普通に使い、避けるのは `Service` / `Manager` / `Handler` のような中身を説明しない接尾辞 |
| 17 | 主語の無い手続きは ActiveModel の PORO、コントローラから直接呼ぶ | 確認 | `app/models/signup.rb:1-5`（`ActiveModel::Model`）、`:24-44`（`complete` が Account/User 作成を束ね失敗時に自前ロールバック）、`:9-11`（`on: :identity_creation` / `on: :completion`）。呼び出しは `app/controllers/signups_controller.rb:17-22` と `signups/completions_controller.rb:13-19`。writebook も `app/models/first_run.rb:4-10` ↔ `app/controllers/first_runs_controller.rb:11` |
| 18 | 外部境界は PORO に閉じ、モデルは入口だけ | 確認 | campfire `app/models/opengraph/fetch.rb`（HTTP・リダイレクト・サイズ制限・SSRF ガード）↔ `app/models/opengraph/metadata.rb`（ドメイン側は `from_url` を呼ぶだけ）。fizzy `notification/push_target.rb:6-16`（`process` は `NotImplementedError`）→ `push_target/web.rb`。**例外**: `app/models/webhook/delivery.rb` は配送の試行自体を記録する要件があるため AR モデルで HTTP も打つ |
| 19 | エンドポイントは名詞リソースの CRUD、カスタムアクションを足さない | 確認 | fizzy `STYLE.md`「CRUD controllers」が `post :close` を Bad、`resource :closure` を Good と明示。`config/routes.rb` の `resources :cards` ブロックは `resource :closure` / `:goldness` / `:not_now` / `:pin` / `:publish` / `:triage` / `:watch` 等のみで `member do post` は 0 件。並び替えも `resource :left_position`、D&D も `namespace :drops` 下のリソース。全 119 コントローラのうち 100 件以上が `Xxx::YyysController` 形式 |
| 20 | 親の解決と認可は `*Scoped` concern、認可済みスコープから find する | 確認 | `app/controllers/concerns/card_scoped.rb:4-15`（`set_card` は `Current.user.accessible_cards.find_by!`）。同型 `board_scoped.rb`, `column_scoped.rb`, `filter_scoped.rb`, writebook `book_scoped.rb` 等 |
| 21 | 追加の認可は `ensure_*` の before_action、失敗は `head :forbidden` | 確認 | `app/controllers/concerns/authorization.rb:20-39`、`app/controllers/cards_controller.rb:9,66-68`、`concerns/board_scoped.rb:13-17`。判定本体はモデル側（`Current.user.can_administer_card?`）。認可 gem は 3 リポジトリとも不使用 |
| 22 | アクションは 1〜3 行 | 確認 | `app/controllers/cards/goldnesses_controller.rb:4-20`（`@card.gild` / `@card.ungild`）、`cards/closures_controller.rb:4-23`（`@card.close`。トランザクション・イベント記録は `app/models/card/closeable.rb:31-48`）、`cards/watches_controller.rb:8-24`。素の AR 操作をそのまま書くのも許容（`cards_controller.rb:23,36,45`） |
| 23 | 書き込みは bang | 確認 | fizzy コントローラ全体で `create!` / `update!` / `destroy!` が 33 箇所。ただし保存失敗を UI で扱う経路は `valid?` / `save` を明示分岐（`signups/completions_controller.rb:15-19`）。「常に bang」ではなく「失敗を見せない経路は bang」 |
| 24 | `params.expect` を使う（Rails 8） | 確認 | fizzy の strong parameters 28 箇所中 24 箇所が `params.expect`（`cards_controller.rb:71`, `signups_controller.rb:35`）。writebook はまだ `require/permit`。`wrap_parameters` をクラス冒頭に置いて JSON 入力も揃える（`cards_controller.rb:2`） |
| 25 | `Current` は認証コンテキスト置き場で、モデルの default に使う | 確認 | `app/models/current.rb:1-27`（`session=` → `identity` → `user` の連鎖解決）。参照は `card.rb:8`, `comment.rb:6`, `board.rb:4`, `reaction.rb:4`, `tag.rb:4`, `filter.rb:4-5` の `default:`、および `card/closeable.rb:31` の `def close(user: Current.user)`。入れているのは session/user/identity/account とリクエストメタ情報だけ |
| 26 | 非同期は `_later` の薄いジョブ | 確認 | fizzy モデル内に 13 件（`card/stallable.rb:40`, `concerns/mentions.rb:45`, `webhook/delivery.rb:29`, `notification/pushable.rb:26`）。ジョブ本体は 1 行でモデルに委譲 |
| 27 | **`_now` は対で書く決まりではない** | **部分的に修正** | 3 リポジトリのアプリコードに `_now` は **1 件も無い**。`STYLE.md`「Run async operations in jobs」の説明例にのみ登場。実際は `detect_activity_spikes` / `detect_activity_spikes_later` のように同期版は素の名前（`card/stallable.rb:27,40`） |
| 28 | **ガード節は推奨されていない** | **反証**（世間に流布する理解と逆） | fizzy `STYLE.md`「Conditional returns」が「In general, we prefer to use expanded conditionals over guard clauses.」と明記し、`return [] unless ids` を Bad とする。例外は (1) メソッド冒頭の early return (2) 本体が数行以上の場合、の 2 つだけ。実装も一致（`card/closeable.rb:32,42` は `unless closed?` / `if closed?` で本体を包む） |
| 29 | 可視性修飾子の下はインデントする | 確認 | `STYLE.md`「Visibility modifiers」。`private` の下に空行を入れず 1 段インデント（`card.rb:70-94`, `cards_controller.rb:53-72`）。private のみの module は先頭で宣言し空行を入れてインデントしない。**rubocop デフォルト（`Layout/IndentationConsistency`）と衝突する**ので、採用するなら `EnforcedStyle: indented_internal_methods` が要る |
| 30 | `!` は同名の非 bang が存在するときだけ付ける | 確認 | `STYLE.md`「To bang or not to bang」。破壊的だから付ける、ではない（Ruby / Rails 自体に `!` の付かない破壊的メソッドは多い） |
| 31 | メソッドは呼び出し順に縦に並べる | 確認 | `STYLE.md`「Methods ordering」「Invocation order」。クラスメソッド → public（`initialize` 先頭） → private の順。実装例 `card.rb:70-94`, `notifier.rb:15-52` |
