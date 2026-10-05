// The new tab screen's strings in English and Japanese, in the pane's language
// (`usePaneLanguage`, which follows the app's preferred localizations). Components read them
// through `useNt()` so a language change re-renders them; `translateNewTab` is for code
// outside render.
import { currentLanguage, type PaneLanguage, usePaneLanguage } from "../i18n";

const en = {
  placeholder: "Search or type a URL",
  suggestions: "Suggestions",
  "row.search": "Search the web",
  "row.open": "Open",
  "row.ask": "Ask {agent}",
  "row.tab": "Switch to tab",
  "row.workspace": "Switch to workspace",
  "row.history": "Open",
  terminal: "Opening a terminal…",
  sections: "Chats and routines",
  chats: "Chats",
  allChats: "All Chats",
  noChats: "Chats you start show up here.",
  "card.input": "Needs input",
  "card.running": "Running",
  "card.error": "Disconnected",
  "card.unread": "Unread",
  "card.open": "Open {title}",
} as const;

export type NewTabStringKey = keyof typeof en;

const ja: Record<NewTabStringKey, string> = {
  placeholder: "検索またはURLを入力",
  suggestions: "候補",
  "row.search": "ウェブを検索",
  "row.open": "開く",
  "row.ask": "{agent}に質問",
  "row.tab": "タブに切り替え",
  "row.workspace": "ワークスペースに切り替え",
  "row.history": "開く",
  terminal: "ターミナルを開いています…",
  sections: "チャットとルーティン",
  chats: "チャット",
  allChats: "すべてのチャット",
  noChats: "開始したチャットがここに表示されます。",
  "card.input": "入力待ち",
  "card.running": "実行中",
  "card.error": "切断されました",
  "card.unread": "未読",
  "card.open": "{title}を開く",
};

export const NEW_TAB_STRING_TABLES: Record<"en" | "ja", Record<NewTabStringKey, string>> = { en, ja };

export type NewTabTranslate = (key: NewTabStringKey, values?: Record<string, string>) => string;

/** A new tab string, with `{name}` placeholders filled. Outside render only; components use `useNt()`. */
export function translateNewTab(
  key: NewTabStringKey,
  values: Record<string, string> = {},
  lang: PaneLanguage = currentLanguage(),
): string {
  const text = NEW_TAB_STRING_TABLES[lang][key] ?? en[key];
  return text.replace(/\{(\w+)\}/g, (whole, name: string) => values[name] ?? whole);
}

const translators: Record<PaneLanguage, NewTabTranslate> = {
  en: (key, values) => translateNewTab(key, values, "en"),
  ja: (key, values) => translateNewTab(key, values, "ja"),
};

/** The new tab translator for the pane's current language; re-renders the caller when it changes. */
export function useNt(): NewTabTranslate {
  return translators[usePaneLanguage()];
}
