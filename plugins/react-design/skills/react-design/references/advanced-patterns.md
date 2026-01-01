# 高度なパターン（避難ハッチ） - 設計ガイド

Ref、Effect、カスタムフックにおける設計判断とよくある落とし穴。「避難ハッチ」は必要最小限に使用すべき。

## Ref の使用判断

### useState vs useRef

| 特性 | useState | useRef |
|---|---|---|
| 更新時 | 再レンダーをトリガ | 再レンダーをトリガしない |
| 変更 | イミュータブル | ref.current は変更可能 |
| レンダー中 | 読み取りOK | 読み取り・書き込み禁止 |

### Ref を使うべき場合

- タイムアウト/インターバルIDの保存
- DOM要素の参照
- 再レンダーをトリガすべきでない値の保存

### Ref を避けるべき場合

- レンダー出力に影響する値 → `useState`を使う
- 計算可能な値 → レンダー時に計算

```javascript
// ❌ レンダー出力に影響するなら State
const countRef = useRef(0);
return <h1>{countRef.current}</h1>; // バグ: 更新されても再レンダーされない

// ✅ State を使用
const [count, setCount] = useState(0);
return <h1>{count}</h1>;
```

### Ref の制約

```javascript
// ❌ レンダー中に読み書き禁止
function Component() {
  const ref = useRef(0);
  ref.current = ref.current + 1; // バグ！
  return <div>{ref.current}</div>;
}

// ✅ イベントハンドラや Effect で使用
function Component() {
  const ref = useRef(0);

  function handleClick() {
    ref.current = ref.current + 1; // OK
  }

  return <button onClick={handleClick}>クリック</button>;
}
```

## DOM 操作の判断

### DOM 操作すべき場合

- フォーカス制御
- スクロール位置の制御
- サイズ/位置の測定
- 非React製ライブラリとの統合

### React で宣言的に表現すべき場合

- 要素の表示/非表示 → 条件付きレンダリング
- クラスの追加/削除 → State で管理
- テキストの変更 → State で管理

```javascript
// ❌ DOM を直接操作
inputRef.current.style.display = isVisible ? 'block' : 'none';

// ✅ 宣言的に表現
{isVisible && <input />}
```

### forwardRef の使用判断

**使うべき場合**:
- 再利用可能なUI部品（Input、Button など）
- DOM要素への直接アクセスを提供したい

**避けるべき場合**:
- アプリケーション固有のコンポーネント
- 内部実装の詳細を隠蔽したい

### useImperativeHandle でメソッド制限

```javascript
import { forwardRef, useRef, useImperativeHandle } from 'react';

const MyInput = forwardRef((props, ref) => {
  const inputRef = useRef(null);

  useImperativeHandle(ref, () => ({
    // 公開するメソッドのみ定義
    focus() {
      inputRef.current.focus();
    },
    scrollIntoView() {
      inputRef.current.scrollIntoView();
    }
    // DOM要素全体は公開しない
  }), []);

  return <input ref={inputRef} {...props} />;
});
```

**利点**: カプセル化を保ち、内部実装を変更しやすくなる。

## Effect の設計判断

### Effect を使うべき場合

外部システムとの同期のみ:
- サーバー接続（WebSocket、SSE）
- 非React製ウィジェット（地図、チャート）
- ブラウザAPI（localStorage、Intersection Observer）
- 分析トラッキング（ページビュー）

### Effect を避けるべき場合

**1. レンダーのためのデータ変換**

```javascript
// ❌ Effect で計算
const [todos, setTodos] = useState([]);
const [visibleTodos, setVisibleTodos] = useState([]);
useEffect(() => {
  setVisibleTodos(todos.filter(todo => !todo.completed));
}, [todos]);

// ✅ レンダー時に計算
const visibleTodos = todos.filter(todo => !todo.completed);

// ✅ 重い計算なら useMemo
const visibleTodos = useMemo(
  () => todos.filter(todo => !todo.completed),
  [todos]
);
```

**2. ユーザーイベントの処理**

```javascript
// ❌ Effect でイベント処理
const [purchased, setPurchased] = useState(false);
useEffect(() => {
  if (purchased) {
    post('/api/buy', { productId });
  }
}, [purchased, productId]);

// ✅ イベントハンドラで処理
function handleBuyClick() {
  post('/api/buy', { productId });
}
```

