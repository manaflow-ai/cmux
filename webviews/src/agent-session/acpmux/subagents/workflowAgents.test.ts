import { expect, test } from "bun:test";
import { SubagentFold } from "./subagentFold";
import { mergeWorkflowAgents, workflowPhases } from "./workflowAgents";

// session/update records as acpmux sends a Claude workflow's (claude_stdio/workflows.rs).
let seq = 0;
function feed(fold: SubagentFold, update: any, acpmux: Record<string, unknown> = {}) {
  seq += 1;
  const msg = { method: "session/update", params: { update, _meta: { acpmux } } };
  return fold.reduce({ seq, at: seq * 1000, msg }, update);
}
const progress = (fields: Record<string, unknown>) =>
  [
    { sessionUpdate: "subagent_progress" },
    { subagents: [{ id: "w", parent: null, state: "running", ...fields }] },
  ] as const;

test("each update's agent changes merge by index; null removes a field; a new map each time", () => {
  const first = mergeWorkflowAgents(undefined, [
    { index: 1, label: "review:#1", state: "running", tokens: 1200, action: "gh pr view 1" },
    { index: 2, label: "review:#2", state: "queued", queuedAt: 1000 },
  ]);
  const second = mergeWorkflowAgents(first, [
    { index: 1, state: "completed", tokens: 1500, action: null, result: "SHIP" },
    { index: 2, state: "running", startedAt: 5100, tokens: "lots" },
  ]);
  expect(second).not.toBe(first);
  expect(first!.get(1)!.state).toBe("running");
  expect(second!.get(1)).toEqual({ index: 1, label: "review:#1", state: "completed", tokens: 1500, result: "SHIP" });
  // A field of the wrong type is ignored, never taken.
  expect(second!.get(2)).toEqual({ index: 2, label: "review:#2", state: "running", queuedAt: 1000, startedAt: 5100 });
  // An update with no agents keeps the map as it was.
  expect(mergeWorkflowAgents(second, undefined)).toBe(second);
});

test("agents restored from a cached snapshot's JSON (a map turned `{}`) count as none", () => {
  const restored = JSON.parse(JSON.stringify({ agents: mergeWorkflowAgents(undefined, [{ index: 1, label: "a" }]) }));
  const merged = mergeWorkflowAgents(restored.agents, [{ index: 2, label: "b" }]);
  expect([...merged!.values()]).toEqual([{ index: 2, label: "b" }]);
});

test("a full update replaces the agents", () => {
  const before = mergeWorkflowAgents(undefined, [
    { index: 1, label: "a", tokens: 9 },
    { index: 2, label: "b" },
  ]);
  const after = mergeWorkflowAgents(before, [{ index: 1, label: "a", state: "completed" }], true);
  expect([...after!.values()]).toEqual([{ index: 1, label: "a", state: "completed" }]);
});

test("phases read in order; ones without an index or title are left out", () => {
  expect(workflowPhases([{ index: 2, title: "Land" }, { index: 1, title: "Review" }, { title: "x" }])).toEqual([
    { index: 1, title: "Review" },
    { index: 2, title: "Land" },
  ]);
  expect(workflowPhases(undefined)).toBeUndefined();
});

test("the fold keeps a workflow's run, phases, agents and counts, and its pause", () => {
  const fold = new SubagentFold();
  feed(
    fold,
    { sessionUpdate: "subagent_spawned" },
    { subagents: [{ id: "w", parent: null, name: "Workflow", kind: "workflow", state: "running" }] },
  );
  feed(
    fold,
    ...progress({
      runId: "wf_4fe",
      scriptPath: "/s/workflows/scripts/probe-wf_4fe.js",
      args: { pr: 24789 },
      phases: [{ index: 1, title: "Review" }],
      workflowAgents: [{ index: 1, label: "review:#1", state: "running", phase: "Review" }],
      agents: { done: 0, started: 1, queued: 2 },
    }),
  );
  feed(
    fold,
    ...progress({
      workflowAgents: [{ index: 1, state: "failed", error: "503" }],
      agents: { done: 0, started: 1, failed: 1 },
    }),
  );
  const agent = fold.all().find((each) => each.id === "w")!;
  expect(agent.runId).toBe("wf_4fe");
  expect([agent.scriptPath, agent.args]).toEqual(["/s/workflows/scripts/probe-wf_4fe.js", { pr: 24789 }]);
  expect(agent.phases).toEqual([{ index: 1, title: "Review" }]);
  expect(agent.workflowAgents?.get(1)).toEqual({
    index: 1,
    label: "review:#1",
    state: "failed",
    phase: "Review",
    error: "503",
  });
  expect(agent.agents).toEqual({ done: 0, started: 1, failed: 1 });
  feed(
    fold,
    { sessionUpdate: "subagent_state_update" },
    { subagents: [{ id: "w", state: "cancelled", reason: "paused" }] },
  );
  const paused = fold.all().find((each) => each.id === "w")!;
  expect([paused.state, paused.paused]).toEqual(["cancelled", true]);
});

test("a pane that read only the run's end still has every agent", () => {
  const fold = new SubagentFold();
  feed(
    fold,
    ...progress({
      workflowAgentsFull: true,
      phases: [{ index: 1, title: "Review" }],
      workflowAgents: [
        { index: 1, label: "review:#1", state: "completed" },
        { index: 2, label: "review:#2", state: "skipped" },
      ],
    }),
  );
  const agent = fold.all().find((each) => each.id === "w")!;
  expect([...agent.workflowAgents!.values()].map((each) => [each.label, each.state])).toEqual([
    ["review:#1", "completed"],
    ["review:#2", "skipped"],
  ]);
});
