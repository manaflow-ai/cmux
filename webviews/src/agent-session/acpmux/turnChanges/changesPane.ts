// A turn's changes in an agent pane of their own, right of the chat (Leo 2026-10-21: "why's the diff
// viewer not opening up in the right split tab?"). A turn the folder's diff cannot show (a folder
// outside a repository, a file the turn wrote outside it) used to open over the chat in its own
// pane; it opens beside it instead. A chat on another machine still shows it in place: the app opens
// no second tab on another machine's session. The app opens a tab on the chat's own
// session right of the chat (`chat.changesPane {session, row, tool, path}`, AgentChangesPane.swift) on a
// `changes:` reveal, and that pane shows the turn's diff; closing the diff there closes the tab. A
// host that opens none (the gallery, Quick Chat, an older app) shows the diff in this pane, as before.

import type { AcpmuxRow } from "../model";

/// The `revealTurn` prefix that opens a pane on a turn's changes: `changes:<session>`, then on lines
/// of their own the row, a tool call of that row (or nothing) and the file to show first (or
/// nothing). Row ids repeat across sessions, so the request names its chat and applies to no other;
/// an activity row's id comes from its first event the pane holds, so it changes as older history
/// pages in, and the tool call, which keeps its id, finds the row again (`requestedRow`).
export const CHANGES_REVEAL = "changes:";

export type ChangesRequest = { sessionId: string; rowId: string; toolId?: string; path?: string };

/// The chat, turn (by row and tool call) and file a `changes:` reveal names, or undefined for any
/// other reveal.
export function revealedChanges(value: string): ChangesRequest | undefined {
  if (!value.startsWith(CHANGES_REVEAL)) return undefined;
  const [sessionId, rowId, toolId, ...rest] = value.slice(CHANGES_REVEAL.length).split("\n");
  const path = rest.join("\n");
  if (!sessionId || !rowId) return undefined;
  return { sessionId, rowId, ...(toolId ? { toolId } : {}), ...(path ? { path } : {}) };
}

const toolIds = (row: AcpmuxRow | undefined) =>
  row?.kind === "activity" ? (row.items ?? []).flatMap((item) => (item.tool ? [item.tool.id] : [])) : [];

/// A tool call of row `rowId` in `rows`, which names that row however its id changes; undefined
/// for a row with none.
export function rowTool(rows: readonly AcpmuxRow[], rowId: string): string | undefined {
  return toolIds(rows.find((row) => row.id === rowId))[0];
}

/// The id the row a request names has in `rows` now: the row holding its tool call, else (a row
/// with no tool call) the row with its id. Undefined while `rows` hold neither.
export function requestedRow(rows: readonly AcpmuxRow[], request: ChangesRequest): string | undefined {
  const { rowId, toolId } = request;
  if (!toolId) return rows.some((row) => row.id === rowId) ? rowId : undefined;
  return rows.find((row) => toolIds(row).includes(toolId))?.id;
}

type Call = (method: string, params: Record<string, unknown>) => Promise<unknown>;

/// Asks the app for a pane right of the chat `sessionId` on the changes of its turn holding `rowId`
/// (whose tool call `toolId` finds it again), at `path`; false when it opened none (the app refuses
/// a pane that shows another chat by now).
export async function openChangesPane(
  call: Call,
  sessionId: string,
  rowId: string,
  toolId: string | undefined,
  path?: string,
): Promise<boolean> {
  try {
    const params = { session: sessionId, row: rowId, ...(toolId ? { tool: toolId } : {}), ...(path ? { path } : {}) };
    const reply = await call("chat.changesPane", params);
    return (reply as { opened?: unknown } | null)?.opened === true;
  } catch {
    return false;
  }
}