**3. アプリ初期化**

```javascript
// ❌ Effect で初期化
function App() {
  useEffect(() => {
    loadDataFromLocalStorage();
  }, []);
}

// ✅ モジュールレベルで初期化
if (typeof window !== 'undefined') {
  loadDataFromLocalStorage();
}
function App() { ... }
```

## 依存配列の設計

### すべてのリアクティブ値を含める

```javascript
// ❌ roomId を依存配列から除外
useEffect(() => {
  const connection = createConnection(serverUrl, roomId);
  connection.connect();
  return () => connection.disconnect();
}, [serverUrl]); // roomId が変わっても再接続されない！

// ✅ すべてのリアクティブ値を含める
useEffect(() => {
  const connection = createConnection(serverUrl, roomId);
  connection.connect();
  return () => connection.disconnect();
}, [serverUrl, roomId]);
```

**Linter を信頼する**: `eslint-plugin-react-hooks` の警告に従う。

### 依存値を減らす方法

**1. Effect 内に移動**

```javascript
// ❌ オブジェクトが依存値（毎回新しいオブジェクト）
const options = { serverUrl, roomId };
useEffect(() => {
  const connection = createConnection(options);
  connection.connect();
  return () => connection.disconnect();
}, [options]); // 毎回再接続！

// ✅ Effect 内で作成
useEffect(() => {
  const options = { serverUrl, roomId };
  const connection = createConnection(options);
  connection.connect();
  return () => connection.disconnect();
}, [serverUrl, roomId]);
```

**2. プリミティブ値のみ使用**

```javascript
// ✅ オブジェクトではなく、個別の値を依存配列に
useEffect(() => {
  const connection = createConnection(serverUrl, roomId);
  connection.connect();
  return () => connection.disconnect();
}, [serverUrl, roomId]); // プリミティブ値
```

**3. useCallback/useMemo で安定化**

```javascript
// ❌ 関数が依存値（毎回新しい関数）
function createOptions() {
  return { serverUrl, roomId };
}
useEffect(() => {
  const options = createOptions();
  const connection = createConnection(options);
  connection.connect();
  return () => connection.disconnect();
}, [createOptions]); // 毎回再接続！

// ✅ useCallback で安定化
const createOptions = useCallback(() => {
  return { serverUrl, roomId };
}, [serverUrl, roomId]);

useEffect(() => {
  const options = createOptions();
  const connection = createConnection(options);
  connection.connect();
  return () => connection.disconnect();
}, [createOptions]); // serverUrl/roomId が変わるときのみ再接続
```

### Effect のライフサイクル

Effect は「同期の開始」と「同期の停止」の2段階のみ。コンポーネントのライフサイクルとは独立。

```javascript
// ✅ 各 Effect は独立した同期プロセス
useEffect(() => {
  // チャットルームに接続（同期開始）
  const connection = createConnection(roomId);
  connection.connect();
  return () => {
    // チャットルームから切断（同期停止）
    connection.disconnect();
  };
}, [roomId]);

useEffect(() => {
  // 分析イベント送信（独立したプロセス）
  logVisit(url);
}, [url]);
```

## カスタムフックの設計

### カスタムフック作成の判断

**作成すべき場合**:
- Effect ロジックが複数コンポーネントで繰り返される
- Effect の目的が明確で名前を付けられる
- Effect が3つ以上の組み込みフックを使用

**作成すべきでない場合**:
- 1箇所でのみ使用される
- ロジックが単純（useState + 1つのEffect程度）
- 抽象化によって理解が難しくなる

### カスタムフックの命名

- 必ず `use` で始める: `useOnlineStatus`, `useFetch`
- 何を返すかが明確な名前: `useFormValidation`, `useLocalStorage`

### State は共有されない

```javascript
// ✅ 各呼び出しは独立した State を持つ
function StatusBar() {
  const isOnline = useOnlineStatus(); // 独自の State
}

function SaveButton() {
  const isOnline = useOnlineStatus(); // 別の独自の State
}
```

**State を共有したい場合**: Context を使用。

