// l10n-allow-file: deterministic workflow names and failure messages in behavioral fixtures.
import { expect, test } from "bun:test";
import { translate } from "../src/agent-session/acpmux/i18n";
import { compactTokens } from "../src/agent-session/acpmux/conversation/CompactionNote";
import { NativeInfoActions } from "../src/agent-session/acpmux/session-info/native/model";
import {
  reconcileNativeWorkflowPhases,
  tasksSection,
  type NativeWorkflowPhaseChoices,
  type TasksSectionInput,
} from "../src/agent-session/acpmux/session-info/native/tasks";
import { createWorkflowAdapter } from "../src/agent-session/acpmux/summary/foldWorkflows";
import type { WorkflowAgent, WorkflowSummary } from "../src/agent-session/acpmux/summary/workflow";
import { workflowFixture } from "../src/agent-session/acpmux/summary/workflowFixture";

const NOW = 1_800_000_000_000;
const summaries = (stage: "running" | "finished") => createWorkflowAdapter()(workflowFixture(stage, NOW), "s1");
const base = (workflows: readonly WorkflowSummary[]): TasksSectionInput => ({
  open: true,
  processes: [],
  transcriptTasks: [],
  listed: true,
  scheduled: [],
  workflows,
  local: true,
  now: NOW,
});
const model = (input: TasksSectionInput, actions = new NativeInfoActions()) => tasksSection(input, actions, translate)!;
const fixture = (agents: WorkflowAgent[], state: WorkflowSummary["state"] = "running"): WorkflowSummary => ({
  id: "work",
  title: "Research",
  state,
  sessionId: "chat",
  runId: "run",
  agents,
  phases: [{ id: "draft", name: "Draft", state: "pending", agentIds: agents.map((agent) => agent.id) }],
});

test("all phases stay in source order, with descriptions and inert empty pending rows", () => {
  const [workflow] = summaries("running");
  const section = model({ ...base([workflow!]), onPhase: () => {} });
  const phases = section.rows.filter((row) => row.id.startsWith("phase:"));
  expect(phases.map((row) => row.title)).toEqual(workflow!.phases.map((phase) => phase.name));
  expect(phases).toHaveLength(3);
  expect(section.rows.find((row) => row.id === `workflowDescription:${workflow!.id}`)!.title).toBe(
    workflow!.description!,
  );
  expect(section.rows.map((row) => row.title).join(" ")).not.toContain("Up next");
  const pending = phases.at(-1)!;
  expect(pending.title).toBe("Judge");
  expect(pending.action).toBeUndefined();
  expect(pending.symbol).toBeUndefined();
  expect(pending.marks).toEqual([]);
  expect(phases[0]!.marks).toEqual(["done", "done", "done"]);
  expect(phases[1]!.marks).toEqual(["accent", "muted", "muted"]);
});

test("phase actions fold the named phase without making an empty phase clickable", async () => {
  const workflow = fixture([{ id: "queued", name: "Queued writer", state: "waiting" }]);
  workflow.phases.push({ id: "empty", name: "Publish", state: "pending", agentIds: [] });
  const actions = new NativeInfoActions();
  const folded: [string, boolean][] = [];
  const section = model({ ...base([workflow]), onPhase: (key, open) => folded.push([key, open]) }, actions);
  const phase = section.rows.find((row) => row.id === "phase:work/draft")!;
  expect(section.rows.some((row) => row.id.startsWith("workflowAgent:"))).toBe(false);
  expect(actions.run(phase.action!)).toBe(true);
  await Promise.resolve();
  expect(folded).toEqual([["work/draft", true]]);
  expect(section.rows.find((row) => row.id === "phase:work/empty")!.action).toBeUndefined();
});

test("agent rows preserve failure reason, model, queued time, and transcript bridge gating", async () => {
  const failed: WorkflowAgent = {
    id: "failed",
    agentId: "agent-failed",
    name: "Writer",
    state: "failed",
    model: "claude-opus-5-5",
    effort: "medium",
    error: "Provider refused the request",
    lastMessage: "Older message",
    doing: "Reading",
    elapsedMs: 12_000,
  };
  const queued: WorkflowAgent = {
    id: "queued",
    name: "Editor",
    state: "pending",
    elapsedMs: 99_000,
  };
  const workflow = fixture([failed, queued]);
  const opened: WorkflowAgent[] = [];
  const actions = new NativeInfoActions();
  const input = {
    ...base([workflow]),
    phases: { "work/draft": true },
    onOpenWorkflowAgent: (agent: WorkflowAgent) => opened.push(agent),
  };
  const rows = model(input, actions).rows;
  const writer = rows.find((row) => row.id === "workflowAgent:work/failed")!;
  const editor = rows.find((row) => row.id === "workflowAgent:work/queued")!;
  // The workflow names its model and effort once in its head; a row names its own only where it differs.
  expect(writer.detail).toBeUndefined();
  expect(rows.find((row) => row.id === "workflow:work")?.subtitle ?? "").toContain("Opus 5.5 · medium");
  const other = model(
    { ...input, workflows: [fixture([failed, queued, { ...failed, id: "sonnet", model: "claude-sonnet-5-5" }])] },
    new NativeInfoActions(),
  ).rows.find((row) => row.id === "workflowAgent:work/sonnet")!;
  expect(other.detail).toBe("Model: Sonnet 5.5 · medium");
  expect(writer.subtitle).toBe(failed.error);
  expect(writer.trailing).toContain("12s");
  expect(writer.symbol).toBe("xmark");
  expect(editor.trailing).toBe(translate("workflow.agentQueued"));
  expect(editor.action).toBeUndefined();
  expect(actions.run(writer.action!)).toBe(true);
  await Promise.resolve();
  expect(opened).toEqual([failed]);
  expect(
    model({ ...input, workflows: [{ ...workflow, runId: undefined }] }).rows.find((row) => row.id === writer.id)!
      .action,
  ).toBeUndefined();
});

