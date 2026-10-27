// l10n-allow-file: fixture workflow names in assertions, not shipped UI.
// The Inspector's Background tasks lists the chat's Claude workflows (Labs): a running one with
// its counts, tokens, description, phases with a dot per agent, the running phase open with its
// model and agents, and "Up next"; a finished one as "Workflow · Finished · 7 agents", its phases
// N/N, each opening into its agents. The data is a workflow's events fed through the real fold.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { renderToStaticMarkup } from "react-dom/server";
import { JSDOM } from "jsdom";
import { WorkflowTasks } from "../src/agent-session/acpmux/inspector/WorkflowTasks";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { finishedTrayItems, trayItems, withSubagentLines } from "../src/agent-session/acpmux/subagents/runningTray";
import { SUBAGENTS } from "../src/agent-session/acpmux/subagents/subagentFold";
import { SUBAGENT_DONE, WORKFLOW_CARD } from "../src/agent-session/acpmux/subagents/subagentRows";
import { WorkflowCard } from "../src/agent-session/acpmux/summary/WorkflowCard";
import { turnViewFrom } from "../src/agent-session/acpmux/conversation/turns";
import {
  createWorkflowAdapter,
  modelName,
  phaseState,
  tally,
  upNext,
} from "../src/agent-session/acpmux/summary/foldWorkflows";
import { workflowFixture } from "../src/agent-session/acpmux/summary/workflowFixture";

const NOW = 1_800_000_000_000;
const summaries = (stage: "running" | "finished") => createWorkflowAdapter()(workflowFixture(stage, NOW), "s1");
const text = (html: string) =>
  html
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();

test("the adapter derives each phase's state and counts, what runs next, and the model's name", () => {
  const [workflow] = summaries("running");
  expect(workflow!.description).toStartWith("Demo: 3 agents brainstorm names");
  expect(workflow!.phases.map((phase) => phase.state)).toEqual(["completed", "running", "pending"]);
  expect(tally(workflow!.agents)).toEqual({ running: 1, queued: 2, done: 3, failed: 0, total: 6 });
  expect(upNext(workflow!).map((phase) => phase.name)).toEqual(["Judge"]);
  expect(workflow!.agents[0]!.model).toBe("claude-opus-5-5");
  expect(phaseState([])).toBe("pending");
  expect([
    modelName("claude-opus-5-5"),
    modelName("sonnet"),
    modelName("claude-haiku-4-5-20251001"),
    modelName("gpt-6"),
  ]).toEqual(["Opus 5.5", "Sonnet", "Haiku 4.5", "Gpt 6"]);
});

test("a running workflow shows its counts, tokens, description, phases, the open running phase and Up next", () => {
  const html = renderToStaticMarkup(<WorkflowTasks workflows={summaries("running")} onStop={async () => undefined} />);
  const shown = text(html);
  // One group: the section's head counts it, so no group head.
  expect(html).not.toContain("acpmux-workflow-tasks__group");
  expect(shown).toContain("demo-name-tournament");
  expect(shown).toContain("1 running · 2 queued · 3 done · 185k tokens");
  expect(shown).toContain("Demo: 3 agents brainstorm names");
  expect(shown).toContain("Brainstorm 3 done");
  // The phase with a running agent is open: its model once, its agents with how long or Queued.
  expect(shown).toContain("Critique 1 running · 2 queued Model: Opus 5.5 punchy");
  expect(shown).toContain("playful Queued descriptive Queued");
  // Judge has no agent yet: not a phase row, but Up next.
  expect(html.match(/class="acpmux-workflow-phase"/g)?.length).toBe(2);
  expect(shown).toContain("Up next: Judge");
  expect(html.match(/acpmux-workflow-dot"/g)?.length).toBe(6);
  expect(html).toContain('aria-label="Stop demo-name-tournament"');
});

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
});

test("a finished workflow reads as finished with its size, and a phase opens into its agents", async () => {
  dom = new JSDOM("<!doctype html><main id=root></main>", { url: "http://localhost/" });
  for (const [key, value] of Object.entries({
    window: dom.window,
    document: dom.window.document,
    HTMLElement: dom.window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  })) {
    saved.set(key, scope[key]);
    scope[key] = value;
  }
  const container = dom.window.document.getElementById("root")!;
  root = createRoot(container);
  await act(async () => root!.render(<WorkflowTasks workflows={summaries("finished")} />));
  const shown = () => text(container.innerHTML);
  expect(shown()).toContain("demo-name-tournament 1m 20s Workflow · Finished · 7 agents · 432k tokens");
  expect(shown()).toContain("Brainstorm 3/3 Critique 3/3 Judge 1/1");
  expect(shown()).not.toContain("Up next");
  expect(container.querySelector("[aria-label='Stop demo-name-tournament']")).toBeNull();
  const judge = [...container.querySelectorAll("button")].find((button) => button.textContent?.startsWith("Judge"))!;
  await act(async () => judge.click());
  expect(shown()).toContain("Judge 1/1 Model: Opus 5.5 judge 41s");
});

test("with running and finished workflows, each group says how many it holds", () => {
  const [finished] = summaries("finished");
  const html = renderToStaticMarkup(
    <WorkflowTasks workflows={[...summaries("running"), { ...finished!, id: "earlier" }]} />,
  );
  expect(text(html)).toContain("1 running demo-name-tournament");
  expect(text(html)).toContain("1 finished demo-name-tournament");
});

