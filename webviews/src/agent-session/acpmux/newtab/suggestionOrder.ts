// Which order the New Tab field's rows take (screenModel.ts screenRows). Its own module: the
// host payload (NewTabPage.tsx) reads it without importing the screen's model.

/// How the rows under the field rank (Leo 2026-10-24: "Search the web. Do you really want that
/// first? Do you want that second?"). The field is a chat composer, so plain text asks the agent in
/// every order; they differ in what else shows. `intent`, the default: an address, a word that
/// completes one (`reddit.c`) or a tab or workspace named exactly what was typed goes first, Ask
/// right under it. `chat`: Ask first for everything, the address second. `minimal`: as `intent`,
/// with at most `MINIMAL_MATCH_ROWS` matches and no create rows while typing. The gallery keeps all
/// three (agent-pane.new-tab variants `suggestions-*`), and the host may pick one.
export type SuggestionOrder = "intent" | "chat" | "minimal";
export const SUGGESTION_ORDERS: readonly SuggestionOrder[] = ["intent", "chat", "minimal"];
export const DEFAULT_SUGGESTION_ORDER: SuggestionOrder = "intent";

/// The order the host names, or undefined for anything else.
export function suggestionOrder(value: unknown): SuggestionOrder | undefined {
  return SUGGESTION_ORDERS.find((order) => order === value);
}
