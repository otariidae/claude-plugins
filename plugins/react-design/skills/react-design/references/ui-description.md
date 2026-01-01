# UIの記述 - 設計ガイド

設計判断、ベストプラクティス、よくある落とし穴に焦点を当てたガイド。

## コンポーネント設計の判断基準

### いつコンポーネントを分割すべきか

**分割すべき場合**:
- 同じUIパターンが3回以上出現
- コンポーネントが200行を超える
- 複数の独立した責務を持つ

**分割すべきでない場合**:
- 1箇所でしか使わない単純な要素
- 分割によってprops drillingが深刻化する
- 過度な抽象化になる（YAGNI原則）

### コンポーネント定義のネスト禁止

```javascript
// ❌ 致命的エラー: パフォーマンス低下とバグの原因
function Gallery() {
  function Profile() {
    return <img />;
  }
  return <Profile />;
}

// ✅ 必ずトップレベルで定義
function Profile() {
  return <img />;
}
function Gallery() {
  return <Profile />;
}
```

**理由**: ネストすると毎回新しいコンポーネント定義が作られ、Stateがリセットされる。

## JSX 設計のポイント

### 単一ルートの回避: Fragment

余計なDOMノードを避けるため`<></>`を使用:

```javascript
// ✅ 不要なdivを追加しない
return (
  <>
    <h1>タイトル</h1>
    <p>本文</p>
  </>
);
```

### style属性の二重中括弧

`style`属性はオブジェクトを受け取るため二重中括弧:

```javascript
<img style={{ width: user.imageSize, height: user.imageSize }} />
```

外側は「JSXの中括弧」、内側は「JavaScriptオブジェクト」。

## Props 設計のベストプラクティス

### Props は読み取り専用

```javascript
// ❌ Propsを変更してはいけない
function Avatar({ person }) {
  person.name = '変更後'; // 絶対NG！
}

// ✅ Stateを使用
function Avatar({ person }) {
  const [name, setName] = useState(person.name);
  setName('変更後');
}
```

### スプレッド構文の使用判断

**使うべき場合**:
- ラッパーコンポーネントで全propsを転送
- 多数のpropsを渡す必要がある

**避けるべき場合**:
- 可読性が重要
- どのpropsが使われているか明示したい

```javascript
// ⚠️ 何が渡されているか不明瞭
<Avatar {...props} />

// ✅ 明示的
<Avatar person={person} size={size} />
```

### children パターンの活用

コンテンツのラッパーには`children`を使用:

```javascript
function Card({ children }) {
  return <div className="card">{children}</div>;
}

// 使用側がコンテンツを制御できる
<Card>
  <Avatar />
  <h1>太郎</h1>
</Card>
```

## 条件付きレンダリングの落とし穴

### && 演算子の数値ゼロ問題

```javascript
// ❌ messageCount が 0 の場合、0 が表示される
{messageCount && <p>新着メッセージ</p>}

// ✅ 必ず真偽値に変換
{messageCount > 0 && <p>新着メッセージ</p>}
```

### 複雑な条件は変数に抽出

```javascript
// ❌ JSX内に複雑なロジック
return (
  <li>
    {isPacked ? (
      isFragile ? <del>{name + ' ⚠️'}</del> : <del>{name + ' ✔'}</del>
    ) : (
      isFragile ? name + ' ⚠️' : name
    )}
  </li>
);

// ✅ 変数に抽出して可読性向上
let itemContent = name;
if (isPacked && isFragile) {
  itemContent = <del>{name + ' ⚠️'}</del>;
} else if (isPacked) {
  itemContent = <del>{name + ' ✔'}</del>;
} else if (isFragile) {
  itemContent = name + ' ⚠️';
}
return <li>{itemContent}</li>;
```

## リストレンダリングのベストプラクティス

### key の選択基準（重要度順）

1. **データベースのID**: データがDB由来なら必ずこれを使う
2. **UUID/crypto.randomUUID()**: ローカル生成データ用
3. **配列インデックス**: 最終手段。順序が不変な場合のみ

```javascript
// ❌ インデックスをkeyに使うと並び替え時にバグ
people.map((person, index) => <li key={index}>{person.name}</li>);

// ✅ 安定したIDを使用
people.map(person => <li key={person.id}>{person.name}</li>);
```

### key が必要な理由

keyがないと、Reactはリストの順序変更時に以下の問題が発生:
- 間違った要素のStateが保持される
- フォーム入力値が別の要素に移動
- アニメーションが不自然になる

### Fragment で key を渡す

`<></>`短縮構文はkeyを受け付けないため、明示的に`<Fragment>`を使用:

```javascript
import { Fragment } from 'react';

const listItems = people.map(person =>
  <Fragment key={person.id}>
    <h1>{person.name}</h1>
    <p>{person.bio}</p>
  </Fragment>
);
```

## コンポーネントの純粋性

### 純粋性違反の典型例

```javascript
// ❌ レンダー中に外部変数を変更
let guest = 0;
function Cup() {
  guest = guest + 1; // 副作用！
  return <h2>Tea cup for guest #{guest}</h2>;
}
```

**問題**: StrictModeや並行レンダリング時に予測不可能な動作。

### 純粋性を保つ方法

```javascript
// ✅ Propsで渡す
function Cup({ guest }) {
  return <h2>Tea cup for guest #{guest}</h2>;
}
```

### 副作用の適切な場所

- **イベントハンドラ**: ユーザー操作に応答する副作用
- **useEffect**: レンダー後に実行される副作用

```javascript
// ✅ イベントハンドラ内での副作用はOK
function Button({ onClick }) {
  return (
    <button onClick={() => {
      console.log('クリック'); // OK
      onClick();
    }}>
      クリック
    </button>
  );
}
```

### StrictMode の活用

開発時にコンポーネントを2回呼び出して純粋性を検証:

```javascript
// 本番: 1回呼び出し
// 開発: 2回呼び出し（純粋でない関数を検出）
```

2回呼び出しても結果が変わらなければ、コンポーネントは純粋。

## 設計チェックリスト

UIの記述における設計判断:

- [ ] コンポーネントをトップレベルで定義している
- [ ] 適切な粒度で分割している（過度な抽象化を避ける）
- [ ] Propsを変更していない
- [ ] `&&`演算子の左側を真偽値にしている
- [ ] リストに安定したkeyを使用している
- [ ] レンダー中に副作用を起こしていない
- [ ] StrictModeで純粋性を検証している

## よくある質問

**Q: いつFragmentを使うべきか？**
A: 余計なDOMノードを避けたい場合。ただし、CSSのflexbox/gridレイアウトでは追加の`<div>`が必要なこともある。

**Q: keyに`Math.random()`を使っても良いか？**
A: 絶対にダメ。毎回新しいkeyが生成され、全要素が再作成される。

**Q: コンポーネントの純粋性を妥協できる場合はあるか？**
A: イベントハンドラとuseEffect内でのみ。レンダー中は絶対に純粋を保つ。
