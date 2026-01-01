# State 管理 - 設計ガイド

複雑なアプリケーションにおけるState管理の設計判断とアーキテクチャパターン。

## State 構造設計の原則

### 冗長性の排除

```javascript
// ❌ fullName は冗長（firstName/lastNameから計算可能）
const [firstName, setFirstName] = useState('');
const [lastName, setLastName] = useState('');
const [fullName, setFullName] = useState('');

// ✅ レンダー時に計算
const fullName = firstName + ' ' + lastName;
```

**判断基準**: 既存のStateやPropsから計算できるならStateにしない。

### 矛盾の回避

```javascript
// ❌ isSending と isSent が同時に true になりうる
const [isSending, setIsSending] = useState(false);
const [isSent, setIsSent] = useState(false);

// ✅ 排他的な状態を1つの変数で表現
const [status, setStatus] = useState('typing'); // 'typing' | 'sending' | 'sent'
```

**Stateが矛盾する兆候**:
- 2つの真偽値Stateが同時にtrueにならない制約がある
- 1つを更新するとき、必ず他も更新する必要がある

### 重複の回避

```javascript
// ❌ items と selectedItem でデータが重複
const [items, setItems] = useState(initialItems);
const [selectedItem, setSelectedItem] = useState(items[0]);

// ✅ IDのみ保持、選択アイテムは計算で取得
const [items, setItems] = useState(initialItems);
const [selectedId, setSelectedId] = useState(0);
const selectedItem = items.find(item => item.id === selectedId);
```

**重複の問題**:
- `items`を更新しても`selectedItem`が古いまま
- 同期を保つロジックが必要になる

### 深いネストの回避

```javascript
// ❌ 深いネスト（更新が複雑）
{
  places: {
    0: {
      id: 0,
      name: '東京',
      places: {
        1: { id: 1, name: '渋谷' }
      }
    }
  }
}

// ✅ 正規化（フラット化）
{
  places: {
    0: { id: 0, name: '東京', childIds: [1] },
    1: { id: 1, name: '渋谷', parentId: 0 }
  }
}
```

**正規化の利点**:
- 更新が簡単
- 重複がない
- 参照が明確

## コンポーネント間での State 共有

### リフトアップの判断

**リフトアップすべき場合**:
- 2つ以上のコンポーネントが同じStateを参照
- 兄弟コンポーネント間で同期が必要
- 親が子のStateを制御したい

**リフトアップすべきでない場合**:
- 1つのコンポーネントのみが使用
- props drillingが5階層以上になる → Contextを検討

### 制御 vs 非制御の選択

**制御されたコンポーネント**:
- 親がStateを管理
- propsで動作を完全に制御
- 柔軟性は低いが、予測可能

**非制御コンポーネント**:
- 自身がStateを管理
- 親からの制御は限定的
- 柔軟だが、親から制御しにくい

```javascript
// 制御されたInput
function Input({ value, onChange }) {
  return <input value={value} onChange={onChange} />;
}

// 非制御Input
function Input({ defaultValue }) {
  const [value, setValue] = useState(defaultValue);
  return <input value={value} onChange={e => setValue(e.target.value)} />;
}
```

**選択基準**: 親からの制御が必要なら制御、ローカルで完結するなら非制御。

## State の保持とリセット

### ツリー内の位置による識別

Reactは「ツリー内の同じ位置」にあるコンポーネントのStateを保持する:

```javascript
// Counter は同じ位置にあるため State が保持される
{isFancy ? (
  <Counter isFancy={true} />
) : (
  <Counter isFancy={false} />
)}
```

### key でリセット

異なる`key`を指定すると、Reactは別のコンポーネントとして扱う:

```javascript
// key が変わると State がリセットされる
{isPlayerA ? (
  <Counter key="田中" person="田中" />
) : (
  <Counter key="佐藤" person="佐藤" />
)}
```

**key の活用例**:
- チャットの相手が変わったとき入力欄をリセット
- フォームの編集対象が変わったときフィールドをリセット
- ページ遷移時にコンポーネントを完全に再作成

### State 保持の選択肢

| 方法 | 用途 |
|---|---|
| ツリー内に残す | 常に表示する必要がある |
| CSS で非表示 | State を保持したいが表示は隠す |
| リフトアップ | 親で State を管理 |
| localStorage | ページリロード後も保持 |

## Reducer パターン

### useState vs useReducer

**useReducer が適している場合**:
- State更新ロジックが複雑
- 複数のイベントハンドラが同じStateを更新
- State更新をテストしたい
- State更新を別ファイルに分離したい

**useState が適している場合**:
- State更新が単純（単一値の設定）
- イベントハンドラが少ない
- コンポーネントが小さい

### Reducer 設計のベストプラクティス

**1. アクションは意図を表現**

```javascript
// ❌ 実装の詳細を記述
{ type: 'SET_NAME', name: '太郎' }
{ type: 'SET_AGE', age: 30 }

// ✅ ユーザーの意図を記述
{ type: 'USER_REGISTERED', user: { name: '太郎', age: 30 } }
```

**2. Reducer は純粋関数**

```javascript
// ❌ 副作用を含む
function reducer(state, action) {
  localStorage.setItem('state', JSON.stringify(state)); // NG
  return newState;
}

// ✅ 純粋（副作用なし）
function reducer(state, action) {
  switch (action.type) {
    case 'added':
      return [...state, action.item];
    default:
      return state;
  }
}
```

**3. 各アクションは単一のインタラクション**

複数フィールドを変更する場合でも、1つのアクションで:

