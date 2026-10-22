// A turn's changes in an agent pane of their own, right of the chat (Leo 2026-10-21: "why's the diff
// viewer not opening up in the right split tab?"). A turn the folder's diff cannot show (a folder
// outside a repository, a file the turn wrote outside it, a chat on another machine) used to open
// over the chat in its own pane; it opens beside it instead. The app opens a tab on the chat's own
// session right of the chat (`chat.changesPane {row, path}`, AgentChangesPane.swift) on a
// `changes:` reveal, and that pane shows the turn's diff; closing the diff there closes the tab. A
// host that opens none (the gallery, Quick Chat, an older app) shows the diff in this pane, as before.

/// The `revealTurn` prefix that opens a pane on a turn's changes: `changes:<row>`, then a line
/// break and the file to show first, if any.
export const CHANGES_REVEAL = "changes:";

/// The turn (by row) and file a `changes:` reveal names, or undefined for any other reveal.
export function revealedChanges(value: string): { rowId: string; path?: string } | undefined {
  if (!value.startsWith(CHANGES_REVEAL)) return undefined;
  const rest = value.slice(CHANGES_REVEAL.length);
  const cut = rest.indexOf("\n");
  const rowId = cut < 0 ? rest : rest.slice(0, cut);
  const path = cut < 0 ? "" : rest.slice(cut + 1);
  if (!rowId) return undefined;
  return path ? { rowId, path } : { rowId };
}

type Call = (method: string, params: Record<string, unknown>) => Promise<unknown>;

/// Asks the app for a pane right of the chat on the changes of the turn holding `rowId`, at `path`;
/// false when it opened none.
export async function openChangesPane(call: Call, rowId: string, path?: string): Promise<boolean> {
  try {
    const reply = await call("chat.changesPane", path ? { row: rowId, path } : { row: rowId });
    return (reply as { opened?: unknown } | null)?.opened === true;
  } catch {
    return false;
  }
}
