/// The `revealTurn` value that opens a chat with Find in Chat on a hit of the transcript index (the
/// command palette's chats page, for a content match past the bound of what it reads itself):
/// `find:<atMs>:<the query>`. Find opens with the query, and the hit nearest `atMs` is the current
/// one (chatFind.ts `reveal`), paged in when the chat has not loaded its turn. `atMs` may be empty:
/// Find then opens on the query as Cmd-F with it would.
export const FIND_REVEAL = "find:";

export type FindRevealValue = { query: string; atMs?: number };

/// The find a reveal names, or undefined for any other reveal.
export function revealedFind(value: string): FindRevealValue | undefined {
  if (!value.startsWith(FIND_REVEAL)) return undefined;
  const rest = value.slice(FIND_REVEAL.length);
  const colon = rest.indexOf(":");
  if (colon < 0) return undefined;
  const at = rest.slice(0, colon).trim();
  const query = rest.slice(colon + 1);
  if (!query.trim()) return undefined;
  if (at === "") return { query };
  const atMs = Number(at);
  return Number.isFinite(atMs) && /^\d+$/.test(at) ? { query, atMs } : undefined;
}