### カスタムフックの設計パターン

```javascript
// ✅ 引数でカスタマイズ可能に
function useChatRoom({ serverUrl, roomId }) {
  useEffect(() => {
    const connection = createConnection(serverUrl, roomId);
    connection.connect();
    return () => connection.disconnect();
  }, [serverUrl, roomId]);
}

// ✅ 複数の値を返す
function useFormInput(initialValue) {
  const [value, setValue] = useState(initialValue);
  const [error, setError] = useState('');

  function validate() {
    if (!value) {
      setError('必須項目です');
      return false;
    }
    setError('');
    return true;
  }

  return { value, setValue, error, validate };
}
```

## よくあるアンチパターン

### 1. Effect の過度な使用

```javascript
// ❌ Effect を何にでも使う
useEffect(() => {
  setFullName(firstName + ' ' + lastName);
}, [firstName, lastName]);

// ✅ レンダー時に計算
const fullName = firstName + ' ' + lastName;
```

### 2. 不要な依存値

```javascript
// ❌ 関数を依存配列に
function Component({ onSuccess }) {
  useEffect(() => {
    doSomething();
    onSuccess();
  }, [onSuccess]); // 親が再レンダーされるたびに実行
}

// ✅ useEffectEvent（実験的機能）
import { useEffectEvent } from 'react';

function Component({ onSuccess }) {
  const onSuccessEvent = useEffectEvent(onSuccess);

  useEffect(() => {
    doSomething();
    onSuccessEvent(); // 依存配列に含めなくてOK
  }, []);
}
```

### 3. Effect チェーン

```javascript
// ❌ Effect が Effect をトリガ（多重レンダー）
const [data, setData] = useState(null);
const [processed, setProcessed] = useState(null);

useEffect(() => {
  fetch('/api/data').then(setData);
}, []);

useEffect(() => {
  if (data) {
    setProcessed(processData(data));
  }
}, [data]);

// ✅ 1つの Effect にまとめる
useEffect(() => {
  fetch('/api/data').then(response => {
    setProcessed(processData(response));
  });
}, []);
```

## 設計チェックリスト

- [ ] Ref をレンダー中に読み書きしていない
- [ ] DOM 操作を最小限にしている（宣言的に表現できないか確認）
- [ ] Effect を外部システムとの同期にのみ使用している
- [ ] すべてのリアクティブ値を依存配列に含めている
- [ ] 不要な依存値を Effect 内に移動している
- [ ] 各 Effect が独立した同期プロセスを表現している
- [ ] カスタムフックの名前が `use` で始まっている

## パフォーマンス最適化

### useMemo で重い計算をメモ化

```javascript
// ✅ 重い計算を最適化
const visibleTodos = useMemo(() => {
  return filterTodos(todos, tab); // 重い計算
}, [todos, tab]);
```

**使うべき場合**:
- 計算が明らかに重い（数千要素の配列操作など）
- 子コンポーネントに渡すオブジェクト/配列

**不要な場合**:
- 単純な計算（文字列結合、数値演算）
- コンポーネントが十分高速

### useCallback でイベントハンドラを安定化

```javascript
// ✅ メモ化された子コンポーネントに渡す場合
const handleClick = useCallback(() => {
  doSomething(value);
}, [value]);

return <MemoizedChild onClick={handleClick} />;
```

**使うべき場合**:
- `React.memo` された子コンポーネントに渡す
- 他のフックの依存配列に含まれる

**不要な場合**:
- 通常のイベントハンドラ（過度な最適化）

## よくある質問

**Q: Effect を空の依存配列で実行すると警告が出る**
A: Effect が使用するすべてのリアクティブ値を依存配列に含める。警告を無視しない。

**Q: Effect が無限ループする**
A: 依存配列に毎回新しく作成されるオブジェクト/配列/関数が含まれている。Effect 内に移動するか、useMemo/useCallback で安定化。

**Q: カスタムフックでStateを共有したい**
A: カスタムフックではなく Context を使用。カスタムフックは呼び出しごとに独立した State を持つ。

**Q: いつ useMemo/useCallback を使うべきか？**
A: プロファイラで測定してから最適化。過度な最適化は逆効果。
