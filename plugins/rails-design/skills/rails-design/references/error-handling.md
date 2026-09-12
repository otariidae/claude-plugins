# エラー設計とエラーハンドリング

判断フローD の詳細。Rails 既定の例外→ステータス変換は前提として、
**どこで捕まえ、何に変換し、誰に見せるか**の判断だけを書いている。

3実装ともエラー処理は少ない。カスタム例外は fizzy が `app/` に6つ（別に `lib/` の WebAuthn 部品に階層が1つ）、
campfire 3、writebook 0。コントローラの `rescue_from` は3実装で1箇所。`ApplicationJob` の
`retry_on` / `discard_on` は Rails 生成時のコメントのまま。**既定は「何もしない」**で、以下は足す判断をした箇所。

## 1. 失敗は 4 種類あり、扱いが全部違う

| 誰の失敗か | 例 | 扱い | 見えるもの |
|---|---|---|---|
| **プログラマ**（前提違反・抽象メソッド） | 別の親の子を渡された / ブロック無し | `raise "説明"` / `ArgumentError` / `NotImplementedError`。rescue しない | 500 |
| **ユーザー入力** | 名前が空 / URL 形式 / 上限超過 | `errors.add` + `valid?` / `save` の戻り値（§2） | 422 |
| **権限・存在** | 他人の・消えたレコード | 認可済みスコープの `find`、`ensure_*` の `head :forbidden` | 404 / 403 |
| **外部世界**（通信・外部サービス・DB 競合・ファイル） | タイムアウト / DNS / 一意制約 / 壊れた ZIP | **境界で捕まえて**アプリの語彙に翻訳（§4） | `failed` + 理由、固定文のアラート |

同じ `RecordInvalid` でも、フォーム経由なら2行目（`if save`）、UI が起こさせない経路なら1行目（`save!` して 500）。
`create!` が「常に bang」ではないのはこのため。
プログラマの失敗は誰も rescue しないのでクラスは要らない。本番でも消さないアサーション
（fizzy：開発環境以外で flash にマジックリンクが載っていたら `after_action` で `raise`）も同じ。

## 2. ユーザー入力の失敗はバリデーションで受ける

入力の解釈（URL・IP・JSON）はバリデーションメソッドの中で行い、**パース例外はその場で `errors.add` に変える**。

```ruby
def validate_url
  uri = URI.parse(url.presence)
  errors.add :url, "must use http or https" unless uri.scheme.in?(%w[ http https ])
rescue URI::InvalidURIError
  errors.add :url, "is not a URL"
end
```

上限や整合性も例外ではなく `errors.add(:base, "...")`。
複数モデルにまたがる手続き（fizzy の `Signup#complete`）が途中で失敗したら、片付けて
`errors.add(:base, "固定文")` → `false`、例外は `Rails.error.report` へ。コントローラは `if signup.complete`。

## 3. カスタム例外クラスを作る条件と置き場

**作るのは、名前で `rescue` / `retry_on` / `discard_on` する人がいるときだけ。**

| 判断 | 形 |
|---|---|
| 置き場 | オーナークラスの中に1行（`class Archive; class InvalidFileError < StandardError; end`）。`app/errors/` は無い |
| 継承元 | `StandardError` 直下。`ApplicationError` 基底は無い |
| 階層 | 包含関係があるときだけ（fizzy の `ConflictError < IntegrityError`：ジョブは `IntegrityError` だけ `discard_on` すればよい） |
| 名前 | 何が起きたか（`ResponseTooLarge`, `ReconcileAborted`, `TooManyRedirectsError`） |
| メッセージ | 診断に要る値を埋め込む（`"needs ~#{required} free, found #{available}"`） |

```ruby
class Ledger::ReconcileJob < ApplicationJob
  class ReconcileAborted < StandardError; end          # retry_on に名前を渡すために存在する
  retry_on ReconcileAborted, wait: 1.minute, attempts: 3

  def perform(owner)
    raise ReconcileAborted, "Ledger for #{owner.class}##{owner.id} moved during scan" unless owner.reconcile_ledger
  end
end
```

モデルの `reconcile_ledger` は boolean を返すだけ。「リトライすべき」という解釈はジョブの都合なので、ジョブが例外に変換する。

例外：`lib/` に切り出したライブラリ相当のコード（fizzy の WebAuthn）は `Error < StandardError` を基底に
サブクラスを並べ、呼び出し側が1つの名前で rescue できるようにする。アプリ本体には持ち込まない。

## 4. 境界で翻訳する — 外部世界の失敗

境界 PORO / レコード（`logic-placement.md` PORO の 2）の責務に「外の例外を中の語彙に変換する」が含まれる。
変換先は3つ。上から順に検討する。

### 4a. データにする（結果を保存・表示するなら）