```javascript
// ✅ フォーム送信を1つのアクションで
dispatch({
  type: 'FORM_SUBMITTED',
  firstName: 'Taro',
  lastName: 'Yamada',
  email: 'taro@example.com'
});
```

### Immer で Reducer を簡潔に

```javascript
import { useImmerReducer } from 'use-immer';

function reducer(draft, action) {
  switch (action.type) {
    case 'added':
      draft.push(action.item); // ミューテーション構文OK
      break;
    case 'changed':
      const item = draft.find(t => t.id === action.id);
      item.done = !item.done;
      break;
  }
}
```

## Context パターン

### Context を使うべきタイミング

**Context が適している場合**:
- 多数のコンポーネントが同じデータを必要とする
- props drillingが5階層以上
- グローバルな設定（テーマ、言語、認証など）

**Context を避けるべき場合**:
- 1〜2階層のprops渡し
- props で十分対応可能
- children で解決できる

### Context の代替: children パターン

```javascript
// ❌ Context を使う前に children を検討
function Page() {
  const user = useContext(UserContext);
  return <Layout user={user}><Content user={user} /></Layout>;
}

// ✅ children で解決
function Page() {
  const user = useContext(UserContext);
  return (
    <Layout>
      <Content user={user} />
    </Layout>
  );
}
```

Layout が `user` を必要としないなら、props として渡す必要はない。

### Context の分割

関連性の低いデータは別のContextに:

```javascript
// ❌ すべてを1つのContextに
const AppContext = createContext({
  theme: 'dark',
  user: {...},
  settings: {...}
});

// ✅ 関心事ごとに分割
const ThemeContext = createContext('dark');
const UserContext = createContext(null);
const SettingsContext = createContext({});
```

**利点**:
- 必要なContextのみ使用
- 更新時の不要な再レンダーを防ぐ
- テストしやすい

## Reducer + Context パターン

### 組み合わせの利点

- **Reducer**: 複雑なState更新ロジックを整理
- **Context**: 深い階層に State と dispatch を提供
- **組み合わせ**: スケーラブルなState管理

### 実装パターン

```javascript
// TasksContext.js
import { createContext, useContext, useReducer } from 'react';

const TasksContext = createContext(null);
const TasksDispatchContext = createContext(null);

export function TasksProvider({ children }) {
  const [tasks, dispatch] = useReducer(tasksReducer, []);

  return (
    <TasksContext.Provider value={tasks}>
      <TasksDispatchContext.Provider value={dispatch}>
        {children}
      </TasksDispatchContext.Provider>
    </TasksContext.Provider>
  );
}

// カスタムフックで使用を簡潔に
export function useTasks() {
  const context = useContext(TasksContext);
  if (context === undefined) {
    throw new Error('useTasks must be used within TasksProvider');
  }
  return context;
}

export function useTasksDispatch() {
  const context = useContext(TasksDispatchContext);
  if (context === undefined) {
    throw new Error('useTasksDispatch must be used within TasksProvider');
  }
  return context;
}

function tasksReducer(tasks, action) {
  // Reducer ロジック...
}
```

### カスタムフックの利点

- Context の使用を簡潔に
- エラーチェックを一箇所に
- 実装の詳細を隠蔽

## スケールアップの戦略

### 複数の Context-Reducer ペア

アプリケーションが成長したら、関心事ごとに分割:

```
src/
  contexts/
    ThemeContext.js       - theme + themeDispatch
    AuthContext.js        - user + authDispatch
    TasksContext.js       - tasks + tasksDispatch
    NotificationsContext.js
```

### ファイル構成

```javascript
// TasksContext.js
export function TasksProvider({ children }) { ... }
export function useTasks() { ... }
export function useTasksDispatch() { ... }

// tasksReducer.js（別ファイル）
export function tasksReducer(tasks, action) { ... }

// taskActions.js（オプション）
export const addTask = (text) => ({ type: 'added', text });
export const deleteTask = (id) => ({ type: 'deleted', id });
```

## よくあるアンチパターン

### 過度な Context 使用

```javascript
// ❌ すべてを Context に
<ThemeContext>
  <UserContext>
    <SettingsContext>
      <NotificationsContext>
        <TasksContext>
          <App />
        </TasksContext>
      </NotificationsContext>
    </SettingsContext>
  </UserContext>
</ThemeContext>

// ✅ 必要最小限の Context + props
<ThemeContext>
  <UserContext>
    <App /> {/* settings や tasks は props で渡す */}
  </UserContext>
</ThemeContext>
```

### Context と State の混同

Context は State 管理ツールではなく、依存性注入のメカニズム。
頻繁に更新される State には React Query、Zustand、Jotai などを検討。

## 設計チェックリスト

- [ ] 冗長な State がない（計算可能な値を State にしていない）
- [ ] State が矛盾しない構造になっている
- [ ] データの重複がない
- [ ] 深いネストを避けている（正規化を検討）
- [ ] Context は必要最小限（props や children で解決できないか確認）
- [ ] Reducer のアクションはユーザーの意図を表現している
- [ ] カスタムフックで Context の使用を簡潔にしている

## よくある質問

**Q: いつ Reducer を使うべきか？**
A: State更新が3箇所以上で発生、またはロジックが複雑な場合。

**Q: Context の更新で全コンポーネントが再レンダーされる**
A: State と dispatch を別の Context に分ける。または useMemo で最適化。

**Q: グローバル State 管理ライブラリは必要か？**
A: Context + Reducer で十分な場合が多い。頻繁な更新や複雑な非同期処理がある場合のみ検討。
