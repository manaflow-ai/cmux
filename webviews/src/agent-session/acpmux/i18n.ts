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
  "composer.sendTooltip": "Send (Return)",
  "picker.recent": "Recent",
  "picker.more": "More…",
  "picker.moreModels": "More models",
  "picker.allModels": "All models",
  "picker.reasoning": "Reasoning",
  "picker.harness": "Harness",
  "picker.provider": "Provider",
  "picker.family": "Family",
  "picker.newChat": "New chat",
  "picker.search": "Type to search models",
  "picker.noMatches": "No matching models",
  "picker.back": "Back",
  "trust.ask": "{agent} can edit and run code in {folder}",
  "trust.trust": "Trust",
  "trust.distrust": "Don't trust",
  "trust.trusted": "Trusted {folder}",
  "trust.untrusted": "Won't trust {folder}",
  "trust.undo": "Undo",
  "trust.failed": "Couldn't save that. Try again.",
  "trust.agent": "The agent",
  "files.search": "Search files",
  "files.hint": "Type to search for files",
  "files.searching": "Searching…",
  "files.none": "No matching files",
  "files.failed": "Couldn't search files",
  "files.outside": "This folder isn't in a git repository",
  "files.more": "Showing the first {count}; type more to narrow it",
  "project.label": "Project",
  "project.choose": "Choose project",
  "project.search": "Search projects",
  "project.none": "No matching projects",
  "permission.required": "Permission required",
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
  "composer.sendTooltip": "送信 (Return)",
  "picker.recent": "最近使ったモデル",
  "picker.more": "その他…",
  "picker.moreModels": "その他のモデル",
  "picker.allModels": "すべてのモデル",
  "picker.reasoning": "推論",
  "picker.harness": "ハーネス",
  "picker.provider": "プロバイダ",
  "picker.family": "ファミリー",
  "picker.newChat": "新しいチャット",
  "picker.search": "入力してモデルを検索",
  "picker.noMatches": "一致するモデルはありません",
  "picker.back": "戻る",
  "trust.ask": "{agent} は {folder} でコードを編集・実行できます",
  "trust.trust": "信頼する",
  "trust.distrust": "信頼しない",
  "trust.trusted": "{folder} を信頼しました",
  "trust.untrusted": "{folder} を信頼しないことにしました",
  "trust.undo": "元に戻す",
  "trust.failed": "保存できませんでした。もう一度お試しください。",
  "trust.agent": "エージェント",
  "files.search": "ファイルを検索",
  "files.hint": "入力してファイルを検索",
  "files.searching": "検索中…",
  "files.none": "一致するファイルはありません",
  "files.failed": "ファイルを検索できませんでした",
  "files.outside": "このフォルダは git リポジトリにありません",
  "files.more": "最初の {count} 件を表示しています。絞り込むには続けて入力してください",
  "project.label": "プロジェクト",
  "project.choose": "プロジェクトを選択",
  "project.search": "プロジェクトを検索",
  "project.none": "一致するプロジェクトはありません",
  "permission.required": "許可が必要です",
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
