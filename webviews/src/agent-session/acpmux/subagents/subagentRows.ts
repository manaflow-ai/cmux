import type { Folds } from "../conversation/viewFolds";
import type { AcpmuxRow } from "../model";
import { continuesTurn } from "../turnStart";
import { SUBAGENTS, type Subagent } from "./subagentFold";

/// A subagent's line in an open group (SubagentListRow in SubagentGroup.tsx).
export const SUBAGENT_ROW = "subagent";
/// The child view's "Subagent of" pill (SubagentOfRow in SubagentGroup.tsx).
export const SUBAGENT_OF = "subagentOf";
/// The known child has no recorded messages or tool calls yet.
export const SUBAGENT_EMPTY = "subagentEmpty";
/// A subagent's one line where it ended, while running ones sit in the tray (SubagentDoneLine.tsx,
/// runningTray.ts).
export const SUBAGENT_DONE = "subagentDone";
/// A Claude workflow's card where it started (Labs `workflowLabs`, summary/WorkflowCard.tsx;
/// runningTray.ts `withSubagentLines`): a row per workflow a group started, in the group's place.
export const WORKFLOW_CARD = "workflowCard";

/// Every subagent the rows list, nested views' included.
export function subagentsIn(
  rows: readonly AcpmuxRow[],
  views: Record<string, AcpmuxRow[]> = {},
): Map<string, Subagent> {
  const found = new Map<string, Subagent>();
  // Reads the rows in place: the chat calls this on every snapshot, and copying every row (and
  // every subagent view's rows) into one array first cost a whole-transcript allocation each time.
  const scan = (list: readonly AcpmuxRow[]) => {
    for (const row of list)
      if (row.kind === SUBAGENTS) for (const agent of row.subagents ?? []) found.set(agent.id, agent);
  };
  scan(rows);
  for (const view of Object.values(views)) scan(view);
  return found;
}

/// Subagent `id`'s own view: the "Subagent of" pill naming its parent (a subagent, or the chat,
/// `chat`), then its rows with its open groups listed. Undefined when the subagent is unknown.
export function childView(
  id: string,
  rows: readonly AcpmuxRow[],
  views: Record<string, AcpmuxRow[]> | undefined,
  expanded: Folds,
  chat: string,
): AcpmuxRow[] | undefined {
  const agents = subagentsIn(rows, views);
  const agent = agents.get(id);
  if (!agent) return undefined;
  const parent = agent.parent === null ? chat : agents.get(agent.parent)?.name || chat;
  const pill: AcpmuxRow = {
    id: `${id}:of`,
    version: 1,
    at: agent.startedAt,
    kind: SUBAGENT_OF,
    subagents: [agent],
    text: parent,
  };
  const content = withSubagentRows(views?.[id] ?? [], expanded);
  // Views are populated by recorded child events, not a separate fetch. An absent entry does
  // not mean a request is pending; describe the empty transcript without claiming it is loading.
  return content.length
    ? [pill, ...content]
    : [pill, { id: `${id}:empty`, version: 1, at: agent.startedAt, kind: SUBAGENT_EMPTY }];
}

export const isSubagentGroup = (row: AcpmuxRow) => row.kind === SUBAGENTS;

/// A group that is one agent a shell call started (subagentFold.ts `reduceRun`): its card
/// (AgentRunCard.tsx) stays where it started, in the tray's layout too, and never opens to a list.
export const isRunGroup = (row: AcpmuxRow) =>
  row.kind === SUBAGENTS && row.subagents?.length === 1 && row.subagents[0]!.command !== undefined;

/// The latest turn's groups, nested views' included, with an agent still running: in a working
/// turn they start open (App.tsx), after Codex and Claude Code. An earlier turn's group stays as
/// it was, its agent still running in the background.
export function runningGroups(rows: readonly AcpmuxRow[], views: Record<string, AcpmuxRow[]> = {}): string[] {
  // The turn starts after its prompt; a prompt still waiting to send starts none, nor does a steer.
  let start = rows.length;
  while (
    start > 0 &&
    (rows[start - 1]!.kind !== "user" ||
      rows[start - 1]!.pending ||
      rows[start - 1]!.failed ||
      continuesTurn(rows[start - 1]!))
  )
    start -= 1;
  const found: string[] = [];
  for (const list of [rows.slice(start), ...Object.values(views)])
    for (const row of list)
      if (row.kind === SUBAGENTS && row.subagents?.some((agent) => agent.state === "running")) found.push(row.id);
  return found;
}

/// ``withSubagentRows`` with what it was drawn from, for the next snapshot to build on.
export type SubagentRows = { source: readonly AcpmuxRow[]; grouped: boolean; rows: AcpmuxRow[] };

/// ``withSubagentRows``, building on `previous`: in a chat without subagent groups, only the rows
/// after the first that differs from `previous.source` (by object) can bring one.
export function subagentRowsFrom(rows: readonly AcpmuxRow[], expanded: Folds, previous?: SubagentRows): SubagentRows {
  if (previous && !previous.grouped) {
    const shared = previous.source;
    let from = 0;
    while (from < rows.length && from < shared.length && rows[from] === shared[from]) from += 1;
    let grouped = false;
    for (let index = from; index < rows.length && !grouped; index += 1) grouped = isSubagentGroup(rows[index]!);
    if (!grouped) return { source: rows, grouped, rows: rows as AcpmuxRow[] };
  }
  const out = withSubagentRows(rows, expanded);
  return { source: rows, grouped: out !== rows, rows: out };
}

/// An open group's subagents as rows below it, one line each, so every line keeps a fixed
/// height. Each carries its place in the list (`status`: only, first, middle or last) for the
/// list's border. A group's version records whether it is open.
export function withSubagentRows(rows: readonly AcpmuxRow[], expanded: Folds): AcpmuxRow[] {
  if (!rows.some(isSubagentGroup)) return rows as AcpmuxRow[];
  const out: AcpmuxRow[] = [];
  for (const row of rows) {
    if (!isSubagentGroup(row) || isRunGroup(row)) {
      out.push(row);
      continue;
    }
    const open = expanded.has(row.id);
    out.push({ ...row, version: row.version * 2 + (open ? 1 : 0) });
    if (!open) continue;
    const agents = row.subagents ?? [];
    agents.forEach((agent, index) => {
      const edge =
        agents.length === 1 ? "only" : index === 0 ? "first" : index === agents.length - 1 ? "last" : "middle";
      out.push({
        id: `${row.id}:${agent.id}`,
        version: row.version,
        at: row.at,
        kind: SUBAGENT_ROW,
        subagents: [agent],
        status: edge,
      });
    });
  }
  return out;
}
