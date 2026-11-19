// l10n-allow-file: test fixture subagent names, not shipped UI.
// Every snapshot acpmux sends is new objects (the host's JSON, parsed again), and a running agent's
// progress moves fields no row draws (the fold's `progressVersion`, `quietSince`; a workflow's
// `progressVersion` on every one of its agents, `lastProgressAt`). The agent pane's lists draw a row
// only when what it shows changed: the summary card's Subagents tab (SubagentListRow), its Subagents
// section (SubagentStatusRow), the agents pill's list (AgentsPillRow) and a workflow's phases
// (WorkflowPhaseRow) and agent rows (WorkflowAgentLine). Each snapshot here is a structuredClone of
// the last with those fields moved; one more renames a single item. Counted from React's commits
// (support/rowRenders.ts).
// And the pill's time moves while the agent's time does (`elapsed`): a completed agent still
// waiting on background work of its own ticks, a finished one does not.
import { createRoot, rowRenders } from "./support/rowRenders";
import { afterAll, beforeAll, expect, test, jest } from "bun:test";
import { JSDOM } from "jsdom";
import { act, type ReactElement } from "react";
import type { Root } from "react-dom/client";
import type { Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";
import type { WorkflowSummary } from "../src/agent-session/acpmux/summary/workflow";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "Node",
  "Element",
  "HTMLElement",
  "getComputedStyle",
  "localStorage",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { url: "http://localhost/", pretendToBeVisual: true });
  const { window } = dom;
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    Node: window.Node,
    Element: window.Element,
    HTMLElement: window.HTMLElement,
    getComputedStyle: window.getComputedStyle.bind(window),
    localStorage: window.localStorage,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  // The whole file on one fake clock (the page's clocks among them), so its time only moves forward.
  jest.useFakeTimers();
});

afterAll(async () => {
  jest.useRealTimers();
  await teardownDom(saved, { window: dom.window, scope });
});

const NOW = Date.now();
const N = 200;

/// Two running subagents and N - 2 ended ones.
const fleet = (): Subagent[] => [
  ...Array.from({ length: 2 }, (_, i) => ({
    id: `run-${i}`,
    parent: null,
    name: `Runner ${i}`,
    task: `Run ${i}`,
    state: "running",
    startedAt: NOW - 60_000 - i * 1_000,
    progressVersion: 1,
    quietSince: NOW - 5_000,
  })),
  ...Array.from({ length: N - 2 }, (_, i) => ({
    id: `done-${i}`,
    parent: null,
    name: `Done ${i}`,
    task: `Task ${i}`,
    state: "completed",
    startedAt: NOW - 600_000 - i * 1_000,
    endedAt: NOW - 300_000 - i * 1_000,
    progressVersion: 1,
  })),
];

/// The next snapshot: every object new, and the fields no row draws moved on.
const nextSnapshot = (agents: Subagent[], step: number): Subagent[] =>
  structuredClone(agents).map((agent) => ({
    ...agent,
    progressVersion: (agent.progressVersion ?? 0) + step,
    ...(agent.state === "running" ? { quietSince: NOW - 5_000 + step * 100 } : {}),
  }));

/// The next snapshot with ended subagent `done-3` renamed.
const renamed = (agents: Subagent[], step: number) =>
  nextSnapshot(agents, step).map((agent) => (agent.id === "done-3" ? { ...agent, name: "Done 3, renamed" } : agent));

const WAITING: ReadonlySet<string> = new Set();
const open = (_id: string) => {};

async function mount<D>(first: D, element: (data: D) => ReactElement) {
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root: Root = createRoot(host);
  await act(async () => root.render(element(first)));
  return {
    host,
    show: (data: D) => act(async () => root.render(element(data))),
    unmount: () => act(async () => root.unmount()).then(() => host.remove()),
  };
}

/// Renders of `name` for three fresh snapshots that move only undrawn fields, then for one rename.
async function count(name: string, list: { show: (agents: Subagent[]) => Promise<void> }) {
  let agents = fleet();
  rowRenders.reset();
  for (let step = 1; step <= 3; step++) await list.show((agents = nextSnapshot(agents, step)));
  const fresh = rowRenders.count(name);
  rowRenders.reset();
  await list.show(renamed(agents, 4));
  return { fresh, change: rowRenders.count(name) };
}

test("Subagents tab: fresh snapshots draw no row; one rename draws one", async () => {
  const { SubagentsTab } = await import("../src/agent-session/acpmux/summary/SubagentsTab");
  const list = await mount(fleet(), (agents) => <SubagentsTab agents={agents} waiting={WAITING} onOpen={open} />);
  expect(list.host.querySelectorAll(".cv-subagent").length).toBe(N);
  const counts = await count("SubagentListRow", list);
  console.log(`FRESH tab ${JSON.stringify(counts)} (rows: ${N}, 3 fresh snapshots)`);
  expect(counts.fresh).toBe(0);
  expect(counts.change).toBe(1);
  expect(list.host.textContent).toContain("Done 3, renamed");
  await list.unmount();
});