test("a phase opens on its first start, then keeps the person's fold choice across updates", () => {
  const pending = fixture([{ id: "a", name: "Writer", state: "pending" }]);
  let choices = reconcileNativeWorkflowPhases([pending], {});
  expect(choices["work/draft"]).toEqual({ started: false, open: false });
  const running = { ...pending, agents: [{ ...pending.agents[0]!, state: "running" as const }] };
  choices = reconcileNativeWorkflowPhases([running], choices);
  expect(choices["work/draft"]).toEqual({ started: true, open: true });
  const closed: NativeWorkflowPhaseChoices = {
    ...choices,
    "work/draft": { ...choices["work/draft"]!, open: false },
  };
  expect(reconcileNativeWorkflowPhases([{ ...running, tokens: 40_000 }], closed)).toBe(closed);
  expect(reconcileNativeWorkflowPhases([], closed)).toEqual({});
});

test("running workflows sort ahead of finished ones and Stop reflects pending or failed operations", async () => {
  const running = { ...fixture([]), tokens: 1200, startedAt: NOW - 20_000 };
  const paused = { ...fixture([], "paused"), id: "paused", elapsedMs: 40_000 };
  const actions = new NativeInfoActions();
  const stopped: string[] = [];
  const input = {
    ...base([paused, running]),
    onStopWorkflow: async (id: string) => {
      stopped.push(id);
    },
  };
  const rows = model({ ...input, operations: { "workflow:work": "pending" } }, actions).rows;
  expect(rows.filter((row) => row.id.startsWith("workflow:")).map((row) => row.id)).toEqual([
    "workflow:work",
    "workflow:paused",
  ]);
  expect(rows.find((row) => row.id === "workflow:paused")!.subtitle).toContain(translate("goal.paused"));
  expect(rows.find((row) => row.id === "workflow:paused")!.buttons).toBeUndefined();
  const pending = rows.find((row) => row.id === "workflow:work")!.buttons![0]!;
  expect(pending.disabled).toBe(true);
  const failed = model({ ...input, operations: { "workflow:work": "failed" } }, actions).rows.find(
    (row) => row.id === "workflow:work",
  )!.buttons![0]!;
  expect(failed.disabled).not.toBe(true);
  expect(failed.label).toBe(translate("subagents.stopFailed", { name: running.title }));
  expect(actions.run(failed.action)).toBe(true);
  await Promise.resolve();
  expect(stopped).toEqual(["work"]);
});

test("native workflow subtitles omit kind and grouped Completed, but keep other outcomes", () => {
  const completed = { ...fixture([], "completed"), id: "completed", tokens: 1200 };
  const failed = { ...fixture([], "failed"), id: "failed", tokens: 1200 };
  const running = { ...fixture([], "running"), id: "running" };
  const completedStatus = translate("bgTask.state.completed");
  const failedStatus = translate("subagents.state.failed");
  const kind = translate("workflow.kind");
  const count = translate("subagents.pill", { n: 0 });
  const tokens = translate("subagents.tokens", { n: 1200, tokens: compactTokens(1200) });

  const solo = model(base([completed])).rows.find((row) => row.id === "workflow:completed")!;
  expect(solo.subtitle).toContain(completedStatus);
  expect(solo.subtitle).toContain(count);
  expect(solo.subtitle).toContain(tokens);
  expect(solo.subtitle).not.toContain(kind);

  const mixed = model(base([running, completed, failed])).rows;
  const groupedCompleted = mixed.find((row) => row.id === "workflow:completed")!;
  const groupedFailed = mixed.find((row) => row.id === "workflow:failed")!;
  expect(groupedCompleted.subtitle).not.toContain(completedStatus);
  expect(groupedCompleted.subtitle).toContain(count);
  expect(groupedCompleted.subtitle).toContain(tokens);
  expect(groupedFailed.subtitle).toContain(`${failedStatus} ·`);
  expect(groupedFailed.subtitle).not.toContain(kind);
});