```ruby
def perform_request                      # deliver 側は SKILL.md 判断フローD の例
  ...
  { code: response.code.to_i }
rescue Resolv::ResolvError, SocketError
  { error: :dns_failed }
rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ETIMEDOUT
  { error: :timed_out }
rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ECONNRESET
  { error: :unreachable }
rescue OpenSSL::SSL::SSLError
  { error: :tls_failed }
end
```

- 種類ごとにシンボルにして保存。画面と後続判定（`succeeded?`、連続失敗カウンタ）が読むのはデータ
- rescue のグループは列挙する。列挙にないものは知らない失敗なので、未処理のまま上げてよい
- 「成功か」と「なぜ失敗か」は別カラム（`status` と `failure_reason` enum）

### 4b. 小さな例外に翻訳する（上位が名前で分岐するなら）

```ruby
def initialize(io)
  @entries = ZipKit::FileReader.read_zip_structure(io: io)
rescue ZipKit::FileReader::ReadError, ZipKit::FileReader::MissingEOCD => e
  raise Archive::InvalidFileError, e.message
end
```

上位が rescue するのはアプリの語彙だけ。**gem やネットワーク層の例外クラスが境界の外に出たら翻訳漏れ。**

### 4c. nil を返す（ベストエフォートなら）

結果が無くても機能が成立する処理（OGP 展開、legacy データの解釈）は nil にし、**なぜ握るかをコメントに書く**。

| 状況 | 記録 |
|---|---|
| 入力の解釈失敗（不正 URL・JSON） | 無し |
| 外部取得の失敗（unfurl） | `Rails.logger.warn "Failed to fetch #{url} (#{e})"` |
| 起きたら知りたいが止めない | `Rails.error.report(e, context: {...})` |
| 競合の片方（`rescue ActiveRecord::RecordNotUnique # Already starred`） | 無し。冪等の一部 |

### クラス指定なしの `rescue` が許される 4 箇所

1. 失敗状態を保存して `raise` し直す最後の受け（§5）
2. ベストエフォートの取得（4c）
3. 複数モデル手続きの片付け → `errors.add` → `false`（§2）
4. バッチの1件隔離（§7）

`rescue Exception` は Rails のエラー処理が届かない場所だけ：スレッドプールの中と、
ユーザー投稿を描画するビューヘルパー（1件の壊れた投稿で画面全体を落とさない）。必ずログか Sentry に送る。

## 5. 状態を残してから投げ直す

```ruby
def process
  processing!
  ...
  mark_completed
rescue RecordSet::Conflict => e
  mark_as_failed(:conflict)
  raise e
rescue RecordSet::Corrupt, Archive::InvalidFileError => e
  mark_as_failed(:invalid_archive)
  raise e
rescue => e
  mark_as_failed        # 理由不明。failure_reason は nil
  raise e
end
```

- ユーザーは `failed_due_to_conflict?` を、運用者は例外を見る。両方に届く
- **rescue はトランザクションの外に置く。** 中で `failed!` するとロールバックで消える
- テストも2面を見る：`assert_raises(Corrupt) { import.check }` の後に `assert import.failed?`

## 6. コントローラ — 失敗の見せ方

`rescue_from` はほぼ書かない（3実装で1箇所）。`ApplicationController` に `rescue_from StandardError` は無く、
`RecordNotFound` → 404 等は Rails の `rescue_responses`、エラーページは `public/404.html`。`ErrorsController` は作らない。

**アクション直下の `rescue` は、その行が実際に投げるクラスだけ。**

```ruby
def create
  token = Current.identity.tokens.issue(token_params)
  redirect_to edit_my_token_path(token, created: true)
rescue ActiveRecord::RecordNotUnique
  redirect_to my_tokens_path, alert: "A token with that name already exists."
end
```

- 一意制約の競合（同時登録・二重送信）は `rescue RecordNotUnique` で「既にある」側へ。事前の `exists?` では防げない
- パラメータの解釈失敗は 404 に：`Time.zone.parse(params[:day])` を `rescue ArgumentError, TypeError → nil` にし
  `raise ActiveRecord::RecordNotFound unless day`
- JSON / Turbo だけで `errors` を返す必要が無いなら、`update!` + `rescue RecordInvalid → head :unprocessable_entity` でよい

| 状況 | HTML | JSON |
|---|---|---|
| 存在しない / 権限が無くて見せない | 認可済みスコープの `find`（自動で 404） | 同じ |
| `find_by` を意図して使った前置き | `head :not_found`（bot 向け）/ `redirect_to root_url, alert:`（人向け） | `head :not_found` |
| 権限が無い | `head :forbidden` | 同じ |
| バリデーション失敗（フォームあり） | `render :new, status: :unprocessable_entity` | `render json: @record.errors, status: :unprocessable_entity` |
| 操作が成立しなかった（falsy 戻り） | `format.turbo_stream`（現状を再描画） | `head :unprocessable_entity` |
| 期限切れ・使い切り | `render :inactive, status: :gone` | 同じ |
| 認証失敗 | `redirect_to new_session_path, alert:` | `render json: { message: }, status: :unauthorized` |
| レート制限 | `rate_limit ... with: -> { redirect_to ..., alert: }` | `head :too_many_requests` |

