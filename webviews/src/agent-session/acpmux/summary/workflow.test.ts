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
      phase: "p",
      elapsedMs: 1200,
      tokens: 42,
      phases: [{ id: "p", name: "Implement", state: "running", agentIds: ["a"] }],
      agents: [{ id: "a", name: "API", state: "running", doing: "Editing", tokens: 42, transcriptRowId: "row" }],
    }),
  ).toEqual({
    id: "w",
    title: "Migration",
    state: "running",
    phase: "p",
    elapsedMs: 1200,
    tokens: 42,
    phases: [{ id: "p", name: "Implement", state: "running", agentIds: ["a"] }],
    agents: [{ id: "a", name: "API", state: "running", doing: "Editing", tokens: 42, transcriptRowId: "row" }],
  });
});

test("workflow adapter rejects malformed children, references, duplicates and selections", () => {
  const base = {
    id: "w",
    title: "Migration",
    state: "running",
    phases: [{ id: "p", name: "Implement", state: "running", agentIds: ["a"] }],
    agents: [{ id: "a", name: "API", state: "running" }],
  };
  expect(workflowFromWire({ ...base, agents: [{ id: "a", name: "API", state: "bogus" }] })).toBeUndefined();
  expect(workflowFromWire({ ...base, agents: [...base.agents, base.agents[0]] })).toBeUndefined();
  expect(workflowFromWire({ ...base, phases: [{ ...base.phases[0], agentIds: ["missing"] }] })).toBeUndefined();
  expect(
    workflowFromWire({ ...base, phases: [{ id: "p", name: "Implement", state: "running", agentIds: [] }] }),
  ).toBeUndefined();
  expect(
    workflowFromWire({
      ...base,
      phases: [
        { id: "p", name: "Implement", state: "running", agentIds: ["a"] },
        { id: "p2", name: "Verify", state: "pending", agentIds: ["a"] },
      ],
    }),
  ).toBeUndefined();
  expect(workflowFromWire({ ...base, selectedAgentId: "missing" })).toBeUndefined();
  expect(workflowFromWire({ ...base, phase: "missing" })).toBeUndefined();
  expect(
    workflowFromWire({
      ...base,
      phase: "p",
      selectedAgentId: "b",
      agents: [base.agents[0], { id: "b", name: "UI", state: "running" }],
      phases: [base.phases[0], { id: "p2", name: "Verify", state: "pending", agentIds: ["b"] }],
    }),
  ).toBeUndefined();
  expect(workflowFromWire({ ...base, elapsedMs: 1.5 })).toBeUndefined();
  expect(workflowFromWire({ ...base, tokens: Number.MAX_SAFE_INTEGER + 1 })).toBeUndefined();
});
