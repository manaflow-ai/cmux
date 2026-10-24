import { expect, test } from "bun:test";
import { workflowFromWire } from "./workflow";

test("workflow adapter stays absent until a complete wire record arrives", () => {
  expect(workflowFromWire(undefined)).toBeUndefined();
  expect(workflowFromWire({ id: "w", title: "Workflow", state: "running" })).toBeUndefined();
  expect(workflowFromWire({ id: "w", title: "Workflow", state: "unknown" })).toBeUndefined();
});

test("workflow adapter keeps typed phases, agents and counters", () => {
  expect(
    workflowFromWire({
      id: "w",
      title: "Migration",
      state: "running",
      phase: "Implement",
      elapsedMs: 1200,
      tokens: 42,
      phases: [{ id: "p", name: "Implement", state: "running", agentIds: ["a"] }],
      agents: [{ id: "a", name: "API", state: "running", doing: "Editing", tokens: 42, transcriptRowId: "row" }],
    }),
  ).toEqual({
    id: "w",
    title: "Migration",
    state: "running",
    phase: "Implement",
    elapsedMs: 1200,
    tokens: 42,
    phases: [{ id: "p", name: "Implement", state: "running", agentIds: ["a"] }],
    agents: [{ id: "a", name: "API", state: "running", doing: "Editing", tokens: 42, transcriptRowId: "row" }],
  });
});
