# エラー設計とエラーハンドリング

判断フローD の詳細。**どこで捕まえ、何に変換し、誰に見せるか**だけ。
**既定は「何もしない」。**

## 1. 失敗は 4 種類

| 誰の失敗か | 扱い | 見えるもの |
|---|---|---|
| **プログラマ**（前提違反・抽象メソッド） | `raise "説明"` / `ArgumentError` / `NotImplementedError`。rescue しない | 500 |
| **ユーザー入力** | `errors.add` + `valid?` / `save` の戻り値（§2） | 422 |
| **権限・存在** | 認可済みスコープの `find`、`ensure_*` の `head :forbidden` | 404 / 403 |
| **外部世界** | **境界で捕まえて**アプリの語彙に翻訳（§4） | `failed` + 理由、固定文のアラート |

同じ `RecordInvalid` でも、フォーム経由なら `if save`、UI が起こさせない経路なら `save!`（500）。
プログラマの失敗は誰も rescue しないのでクラスは要らない。

## 2. ユーザー入力はバリデーションで受ける

```ruby
validate :validate_url

def validate_url
  uri = URI.parse(url.presence)
  errors.add :url, "must use http or https" unless uri.scheme.in?(%w[ http https ])
rescue URI::InvalidURIError
  errors.add :url, "is not a URL"
end
```

複数モデル手続きが途中で失敗したら、片付けて `errors.add` → `false`、例外は `Rails.error.report` へ。

```ruby
# Signup など ActiveModel::Model の手続き PORO
def complete
  return false unless valid?

  @user = User.create!(email:)
  @user.create_default_project!
  true
rescue => e
  @user&.destroy
  errors.add :base, "Could not complete sign-up"
  Rails.error.report(e, severity: :error)
  false
end
```

## 3. カスタム例外 — この失敗だけ別扱いするとき

原因が違うだけでは切らない。**その後の対処・記録・見えるものが分岐するとき**だけ。

```
この失敗の「その後」は他と同じでよいか？
├ 同じ（同じ retry / 同じ failed / 同じログ / 同じ nil）
│   → raise "説明" / ArgumentError 等。クラス不要
└ 違う（retry と discard、failure_reason、翻訳先、見える理由が分かれる）
    → 別扱い → オーナークラスに class Xxx < StandardError; end を1行
```

別扱いの手段が `rescue` / `retry_on` / `discard_on` / 翻訳先の分岐。型がキーになる。

| 判断 | 形 |
|---|---|
| 置き場 | オーナークラス内に1行。`app/errors/` / `ApplicationError` 基底は無い |
| 階層 | 包含関係があるときだけ（ジョブは基底だけ `discard_on` すればよい） |
| 名前 / メッセージ | 何が起きたか / 診断に要る値 |

```ruby
class Ledger::ReconcileJob < ApplicationJob
  class ReconcileAborted < StandardError; end
  retry_on ReconcileAborted, wait: 1.minute, attempts: 3

  def perform(owner)
    raise ReconcileAborted, "Ledger for #{owner.class}##{owner.id} moved during scan" unless owner.reconcile_ledger
  end
end
```

モデルは boolean を返すだけ。「リトライすべき」はジョブの都合なのでジョブが例外に変換する。

ジョブ以外は、記録する理由が分岐するとき。捕まえたら状態を残してから `raise` し直す。

```ruby
class Archive::Import < ApplicationRecord
  class InsufficientSpace < StandardError; end

  def process
    ensure_space!
    extract_and_apply!
  rescue InsufficientSpace
    mark_as_failed(:insufficient_space)
    raise
  end

  private
    def ensure_space!
      raise InsufficientSpace, "needs ~#{needed} free, found #{available}" if available < needed
    end
end
```

`lib/` のライブラリ相当だけ `Error < StandardError` 基底を置いてよい。アプリ本体には持ち込まない。

## 4. 境界で翻訳する

境界 PORO / レコードの責務。変換先は上から順に。

### 4a. データ（結果を保存・表示するなら）

外部への1回の試行をレコードに残すとき（Webhook 配送など）。

```ruby
# Webhook::Delivery 相当
def perform_request
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

def deliver
  processing!
  self.response = perform_request  # 成功も失敗もハッシュ。例外にはしない
  self.status = :completed
  save!
rescue
  failed!   # 状態保存や save! 自体が落ちたとき。transaction の外で。中だとロールバックで消える
  raise     # ジョブの retry_on / discard_on へ
end
```

