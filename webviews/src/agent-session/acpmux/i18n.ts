// Pane strings in English and Japanese. The page has no string catalog from the host yet,
// so it picks the language WebKit reports for the app (`navigator.languages`, which follows
// the app's preferred localizations), falling back to English. Keys are the English text's
// role; values keep product names (cmux) and placeholders ({n}) intact.
const en = {
  "search.title": "Search chats",
  "search.placeholder": "Search chats",
  "search.chats": "Chats",
  "search.quick": "Quick actions",
  "search.newChat": "New chat",
  "search.none": "No results",
  "search.close": "Close search",
  "turn.previous.one": "1 previous message",
  "turn.previous.other": "{n} previous messages",
  "turn.worked": "Worked for {time}",
  "turn.stopped": "You stopped after {time}",
  "approval.title": "How should the agent's actions be approved?",
  "effort.title": "Effort",
  "host.retry": "Retry",
  "host.retryQueued": "Retrying…",
  "host.retrying": "cmux tries again on its own. Your prompt stays here until acpmux connects.",
  "project.label": "Project",
  "project.choose": "Choose project",
  "project.search": "Search projects",
  "project.none": "No matching projects",
} as const;

export type StringKey = keyof typeof en;

const ja: Record<StringKey, string> = {
  "search.title": "チャットを検索",
  "search.placeholder": "チャットを検索",
  "search.chats": "チャット",
  "search.quick": "クイックアクション",
  "search.newChat": "新しいチャット",
  "search.none": "結果なし",
  "search.close": "検索を閉じる",
  "turn.previous.one": "以前のメッセージ 1 件",
  "turn.previous.other": "以前のメッセージ {n} 件",
  "turn.worked": "{time} 作業しました",
  "turn.stopped": "{time} 後に停止しました",
  "approval.title": "エージェントの操作をどのように承認しますか？",
  "effort.title": "推論の強さ",
  "host.retry": "再試行",
  "host.retryQueued": "再試行中…",
  "host.retrying": "cmux は自動で再試行します。acpmux に接続するまで、プロンプトはここに残ります。",
  "project.label": "プロジェクト",
  "project.choose": "プロジェクトを選択",
  "project.search": "プロジェクトを検索",
  "project.none": "一致するプロジェクトはありません",
};

const tables: Record<string, Record<StringKey, string>> = { en, ja };

/** The pane's language: the first of the app's languages the pane has strings for. */
export function paneLanguage(languages: readonly string[] = globalThis.navigator?.languages ?? []): "en" | "ja" {
  for (const language of languages) {
    const base = language.toLowerCase().split("-")[0];
    if (base === "ja") return "ja";
    if (base === "en") return "en";
  }
  return "en";
}

/** A pane string, with `{name}` placeholders filled. */
export function t(key: StringKey, values: Record<string, string | number> = {}, language = paneLanguage()): string {
  const text = tables[language]?.[key] ?? en[key];
  return text.replace(/\{(\w+)\}/g, (whole, name: string) => (name in values ? String(values[name]) : whole));
}

/** Every key of every language, for tests that keep the tables complete. */
export const STRING_TABLES = tables;
