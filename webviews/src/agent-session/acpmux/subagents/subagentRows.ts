import type { AcpmuxRow } from "../model";
import { SUBAGENTS } from "./subagentFold";

/// A subagent's line in an open group (SubagentListRow in SubagentGroup.tsx).
export const SUBAGENT_ROW = "subagent";

export const isSubagentGroup = (row: AcpmuxRow) => row.kind === SUBAGENTS;

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
