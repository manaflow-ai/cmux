// A turn's changes in an agent pane of their own, right of the chat (Leo 2026-10-21: "why's the diff
// viewer not opening up in the right split tab?"). A turn the folder's diff cannot show (a folder
// outside a repository, a file the turn wrote outside it) used to open over the chat in its own
// pane; it opens beside it instead. A chat on another machine still shows it in place: the app opens
// no second tab on another machine's session. The app opens a tab on the chat's own
// session right of the chat (`chat.changesPane {row, path}`, AgentChangesPane.swift) on a
// `changes:` reveal, and that pane shows the turn's diff; closing the diff there closes the tab. A
// host that opens none (the gallery, Quick Chat, an older app) shows the diff in this pane, as before.

/// The `revealTurn` prefix that opens a pane on a turn's changes: `changes:<session>`, a line
/// break, the row, then a line break and the file to show first, if any. Row ids repeat across
/// sessions, so the request names its chat and applies to no other.
export const CHANGES_REVEAL = "changes:";

export type ChangesRequest = { sessionId: string; rowId: string; path?: string };

/// The chat, turn (by row) and file a `changes:` reveal names, or undefined for any other reveal.
export function revealedChanges(value: string): ChangesRequest | undefined {
  if (!value.startsWith(CHANGES_REVEAL)) return undefined;
  const [sessionId, rowId, ...rest] = value.slice(CHANGES_REVEAL.length).split("\n");
  const path = rest.join("\n");
  if (!sessionId || !rowId) return undefined;
  return path ? { sessionId, rowId, path } : { sessionId, rowId };
}

type Call = (method: string, params: Record<string, unknown>) => Promise<unknown>;

/// Asks the app for a pane right of the chat `sessionId` on the changes of its turn holding `rowId`,
/// at `path`; false when it opened none (the app refuses a pane that shows another chat by now).
export async function openChangesPane(call: Call, sessionId: string, rowId: string, path?: string): Promise<boolean> {
  try {
    const params = { session: sessionId, row: rowId, ...(path ? { path } : {}) };
    const reply = await call("chat.changesPane", params);
    return (reply as { opened?: unknown } | null)?.opened === true;
  } catch {
    return false;
  }
}
