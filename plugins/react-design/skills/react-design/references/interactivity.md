# インタラクティビティの追加 - 設計ガイド

State管理、イベント処理、レンダーサイクルにおける設計判断とよくある落とし穴。

## イベントハンドリングの落とし穴

### 関数を渡す vs 呼び出す

```javascript
// ❌ レンダー中に実行される（最も一般的なミス）
<button onClick={handleClick()}>

// ✅ 関数を渡す
<button onClick={handleClick}>

// ✅ インライン（引数を渡したい場合）
<button onClick={() => handleClick(id)}>
```

### 伝播制御の判断

**stopPropagation を使うべき場合**:
- 親要素のイベントハンドラと競合する
- 分析トラッキングが二重に発火する
- モーダル外側のクリックを無視したい

**stopPropagation を避けるべき場合**:
- イベント委譲パターンを壊す
- グローバルなクリックリスナーが必要

```javascript
// ✅ 適切な使用例
function Button({ onClick, children }) {
  return (
    <button onClick={e => {
      e.stopPropagation(); // 親のonClickを防ぐ
      onClick();
    }}>
      {children}
    </button>
  );
}
```

## State 設計の判断基準

### useState vs 通常の変数

**useStateを使うべき場合**:
- 値が変わったときにUIを更新したい
- レンダー間で値を保持したい

**通常の変数で十分な場合**:
- レンダー中に計算できる値
- イベントハンドラ内でのみ使う一時的な値

```javascript
// ❌ 不要なState（派生値）
const [fullName, setFullName] = useState('');
useEffect(() => {
  setFullName(firstName + ' ' + lastName);
}, [firstName, lastName]);

// ✅ レンダー時に計算
const fullName = firstName + ' ' + lastName;
```

### 複数のState変数 vs 1つのオブジェクト

**分離すべき場合**:
- 独立して更新される
- 互いに関係がない

**統合すべき場合**:
- 常に同時に更新される
- 密接に関連している（座標のx,yなど）

```javascript
// ❌ 常に同時に更新するなら分離は不適切
const [x, setX] = useState(0);
const [y, setY] = useState(0);
// 常にセットで更新...

// ✅ まとめる
const [position, setPosition] = useState({ x: 0, y: 0 });
```

### State の配置判断

**コンポーネントローカルに置くべき場合**:
- 1つのコンポーネントのみが使用
- 他のコンポーネントに影響しない

**リフトアップすべき場合**:
- 複数のコンポーネントが同じデータを使う
- 兄弟コンポーネント間で同期が必要

## レンダーサイクルの理解

### レンダーをトリガする唯一の方法

1. **初回レンダー**: `root.render(<App />)`
2. **State更新**: `setState`関数の呼び出し

**重要**: Props変更は親の再レンダーが原因。Props自体はレンダーをトリガしない。

### コミットの最適化

Reactは差分がない場合、DOMを変更しない:

```javascript
// 毎秒再レンダーされるが、時刻が変わらない限りDOMは更新されない
function Clock({ time }) {
  return <h1>{time}</h1>;
}
```

**活用**: 重い計算をしても、結果が同じならDOM更新コストはゼロ。

## State スナップショットの落とし穴

### State更新は即座に反映されない

```javascript
// ❌ よくある誤解
function handleClick() {
  setCount(count + 1);
  console.log(count); // 古い値！
  alert(count);       // 古い値！
}

// ✅ 理解: 次のレンダーで反映される
function handleClick() {
  setCount(count + 1); // 次のレンダーで count は +1
  // この関数内では count は変わらない
}
```

### タイムアウト内でも固定

```javascript
function handleClick() {
  setCount(count + 1);
  setTimeout(() => {
    alert(count); // クリック時の値（古い値）
  }, 3000);
}
```

**対策**: Stateが必要なら、タイムアウト前に変数に保存:

```javascript
function handleClick() {
  const nextCount = count + 1;
  setCount(nextCount);
  setTimeout(() => {
    alert(nextCount); // 更新後の値
  }, 3000);
}
```

## State 更新のキューイング

### 連続更新の問題

```javascript
// ❌ 期待: count が 3 増える。実際: 1 だけ増える
function handleClick() {
  setCount(count + 1); // setCount(0 + 1)
  setCount(count + 1); // setCount(0 + 1)
  setCount(count + 1); // setCount(0 + 1)
}
```

### 更新用関数で解決

```javascript
// ✅ count が 3 増える
function handleClick() {
  setCount(c => c + 1); // キューに追加: 0 => 1
  setCount(c => c + 1); // キューに追加: 1 => 2
  setCount(c => c + 1); // キューに追加: 2 => 3
}
```