test("Subagents section: fresh snapshots draw no row; one rename draws one", async () => {
  const { SubagentStatusList } = await import("../src/agent-session/acpmux/summary/SubagentStatusList");
  const list = await mount(fleet(), (agents) => <SubagentStatusList agents={agents} waiting={WAITING} onOpen={open} />);
  expect(list.host.querySelectorAll(".acpmux-summary-list > li").length).toBe(N);
  const counts = await count("SubagentStatusRow", list);
  console.log(`FRESH section ${JSON.stringify(counts)} (rows: ${N}, 3 fresh snapshots)`);
  expect(counts.fresh).toBe(0);
  expect(counts.change).toBe(1);
  expect(list.host.textContent).toContain("Done 3, renamed");
  await list.unmount();
});

test("Subagents section: fresh sub-session snapshots draw no row; one rename draws one (1,000 rows)", async () => {
  const { SubagentStatusList } = await import("../src/agent-session/acpmux/summary/SubagentStatusList");
  type Row = import("../src/agent-session/acpmux/subagents/subsessions").SubsessionRow;
  const M = 1_000;
  const rows = (): Row[] =>
    Array.from({ length: M }, (_, i) => ({
      sessionId: `sub-${i}`,
      harness: "claude",
      name: `Sub ${i}`,
      state: i < 3 ? "working" : "done",
      ...(i < 3 ? { doing: `Step ${i}` } : {}),
      depth: i % 2,
      lastMessage: "first",
      model: "sonnet",
    }));
  // Every object new, and the fields this row never reads moved on (its last message, its model).
  const next = (list: Row[], step: number): Row[] =>
    structuredClone(list).map((row) => ({ ...row, lastMessage: `message ${step}`, model: `model ${step}` }));
  const element = (subsessions: Row[]) => (
    <SubagentStatusList agents={[]} waiting={WAITING} subsessions={subsessions} onOpenSession={open} />
  );
  const list = await mount(rows(), element);
  expect(list.host.querySelectorAll(".acpmux-summary-subsession").length).toBe(M);
  let current = rows();
  rowRenders.reset();
  for (let step = 1; step <= 3; step++) await list.show((current = next(current, step)));
  const fresh = rowRenders.count("SubsessionStatusRow");
  rowRenders.reset();
  await list.show(
    next(current, 4).map((row) => (row.sessionId === "sub-7" ? { ...row, name: "Sub 7, renamed" } : row)),
  );
  const change = rowRenders.count("SubsessionStatusRow");
  console.log(`FRESH subsessions ${JSON.stringify({ fresh, change })} (rows: ${M}, 3 fresh snapshots)`);
  expect(fresh).toBe(0);
  expect(change).toBe(1);
  expect(list.host.textContent).toContain("Sub 7, renamed");
  await list.unmount();
});

test("agents pill: fresh snapshots draw no row; one rename draws one", async () => {
  const { AgentsPill } = await import("../src/agent-session/acpmux/subagents/AgentsPill");
  const tones: ReadonlyMap<string, number> = new Map();
  const list = await mount(fleet(), (agents) => (
    <AgentsPill agents={agents} waiting={WAITING} tones={tones} onOpen={open} />
  ));
  await act(async () => list.host.querySelector<HTMLButtonElement>(".acpmux-agents-pill")!.click());
  expect(list.host.querySelectorAll(".acpmux-agents-list__row").length).toBe(N);
  const counts = await count("AgentsPillRow", list);
  console.log(`FRESH pill ${JSON.stringify(counts)} (rows: ${N}, 3 fresh snapshots)`);
  expect(counts.fresh).toBe(0);
  expect(counts.change).toBe(1);
  expect(list.host.textContent).toContain("Done 3, renamed");
  await list.unmount();
});

