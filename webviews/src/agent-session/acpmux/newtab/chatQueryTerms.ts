// The All chats search's operators as the field holds them (ask-b75ea23533, Leo 2026-11-18:
// "recency is usually what's desired"). acpmux reads them (cmux-tui chats/terms.rs: `since:7d`,
// `before:`, `harness:`, `in:`, `title:`, `-word`, `"a phrase"`); the When menu writes its
// `since:` into the field, so what the menu chose is what the search says.

export type ChatRecency = "any" | "day" | "week" | "month";
export const RECENCIES = ["any", "day", "week", "month"] as const satisfies readonly ChatRecency[];

const SINCE: Record<Exclude<ChatRecency, "any">, string> = { day: "since:1d", week: "since:7d", month: "since:30d" };

/// A `since:` or `after:` piece of the query (the menu's own or one typed).
const SINCE_TOKEN = /^(?:since|after):\S+$/i;
/// A piece acpmux reads as an operator, not a word: `key:value` for its keys, or `-word`.
const OPERATOR = /^(?:(?:since|after|before|until|harness|agent|in|folder|path|title):\S+|-[^-\s]\S*)$/i;

/// The menu choice the query's `since:` names; "any" with none, and with a `since:` the menu does
/// not offer (the menu then shows no choice of its own: see `customRecency`).
export function recencyOf(query: string): ChatRecency {
  const since = query.split(/\s+/).find((piece) => SINCE_TOKEN.test(piece));
  if (!since) return "any";
  const found = (Object.keys(SINCE) as Exclude<ChatRecency, "any">[]).find((key) => SINCE[key] === since.toLowerCase());
  return found ?? "any";
}

/// Whether the query has a `since:` the menu does not offer (typed by hand).
export function customRecency(query: string): boolean {
  return query.split(/\s+/).some((piece) => SINCE_TOKEN.test(piece)) && recencyOf(query) === "any";
}

/// `query` with its `since:` set to `recency`'s (or taken out for "any"), at the end.
export function withRecency(query: string, recency: ChatRecency): string {
  const rest = query
    .split(/\s+/)
    .filter((piece) => piece && !SINCE_TOKEN.test(piece))
    .join(" ");
  if (recency === "any") return rest;
  return rest ? `${rest} ${SINCE[recency]}` : SINCE[recency];
}

/// The query's plain words, operators taken out: what a live chat's title is matched with here.
export function plainWords(query: string): string {
  return query
    .split(/\s+/)
    .filter((piece) => piece && !OPERATOR.test(piece))
    .join(" ")
    .replaceAll('"', "")
    .toLowerCase();
}
