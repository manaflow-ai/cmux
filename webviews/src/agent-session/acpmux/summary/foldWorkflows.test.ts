import { expect, test } from "bun:test";
import type { Subagent } from "../subagents/subagentFold";
import { createWorkflowAdapter, workflowDetailRequest, workflowDraft, workflowSignals } from "./foldWorkflows";

const node = (id: string, fields: Partial<Subagent> = {}): Subagent => ({
  id,
  parent: null,
  name: "Review",
  kind: "workflow",
  state: "running",
  startedAt: 1000,
  runId: "wf_same",
  phases: [{ index: 0, title: "Plan" }],
  agents: { done: 0, started: 1 },
  workflowAgents: new Map([[0, { index: 0, agentId: "plain-agent", state: "running", phaseIndex: 0 }]]),
  ...fields,
});

test("same run id and index on resumed nodes keep distinct row and agent identities", () => {
  const adapt = createWorkflowAdapter();
  const summaries = adapt([node("task-one"), node("task-two")], "session-plain");
  expect(summaries.map((workflow) => workflow.id)).toEqual(["task-one", "task-two"]);
  expect(summaries[0]!.agents[0]!.id).not.toBe(summaries[1]!.agents[0]!.id);
  expect(summaries[1]!.resumedFrom).toBe("task-one");
  expect(workflowDetailRequest(summaries[1]!, summaries[1]!.agents[0]!)).toEqual({
    sessionId: "session-plain",
    runId: "wf_same",
    agentId: "plain-agent",
  });
});

test("unrelated streamed text reuses workflow and agent array references", () => {
  const adapt = createWorkflowAdapter();
  const workflow = node("n");
  const first = adapt([workflow], "s");
  expect(adapt([{ ...workflow }], "s")).toBe(first);
});

test("paused, cancelled and unknown states stay explicit and unassigned agents stay visible", () => {
  const summaries = createWorkflowAdapter()(
    [
      node("paused", { state: "cancelled", paused: true }),
      node("cancelled", { state: "cancelled" }),
      node("unknown", { state: "future-state", phases: [] }),
    ],
    "s",
  );
  expect(summaries.map((workflow) => workflow.state)).toEqual(["paused", "cancelled", "unknown"]);
  expect(summaries[2]!.phases[0]!.agentIds).toContain(summaries[2]!.agents[0]!.id);
});

test("capacity has one shared two-minute window while idle uses last progress and keeps action", () => {
  const now = 1_000_000;
  const workflows = createWorkflowAdapter()(
    [
      node("n", {
        workflowAgents: new Map([
          [0, { index: 0, state: "running", retryReason: "HTTP 503 exhausted", lastProgressAt: now - 60_000 }],
          [1, { index: 1, state: "running", action: "Read routes", lastProgressAt: now - 180_000 }],
        ]),
      }),
    ],
    "s",
  );
  const error = (agentId: string, daemonId = "daemon-a") => ({
    agentId,
    daemonId,
    at: now - 60_000,
    reason: "HTTP 503 exhausted",
  });
  expect(workflowSignals(workflows, now).capacity).toBe(false);
  expect(workflowSignals(workflows, now, { daemonId: "daemon-a", errors: [error("a")] }).capacity).toBe(false);
  expect(workflowSignals(workflows, now, { daemonId: "daemon-a", errors: [error("a"), error("a")] }).capacity).toBe(
    false,
  );
  expect(
    workflowSignals(workflows, now, { daemonId: "daemon-a", errors: [error("a"), error("b", "daemon-b")] }).capacity,
  ).toBe(false);
  const daemon = { daemonId: "daemon-a", errors: [error("a"), error("b")] };
  expect(workflowSignals(workflows, now, daemon).capacity).toBe(true);
  expect(workflowSignals(workflows, now).idle.has(workflows[0]!.agents[1]!.id)).toBe(true);
  expect(workflows[0]!.agents[1]!.doing).toBe("Read routes");
  expect(workflowSignals(workflows, now + 61_000, daemon).capacity).toBe(false);
});

test("resume creates a visible Workflow message only from known launch input", () => {
  const launch = { scriptPath: "/project/review.ts", args: { target: "api" } };
  expect(workflowDraft(launch, "wf_resume")).toBe(
    'Workflow({"scriptPath":"/project/review.ts","resumeFromRunId":"wf_resume","args":{"target":"api"}})',
  );
  expect(workflowDraft(undefined, "wf_resume")).toBeUndefined();
  expect(workflowDraft(launch)).not.toContain("resumeFromRunId");
});

test("a node restored from the cached snapshot's JSON (its agents map turned `{}`) summarizes without agents", () => {
  const restored = JSON.parse(JSON.stringify(node("restored"))) as Subagent;
  const [summary] = createWorkflowAdapter()([restored], "s");
  expect(summary!.agents).toEqual([]);
  expect(summary!.phases[0]!.agentIds).toEqual([]);
});

test("workflow summaries retain the latest agent message with a legacy result fallback", () => {
  const agents = createWorkflowAdapter()(
    [
      node("messages", {
        workflowAgents: new Map([
          [
            0,
            {
              index: 0,
              model: "claude-opus",
              effort: "high",
              lastMessage: "Still reviewing.",
              result: "Earlier result",
            },
          ],
          [1, { index: 1, result: "Legacy result" }],
        ]),
      }),
    ],
    "s",
  )[0]!.agents;
  expect(agents[0]).toMatchObject({ model: "claude-opus", effort: "high", lastMessage: "Still reviewing." });
  expect(agents[1]!.lastMessage).toBe("Legacy result");
});

test("workflow summaries retain a failed agent's provider error", () => {
  const [workflow] = createWorkflowAdapter()(
    [
      node("failed", {
        workflowAgents: new Map([
          [
            0,
            {
              index: 0,
              state: "failed",
              error: "503: No provider capacity available",
              action: "Reading source",
            },
          ],
        ]),
      }),
    ],
    "s",
  );
  expect(workflow!.agents[0]).toMatchObject({
    state: "failed",
    error: "503: No provider capacity available",
    doing: "Reading source",
  });
});
