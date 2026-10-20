import type { AcpmuxRow } from "../model";
import { SUBAGENTS, type Subagent } from "./subagentFold";

/// A subagent's line in an open group (SubagentListRow in SubagentGroup.tsx).
export const SUBAGENT_ROW = "subagent";
/// The child view's "Subagent of" pill (SubagentOfRow in SubagentGroup.tsx).
export const SUBAGENT_OF = "subagentOf";

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
  expanded: ReadonlySet<string>,
  chat: string,
): AcpmuxRow[] | undefined {
  const agents = subagentsIn(rows, views);
  const agent = agents.get(id);
  if (!agent) return undefined;
  const parent = agent.parent === null ? chat : (agents.get(agent.parent)?.name ?? chat);
  const pill: AcpmuxRow = {
    id: `${id}:of`,
    version: 1,
    at: agent.startedAt,
    kind: SUBAGENT_OF,
    subagents: [agent],
    text: parent,
  };
  return [pill, ...withSubagentRows(views?.[id] ?? [], expanded)];
}

export const isSubagentGroup = (row: AcpmuxRow) => row.kind === SUBAGENTS;

/// ``withSubagentRows`` with what it was drawn from, for the next snapshot to build on.
export type SubagentRows = { source: readonly AcpmuxRow[]; grouped: boolean; rows: AcpmuxRow[] };

/// ``withSubagentRows``, building on `previous`: in a chat without subagent groups, only the rows
/// after the first that differs from `previous.source` (by object) can bring one.
export function subagentRowsFrom(
  rows: readonly AcpmuxRow[],
  expanded: ReadonlySet<string>,
  previous?: SubagentRows,
): SubagentRows {
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
export function withSubagentRows(rows: readonly AcpmuxRow[], expanded: ReadonlySet<string>): AcpmuxRow[] {
  if (!rows.some(isSubagentGroup)) return rows as AcpmuxRow[];
  const out: AcpmuxRow[] = [];
  for (const row of rows) {
    if (!isSubagentGroup(row)) {
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
