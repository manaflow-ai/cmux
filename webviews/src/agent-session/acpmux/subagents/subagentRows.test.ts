import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { childView } from "./subagentRows";
import { SUBAGENTS, type Subagent } from "./subagentFold";

const agent = (fields: Partial<Subagent> = {}): Subagent => ({
  id: "worker",
  parent: null,
  name: "Review worker",
  state: "completed",
  startedAt: 1_000,
  endedAt: 2_000,
  result: "The result is ready.",
  ...fields,
});

const parentRows = (worker: Subagent): AcpmuxRow[] => [
  { id: "group", version: 1, at: 1_000, kind: SUBAGENTS, subagents: [worker] },
];

test("a completed child with only a folded result keeps transcript empty for the result head", () => {
  const rows = childView("worker", parentRows(agent()), {}, new Set(), "Main chat");
  expect(rows?.map((row) => row.kind)).toEqual(["subagentOf", "subagentEmpty"]);
});

test("a running child keeps its live view without synthesizing a result", () => {
  const running = agent({ state: "running", endedAt: undefined });
  const rows = childView("worker", parentRows(running), {}, new Set(), "Main chat");
  expect(rows?.map((row) => row.kind)).toEqual(["subagentOf", "subagentEmpty"]);
});