test("agents pill: a completed agent still waiting on its own background work keeps its time moving", async () => {
  const { AgentsPill } = await import("../src/agent-session/acpmux/subagents/AgentsPill");
  const agents = [
    { id: "run", parent: null, name: "Runner", state: "running", startedAt: NOW - 60_000 },
    // Its task ended, but it waits on background work of its own (subagentFold.ts `awaitsOwnWork`).
    {
      id: "interim",
      parent: null,
      name: "Interim",
      state: "completed",
      startedAt: NOW - 90_000,
      endedAt: NOW - 30_000,
      reaction: { interim: true },
    },
    { id: "done", parent: null, name: "Finished", state: "completed", startedAt: NOW - 90_000, endedAt: NOW - 30_000 },
  ] as Subagent[];
  const list = await mount(agents, (data) => (
    <AgentsPill agents={data} waiting={WAITING} tones={new Map()} onOpen={open} />
  ));
  await act(async () => list.host.querySelector<HTMLButtonElement>(".acpmux-agents-pill")!.click());
  const timeOf = (name: string) =>
    [...list.host.querySelectorAll(".acpmux-agents-list__row")]
      .find((row) => row.textContent?.includes(name))
      ?.querySelector(".acpmux-agents-list__time")?.textContent;
  // The pill's Completed section (AgentsPill.tsx `completed`) draws the agents that are not running,
  // so both completed agents have a row and a time to compare: the Active filter (`live`) does not
  // reach them.
  const completed = [...list.host.querySelectorAll(".acpmux-agents-list__row")].map((row) => row.textContent ?? "");
  expect(completed.some((text) => text.includes("Interim"))).toBe(true);
  expect(completed.some((text) => text.includes("Finished"))).toBe(true);
  const before = { interim: timeOf("Interim"), done: timeOf("Finished") };
  expect(before.interim).toBeDefined();
  // One tick of the page's second clock: the tick is the behaviour checked, so its time is advanced.
  await act(async () => {
    jest.advanceTimersByTime(1_100);
  });
  const after = { interim: timeOf("Interim"), done: timeOf("Finished") };
  console.log(`PILL-TIME ${JSON.stringify({ before, after })}`);
  expect(after.interim).not.toBe(before.interim);
  expect(after.done).toBe(before.done);
  expect(after.done).toBe("1m");
  await list.unmount();
});

test("a workflow: fresh snapshots that bump its progress draw no phase and no agent row", async () => {
  const { WorkflowTasks } = await import("../src/agent-session/acpmux/session-info/WorkflowTasks");
  const { createWorkflowAdapter } = await import("../src/agent-session/acpmux/summary/foldWorkflows");
  const { workflowFixture } = await import("../src/agent-session/acpmux/summary/workflowFixture");
  const first = createWorkflowAdapter()(workflowFixture("running", NOW), "s1");
  // A fresh snapshot: new objects, the workflow's progress sequence bumped on each of its agents.
  const next = (workflows: WorkflowSummary[], step: number): WorkflowSummary[] =>
    structuredClone(workflows).map((workflow) => ({
      ...workflow,
      agents: workflow.agents.map((agent) => ({
        ...agent,
        progressVersion: (agent.progressVersion ?? 0) + step,
        lastProgressAt: NOW + step * 100,
      })),
    }));
  // The pane's opener is one stable function, as useSessionInfo's is.
  const openAgent = () => {};
  const list = await mount(first, (data) => <WorkflowTasks workflows={data} onOpenWorkflowAgent={openAgent} />);
  // Every phase with agents still to run opens, so their rows are drawn too.
  for (const head of list.host.querySelectorAll<HTMLButtonElement>(".acpmux-workflow-phase__head:not(:disabled)"))
    await act(async () => head.click());
  const phases = list.host.querySelectorAll(".acpmux-workflow-phase").length;
  const rows = list.host.querySelectorAll(".acpmux-workflow-agent").length;
  expect(phases).toBeGreaterThan(0);
  expect(rows).toBeGreaterThan(0);
  let workflows = first;
  rowRenders.reset();
  for (let step = 1; step <= 3; step++) await list.show((workflows = next(workflows, step)));
  const fresh = { phases: rowRenders.count("WorkflowPhaseRow"), rows: rowRenders.count("WorkflowAgentLine") };
  // One finished agent renamed.
  rowRenders.reset();
  const target = workflows[0]!.agents.find((agent) => agent.state === "completed")!.id;
  await list.show(
    next(workflows, 4).map((workflow) => ({
      ...workflow,
      agents: workflow.agents.map((agent) =>
        agent.id === target ? { ...agent, name: `${agent.name}, renamed` } : agent,
      ),
    })),
  );
  const change = { phases: rowRenders.count("WorkflowPhaseRow"), rows: rowRenders.count("WorkflowAgentLine") };
  console.log(`FRESH workflow ${JSON.stringify({ fresh, change })} (phases: ${phases}, agent rows: ${rows})`);
  expect(fresh.phases).toBe(0);
  expect(fresh.rows).toBe(0);
  // Its row, and its phase's (its dot and count read it).
  expect(change.rows).toBe(1);
  expect(change.phases).toBeLessThanOrEqual(1);
  expect(list.host.textContent).toContain(", renamed");
  await list.unmount();
});
