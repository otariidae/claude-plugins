# rails-design プラグイン

Railsにおける良い設計を支援するためのプラグイン。以下の設計領域をサポートします：

- モデル・コントローラー・エラー設計（`rails-design` スキル）
- テストデータ設計（`factorybot-design` スキル）

## 参考文献

このプラグインは下記を参考に作成しました。すばらしい知見を共有してくださる著者の方々に感謝いたします。

### モデル設計

- [[Rails基礎] DBモデリング基礎講座](https://zenn.dev/igaiga/books/rails-practice-note/viewer/rails_db_modeling_workshop)
- [Simplicity on Rails -- RDB, REST and Ruby](https://speakerdeck.com/moro/simplicity-on-rails-rdb-rest-and-ruby)
- [Railsの仕組みを理解してモデルを上手に育てる - モデルを見つける、モデルを分割する良いタイミング -](https://speakerdeck.com/igaiga/kaigionrails2024/)
- [[ActiveRecord] 複数のモデルにまたがる処理を書きたいときの設計方法](https://zenn.dev/igaiga/books/rails-practice-note/viewer/ar_processing_across_multiple_models)
- [Identifying User Idenity](https://speakerdeck.com/moro/identifying-user-idenity)
- [楽々ERDレッスン 第1回：「お持ち帰りご注文用紙」編](https://codezine.jp/article/detail/154)
- [楽々ERDレッスン 第2回：「図書館の予約申込書」編](https://codezine.jp/article/detail/175)

### 37signals のリファレンス実装

- https://rubyonrails.org/docs/reference-apps
- [basecamp/fizzy](https://github.com/basecamp/fizzy)（O'Saasy License）— `ebfb067`
- [basecamp/once-campfire](https://github.com/basecamp/once-campfire)（MIT）— `ef147d1`
- [basecamp/writebook](https://github.com/basecamp/writebook)（ソース公開・OSS ではない）— `3f98703`
- [Vanilla Rails is plenty](https://dev.37signals.com/vanilla-rails-is-plenty/)

いずれもライセンスが CC0-1.0 ではないため、`references/*.md` のコード例は
すべて架空ドメインで書き起こした自作の最小例です。逐語のコピーは含みません。

### factory_bot

- [FactoryBot公式ドキュメント](https://thoughtbot.github.io/factory_bot/)
- [FactoryBotを使う時に覚えておきたい、たった5つのこと](https://qiita.com/piggydev/items/32717b6c382272e2134e)
- [FactoryBot the Right Way - Speaker Deck](https://speakerdeck.com/toshimaru/factorybot-the-right-way)
- [FactoryBotアンチパターン8選](https://zenn.dev/readyfor_blog/articles/8be2e10830c797)
- [FactoryBotにおける関連の扱いと、factory_bot-with gemを作った話](https://zenn.dev/yubrot/articles/032447068e308e)