JSON の失敗ボディは `@record.errors` か人が読む一文（`{ message: }`）。エラーコード体系は無い。
**ステータスが分類、本文は説明。** `alert:` は固定の一文で、例外メッセージは載せない。

**「成立しなかった」は例外ではなく falsy。** fizzy では `toggle_assignment` → 何もしなければ falsy、
`MagicLink.consume(code)` → nil、`Passkey#authenticate` → nil。コントローラが `if` で 422 やアラートに振り分ける。

## 7. ジョブ — 宣言で決め、本文は 1 行

`ApplicationJob` では決めず、ジョブごとに宣言する（fizzy は 19 ジョブ中 14 が `discard_on ActiveJob::DeserializationError` を書いている）。

| 宣言 | 使う条件 |
|---|---|
| `discard_on ActiveJob::DeserializationError` | レコードが消えたら意味が無いジョブ（ほぼ全部） |
| `discard_on X, report: true`（Rails 8.1+） | 恒久的に無理だが見えていてほしい（ファイルが消えた変換ジョブ） |
| `discard_on(*TERMINAL_ERRORS)` | 再実行しても同じ結果になるドメインの失敗 |
| `retry_on X, wait: :polynomially_longer` | 一時的な原因を名指し（`Net::OpenTimeout`, `Net::SMTPServerBusy`） |
| `retry_on X, wait: 1.minute, attempts: 3` | 再試行で解ける競合（`ReconcileAborted`） |
| `rescue_from X do ... raise end` | 例外のメッセージを見て分けるとき（SMTP 5xx の宛先不在だけ無視、他は `raise`） |

- `retry_on` に生のネットワーク例外を書いてよいのは、境界を自分で持たないとき（ActionMailer の配送）。
  境界を自分で持つなら `Net::*` は境界の中で 4a か 4b に翻訳し、`retry_on` には自前の例外を渡す
- `retry_on StandardError` は無い。`perform` に `rescue` / `retry_job` も書かない
- `ActiveJob::Continuable`（Rails 8.1+）は例外時にステップから再開する。再開してはいけない失敗は
  `resume_job(exception)` をオーバーライドして再 `raise` し、`discard_on` に届かせる
- バッチは1件ずつ隔離：`rescue StandardError => e; Rails.error.report(e, context: { record_id: })` で残りを止めない

## 8. 報告

| 手段 | 用途 |
|---|---|
| `Rails.error.report(e, severity:, context:)` | 握るが知りたい失敗 |
| `Rails.error.add_middleware ->(error, context:, **) { context.merge(account_id: ...) }` | テナントの文脈を全レポートに付ける（initializer に1つ） |
| `Sentry.capture_exception e, level: :info` | 想定内だが件数は見たい |
| `Rails.logger.warn "[Ledger] ... #{self.class}##{id} (#{e})"` | ベストエフォート失敗。機能名 + 識別子を含める |

## 「惰性 → リファレンス実装」対照表（エラー編）

| つい書いてしまう形 | 37signals 流 |
|---|---|
| `app/errors/` + `ApplicationError` 基底 | オーナークラスの中に `class XxxError < StandardError; end` を1行 |
| 意味を込めるためだけの例外クラス | 誰も rescue しないなら `raise "説明"` |
| `rescue_from StandardError` を `ApplicationController` に | 書かない。`rescue_responses` + 静的エラーページ |
| 各層で `rescue => e; logger.error; nil` | 境界1箇所で翻訳。上位はアプリの語彙だけ rescue |
| `Result.failure(:timeout)` / Either 型 | 失敗を持つレコード（`status` + `failure_reason`）か素の例外 |
| ユーザー入力の失敗を `raise InvalidInput` | `errors.add` + falsy 戻り値、422 |
| 「成立しなかった」を例外で通知 | falsy を返し、コントローラが `if` |
| ジョブの `perform` に `rescue => e; retry_job` | `retry_on` / `discard_on` の宣言。本文は1行 |
| 例外を握ってジョブを成功にする | `failed!` してから `raise` |
| `transaction do ... rescue → failed! end` | rescue はトランザクションの外 |
| 事前に `exists?` で重複チェック | 一意制約 + `rescue ActiveRecord::RecordNotUnique` |
| `alert: e.message` | 固定の一文。詳細は `Rails.error.report` へ |
