// The new tab screen's strings in English and Japanese, in the pane's language
// (`paneLanguage`, which follows the app's preferred localizations).
import { paneLanguage } from "../i18n";

const en = {
  placeholder: "Search or type a URL",
  tabHint: "Tab to switch",
  modeLabel: "Search or ask",
  "mode.search": "Search",
  "mode.ask": "Ask",
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
  tabHint: "Tabで切り替え",
  modeLabel: "検索または質問",
  "mode.search": "検索",
  "mode.ask": "質問",
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

export function nt(key: NewTabStringKey, values: Record<string, string> = {}, language = paneLanguage()): string {
  const text = NEW_TAB_STRING_TABLES[language][key] ?? en[key];
  return text.replace(/\{(\w+)\}/g, (whole, name: string) => values[name] ?? whole);
}