### 混在パターンの理解

```javascript
setCount(count + 1);     // setCount(0 + 1) = setCount(1)
setCount(c => c + 1);    // 1 => 2
setCount(42);            // setCount(42)
setCount(c => c + 1);    // 42 => 43
// 最終結果: 43
```

**処理順序**:
1. `setCount(1)` → 次の値を1に設定
2. `c => c + 1` → 1を受け取り2を返す
3. `setCount(42)` → 次の値を42に設定
4. `c => c + 1` → 42を受け取り43を返す

### 使い分けの指針

- **単純な代入**: `setState(newValue)`
- **前のStateに基づく更新**: `setState(prev => prev + 1)`
- **複数回の更新**: 必ず更新用関数を使う

## オブジェクトと配列の State

### ミューテーション禁止の理由

```javascript
const [position, setPosition] = useState({ x: 0, y: 0 });

// ❌ Reactが変更を検知できない
position.x = 5;

// ❌ setPositionを呼んでも同一オブジェクトなので再レンダーされない
position.x = 5;
setPosition(position);
```

**Reactの同一性チェック**: `Object.is(oldState, newState)`で判定。

### オブジェクト更新のパターン

```javascript
// ✅ 新しいオブジェクトを作成
setPosition({ ...position, x: 5 });

// ✅ ネストされたオブジェクト
setPerson({
  ...person,
  address: {
    ...person.address,
    city: '大阪'
  }
});
```

### 配列更新のパターン

| 操作 | 避ける | 推奨 |
|---|---|---|
| 追加 | `push`, `unshift` | `[...arr, item]`, `[item, ...arr]` |
| 削除 | `pop`, `shift`, `splice` | `filter`, `slice` |
| 置換 | `arr[i] = x` | `map` |
| ソート | `sort`, `reverse` | `[...arr].sort()` |

```javascript
// ❌ 配列を直接変更
items.push(newItem);
setItems(items);

// ✅ 新しい配列を作成
setItems([...items, newItem]);

// ✅ 要素を置換
setItems(items.map(item =>
  item.id === targetId ? { ...item, done: !item.done } : item
));

// ✅ 要素を削除
setItems(items.filter(item => item.id !== targetId));
```

### Immer で簡潔に

ネストが深い場合、Immerを使用:

```javascript
import { useImmer } from 'use-immer';

const [person, updatePerson] = useImmer({
  name: '太郎',
  address: { city: '東京', street: '渋谷' }
});

// ミューテーション構文で書けるが、実際には新しいオブジェクト
updatePerson(draft => {
  draft.address.city = '大阪';
});
```

**Immerを使うべき場合**:
- 3階層以上のネスト
- 複数のフィールドを更新
- スプレッド構文が読みにくくなる

## 設計チェックリスト

- [ ] イベントハンドラで関数を呼び出していない
- [ ] 派生値をStateにしていない
- [ ] 連続更新で更新用関数を使っている
- [ ] State内のオブジェクト/配列を直接変更していない
- [ ] スプレッド構文で新しいオブジェクトを作成している
- [ ] 深いネストではImmerを検討している

## パフォーマンス最適化のヒント

### 不要な再レンダーを避ける

```javascript
// ❌ 毎回新しいオブジェクト（不要な再レンダー）
<ChildComponent config={{ url: 'https://api.example.com' }} />

// ✅ 安定した参照
const config = { url: 'https://api.example.com' };
<ChildComponent config={config} />

// ✅ または useMemo
const config = useMemo(() => ({ url: 'https://api.example.com' }), []);
```

### State 更新のバッチング

React 18以降、すべてのState更新は自動的にバッチされる:

```javascript
// 自動的に1回の再レンダーにまとめられる
setCount(c => c + 1);
setName('太郎');
setEmail('taro@example.com');
```

**例外なくバッチされる場所**:
- イベントハンドラ
- タイムアウト
- Promise
- ネイティブイベント

## よくある質問

**Q: Stateが更新されない。なぜ？**
A: オブジェクト/配列を直接変更している可能性。新しいオブジェクトを作成して`setState`を呼ぶ。

**Q: `setState`直後に新しい値を読みたい**
A: 不可能。次のレンダーまで待つか、変数に保存する。どうしても必要なら`useEffect`で監視。

**Q: 複数のStateを同時に更新したい**
A: React 18以降は自動的にバッチされるため、個別に`setState`を呼べば良い。