test("blocked and skipped agents count as ended without finishing, never as unknown", () => {
  const nodes = workflowFixture("running", NOW).map((node) => {
    const agents = new Map(node.workflowAgents);
    agents.set(5, { ...agents.get(5)!, state: "blocked" });
    agents.set(6, { ...agents.get(6)!, state: "skipped" });
    return { ...node, workflowAgents: agents };
  });
  const [workflow] = createWorkflowAdapter()(nodes, "s1");
  expect(workflow!.agents.map((agent) => agent.state).slice(4)).toEqual(["failed", "cancelled"]);
  expect(tally(workflow!.agents)).toEqual({ running: 1, queued: 0, done: 3, failed: 2, total: 6 });
  expect(workflow!.phases[1]!.state).toBe("running");
});

test("the transcript card names the workflow, its size and time, with a dot per agent", () => {
  const [node] = workflowFixture("running", NOW).filter((each) => each.kind === "workflow");
  const html = renderToStaticMarkup(<WorkflowCard node={{ ...node!, endedAt: node!.startedAt + 13_000 }} />);
  expect(text(html)).toBe("demo-name-tournament Workflow 6 agents 13s");
  expect(html.match(/acpmux-workflow-dot"/g)?.length).toBe(6);
  // No handler: the card is no button anyone can press.
  expect(html).toContain("disabled");
});

test("with Labs, a workflow a group started is a card in the group's place and leaves no done line", () => {
  const nodes = workflowFixture("finished", NOW);
  const plain = { ...nodes[0]!, id: "acp-1/toolu_plain", kind: "Explore", name: "Explore", workflowAgents: undefined };
  const rows: AcpmuxRow[] = [
    { id: "u", version: 1, at: NOW - 200_000, kind: "user", text: "go" },
    { id: "g", version: 1, at: NOW - 120_000, kind: SUBAGENTS, subagents: [...nodes, plain] },
    { id: "a", version: 1, at: NOW - 10_000, kind: "assistant", text: "done" },
  ];
  const labs = withSubagentLines(rows, new Map(), true);
  expect(labs.map((row) => row.kind)).toEqual(["user", WORKFLOW_CARD, SUBAGENT_DONE, "assistant"]);
  expect(labs[1]!.subagents?.map((node) => node.id)).toEqual([nodes[0]!.id]);
  // A pause alone (the state kept, only the flag) draws the card again: its row's version moves.
  const cache = new Map();
  const first = withSubagentLines(rows, cache, true)[1]!;
  const paused = rows.map((row) =>
    row.kind === SUBAGENTS
      ? {
          ...row,
          subagents: row.subagents!.map((node) => (node.kind === "workflow" ? { ...node, paused: true } : node)),
        }
      : row,
  );
  expect(withSubagentLines(paused, cache, true)[1]!.version).not.toBe(first.version);
  expect(labs[2]!.subagents?.[0]!.id).toBe(plain.id);
  // Without Labs, the workflow is a done line like any subagent.
  expect(withSubagentLines(rows, new Map()).map((row) => row.kind)).toEqual([
    "user",
    SUBAGENT_DONE,
    SUBAGENT_DONE,
    "assistant",
  ]);
});

test("each workflow a group started is its own card row, so each row is one card tall", () => {
  const [node] = workflowFixture("finished", NOW);
  const rows: AcpmuxRow[] = [
    {
      id: "g",
      version: 1,
      at: NOW - 120_000,
      kind: SUBAGENTS,
      subagents: [node!, { ...node!, id: "acp-1/toolu_wf2" }],
    },
  ];
  const cards = withSubagentLines(rows, new Map(), true);
  expect(cards.map((row) => [row.kind, row.subagents?.length])).toEqual([
    [WORKFLOW_CARD, 1],
    [WORKFLOW_CARD, 1],
  ]);
});

test("a finished turn's fold keeps the workflow card outside it, where the workflow started", () => {
  const [node] = workflowFixture("finished", NOW);
  const rows: AcpmuxRow[] = [
    { id: "u", version: 1, at: NOW - 200_000, kind: "user", text: "go" },
    {
      id: "w1",
      version: 1,
      at: NOW - 190_000,
      kind: "activity",
      items: [{ kind: "tool", text: "Read a.ts" }],
      toolCount: 1,
    },
    { id: "g", version: 1, at: NOW - 180_000, kind: SUBAGENTS, subagents: [node!] },
    { id: "a", version: 1, at: NOW - 10_000, kind: "assistant", text: "done" },
    { id: "s", version: 1, at: NOW - 9_000, kind: "turnSummary", durationMs: 190_000, toolCount: 1 },
  ];
  const view = turnViewFrom(withSubagentLines(rows, new Map(), true), new Set(), { now: NOW });
  // The turn folded its work (the read) but the card is still drawn.
  expect(view.rows.some((row) => row.id === "w1")).toBe(false);
  expect(view.rows.some((row) => row.kind === WORKFLOW_CARD)).toBe(true);
});

test("with Labs, a workflow is in neither tray list, running or ended (App.tsx trayAgents)", () => {
  const running = workflowFixture("running", NOW);
  const finished = workflowFixture("finished", NOW);
  const plain = {
    ...finished[0]!,
    id: "acp-1/toolu_plain",
    kind: "Explore",
    name: "Explore",
    workflowAgents: undefined,
  };
  const labs = (agents: typeof running) => agents.filter((agent) => agent.kind !== "workflow");
  expect(trayItems(labs(running), [], [], true)).toEqual([]);
  expect(
    finishedTrayItems(labs([...finished, plain]), []).map((item) => (item.kind === "agent" ? item.agent.id : "")),
  ).toEqual([plain.id]);
  // Without Labs, both lists carry it, as before.
  expect(trayItems(running, [], [], true).length).toBe(1);
  expect(finishedTrayItems(finished, []).length).toBe(1);
});