rescue のグループは列挙する。「成功か」と「なぜ失敗か」は別の場所（ここでは `status` と `response[:error]`）。
テストも2面: `assert_raises` の後に `assert record.failed?`。

### 4b. アプリの例外型へ（別扱いするために型が要るなら）

外の例外をそのまま出さず、オーナークラスの型に載せ替える。中身はメッセージの引き渡し程度でよい（§3）。

```ruby
rescue ZipKit::FileReader::ReadError, ZipKit::FileReader::MissingEOCD => e
  raise Archive::InvalidFileError, e.message
```

**gem / ネットワーク層の例外が境界の外に出たら翻訳漏れ。**

### 4c. nil（ベストエフォート）

**主処理を止めたくない／無くても成立する付加的なこと**のとき。失敗の見える結果は「無し」でよく、理由をレコードに残す必要もない。

記録: 無し / `logger.warn` / `Rails.error.report`（知りたいが止めない）。

```ruby
# Opengraph プレビューなど。本体の投稿はすでに成立している
def fetch_html
  Opengraph::Fetch.new.fetch_document(url)
rescue => e
  Rails.logger.warn "Failed to fetch #{url} (#{e})"  # なぜ握るか: プレビューは付加
  nil
end
```

### クラス指定なしの `rescue` が許される箇所

1. 失敗状態を保存して `raise` し直す（4a）
2. ベストエフォート（4c）
3. 複数モデル手続きの片付け → `errors.add` → `false`（§2）
4. バッチの1件隔離（§6）

`rescue Exception` は Rails のエラー処理が届かない場所だけ（スレッドプール、壊れた投稿1件で画面全体を落とさないビュー）。必ずログか Sentry へ。

## 5. コントローラ

`ApplicationController` に `rescue_from StandardError` は無い。404 等は `rescue_responses`。
**アクション直下の `rescue` は、その行が実際に投げるクラスだけ。**

```ruby
def create
  token = Current.identity.tokens.issue(token_params)
  redirect_to edit_my_token_path(token, created: true)
rescue ActiveRecord::RecordNotUnique
  redirect_to my_tokens_path, alert: "A token with that name already exists."
end
```

| 状況 | 応答 |
|---|---|
| 存在しない / 見せない | 認可済みスコープの `find`（404） |
| 権限が無い | `head :forbidden` |
| バリデーション失敗（フォームあり） | `render :new, status: :unprocessable_entity`（JSON は `@record.errors`） |
| 操作が成立しなかった（falsy） | turbo_stream 再描画 / `head :unprocessable_entity` |
| 期限切れ | `render :inactive, status: :gone` |
| 認証失敗 | `redirect_to new_session_path, alert:` / `401` |
| レート制限 | `rate_limit ...` / `429` |

**ステータスが分類、本文は説明。** `alert:` は固定文（`e.message` は載せない）。
「成立しなかった」は falsy。コントローラが `if` で振り分ける。

## 6. ジョブ — 宣言で決め、本文は 1 行

| 宣言 | 使う条件 |
|---|---|
| `discard_on ActiveJob::DeserializationError` | レコード消滅で意味が無いジョブ（ほぼ全部） |
| `discard_on X, report: true`（Rails 8.1+） | 恒久的だが見えていてほしい |
| `retry_on X, wait: :polynomially_longer` | 一時的な原因を名指し |
| `retry_on X, wait: 1.minute, attempts: 3` | 再試行で解ける競合 |
| `rescue_from X do ... raise end` | メッセージを見て分けるとき |

- 生の `Net::*` を `retry_on` してよいのは境界を自分で持たないとき（ActionMailer）。持つなら境界で翻訳
- `retry_on StandardError` / `perform` 内の `rescue` / `retry_job` は書かない
- `Continuable` で再開不可の失敗は `resume_job` を再 `raise` して `discard_on` へ
- バッチは1件隔離: `rescue StandardError => e; Rails.error.report(e, context: { record_id: })`

## 7. 報告

`Rails.error.report`（握るが知りたい）/ `add_middleware` でテナント文脈 /
`Sentry.capture_exception`（件数は見たい）/ `logger.warn "[機能] ..."`（ベストエフォート）。
