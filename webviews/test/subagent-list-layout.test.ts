// l10n-allow-file: nested subagent geometry fixtures.
import { expect, test } from "bun:test";
import { layoutConversation, type AcpmuxRow } from "../src/agent-session/acpmux/model";
import { SUBAGENTS, type Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";
import { withSubagentRows, SUBAGENT_ROW } from "../src/agent-session/acpmux/subagents/subagentRows";

const agents: Subagent[] = [
  { id: "unit", parent: "coverage", name: "Unit tests", state: "completed", startedAt: 0, endedAt: 1000 },
  { id: "integration", parent: "coverage", name: "Integration tests", state: "running", startedAt: 0 },
];
const group: AcpmuxRow = { id: "coverage-children", version: 1, at: 0, kind: SUBAGENTS, subagents: agents };

test("an expanded child-agent list has no empty transcript gaps inside it", () => {
  const rows = withSubagentRows([group], new Set([group.id]));
  const layout = layoutConversation(rows, 760);
  expect(rows.filter((row) => row.kind === SUBAGENT_ROW)).toHaveLength(2);
  expect(layout.tops[1]).toBe(layout.tops[0]! + layout.heights[0]!);
  expect(layout.tops[2]).toBe(layout.tops[1]! + layout.heights[1]!);
});

test("closing the group removes its children while preserving room around the group", () => {
  const answer: AcpmuxRow = { id: "answer", version: 1, at: 1, kind: "assistant", text: "The test run is ready." };
  const rows = withSubagentRows([group, answer], new Set());
  expect(rows.some((row) => row.kind === SUBAGENT_ROW)).toBe(false);
  const layout = layoutConversation(rows, 760);
  expect(layout.tops[1]).toBeGreaterThan(layout.heights[0]!);
});
