// l10n-allow-file: replay assertions use the scrubbed workflow recording's fixture labels.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { WorkflowCard } from "./WorkflowCard";
import { WorkflowSummaries } from "./WorkflowSummary";
import { createWorkflowAdapter } from "./foldWorkflows";
import { realWorkflowFixture } from "../realWorkflowFixture";
import { WorkflowTasks } from "../inspector/WorkflowTasks";

const pane = globalThis as { __cmuxPaneStrings?: Record<string, Record<string, string>> };
pane.__cmuxPaneStrings ??= (await import("../generated/strings.json")).default;

const NOW = 1_000_000;
const nodes = realWorkflowFixture(NOW);
const [workflowNode] = nodes;
const [workflow] = createWorkflowAdapter()(nodes, "workflow-session");
const [runningWorkflow] = createWorkflowAdapter()(realWorkflowFixture(NOW, 8_760), "workflow-session");
const text = (html: string) =>
  html
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();

test("a real Claude workflow replay folds into its phases, agents, states, models and durations", () => {
  expect(workflow).toMatchObject({
    id: "workflow-session/tool-workflow",
    title: "count-files-fixture",
    description: "Tiny 2-phase fixture: two agents count files, one agent reports the combined count",
    state: "completed",
    runId: "workflow-run-1",
    elapsedMs: 10_780,
    tokens: 84_080,
    counts: { done: 3, started: 3 },
  });
  expect(workflow!.phases.map(({ id, name, state, agentIds }) => ({ id, name, state, agentIds }))).toEqual([
    {
      id: "1",
      name: "Count",
      state: "completed",
      agentIds: ['["workflow-session/tool-workflow",1]', '["workflow-session/tool-workflow",2]'],
    },
    {
      id: "2",
      name: "Report",
      state: "completed",
      agentIds: ['["workflow-session/tool-workflow",3]'],
    },
  ]);
  expect(workflow!.agents).toEqual([
    expect.objectContaining({
      name: "count-a",
      state: "completed",
      model: "claude-opus-5-5",
      elapsedMs: 5_054,
      startedAt: NOW - 10_716,
    }),
    expect.objectContaining({
      name: "count-b",
      state: "completed",
      model: "claude-opus-5-5",
      elapsedMs: 4_640,
      startedAt: NOW - 10_716,
    }),
    expect.objectContaining({
      name: "report",
      state: "completed",
      model: "claude-opus-5-5",
      elapsedMs: 4_195,
      startedAt: NOW - 4_201,
    }),
  ]);
});

test("a running replay anchors agent start times to its injected clock", () => {
  expect(runningWorkflow).toMatchObject({
    state: "running",
    startedAt: NOW - 8_760,
    elapsedMs: undefined,
  });
  expect(runningWorkflow!.agents[0]).toMatchObject({ state: "completed", startedAt: NOW - 8_696 });
  expect(runningWorkflow!.agents[2]).toMatchObject({ state: "running", startedAt: NOW - 2_181 });
});

test("the replay renders in the transcript card, Session Info tasks and summary", () => {
  const card = renderToStaticMarkup(<WorkflowCard node={{ ...workflowNode!, endedAt: NOW }} />);
  const tasks = renderToStaticMarkup(<WorkflowTasks workflows={[workflow!]} />);
  const summary = renderToStaticMarkup(<WorkflowSummaries workflows={[workflow!]} />);
  expect(text(card)).toContain("count-files-fixture Done Report 3/3 10s 84.1K tokens");
  expect(card).toContain('aria-valuemax="3" aria-valuenow="3"');
  expect(text(tasks)).toContain("count-files-fixture 10s Workflow · Finished · 3 agents · 84k tokens");
  expect(text(tasks)).toContain("Count 2/2 Report 1/1");
  expect(text(summary)).toContain("count-files-fixture");
  expect(text(summary)).toContain("3/3");
});
