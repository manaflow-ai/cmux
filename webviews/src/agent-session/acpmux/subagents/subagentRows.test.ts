import { describe, expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { turnView, WORKED } from "../conversation/turns";
import { SUBAGENTS, type Subagent } from "./subagentFold";
import { SUBAGENT_ROW, withSubagentRows } from "./subagentRows";

const agent = (id: string): Subagent => ({ id, parent: null, name: id, state: "running", startedAt: 2 });
const group: AcpmuxRow = {
  id: "subagents-3",
  version: 4,
  at: 3,
  kind: SUBAGENTS,
  subagents: [agent("a"), agent("b"), agent("c")],
};

describe("subagent rows", () => {
  test("a closed group draws one line", () => {
    const rows = withSubagentRows([group], new Set());
    expect(rows.map((row) => row.kind)).toEqual([SUBAGENTS]);
  });

  test("an open group lists each subagent on its own line, with the list's edges", () => {
    const rows = withSubagentRows([group], new Set([group.id]));
    expect(rows.map((row) => row.kind)).toEqual([SUBAGENTS, SUBAGENT_ROW, SUBAGENT_ROW, SUBAGENT_ROW]);
    expect(rows.slice(1).map((row) => row.status)).toEqual(["first", "middle", "last"]);
    expect(rows.slice(1).map((row) => row.subagents?.[0]?.id)).toEqual(["a", "b", "c"]);
  });

  test("opening a group changes its version, so its line redraws", () => {
    const closed = withSubagentRows([group], new Set())[0]!;
    const open = withSubagentRows([group], new Set([group.id]))[0]!;
    expect(open.version).not.toBe(closed.version);
  });

  test("an ended turn keeps its subagents in view, not folded under Worked for", () => {
    const rows: AcpmuxRow[] = [
      { id: "user-1", version: 1, at: 1, kind: "user", text: "go" },
      { id: "activity-2", version: 1, at: 2, kind: "activity", toolCount: 1, items: [] },
      group,
      { id: "assistant-5", version: 1, at: 5, kind: "assistant", text: "done" },
      { id: "summary-6", version: 1, at: 6, kind: "turnSummary", status: "completed" },
    ];
    const kinds = turnView(rows, new Set(), { now: 7 }).map((row) => row.kind);
    expect(kinds).toEqual(["user", WORKED, SUBAGENTS, "assistant", "turnSummary"]);
  });
});
