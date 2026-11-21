// l10n-allow-file: test fixture names and commands, not shipped UI.
// Session Info's second clock draws only the times that move. While items run, a tick of the page's
// one-second clock renders no row (a running row's time is a leaf that ticks alone, counted apart),
// and the lists' sort and split (Subagents' `splitSubagentLines`, Background tasks' `splitCommands`,
// a workflow's `splitAgents`) run 0 times on a tick that changes no item's group or order: they run
// when the items change, or when a running subagent crosses into idle. At N = 1,000 items.
// A running workflow agent's row keeps its time in its accessible name: the row says the words
// before the time and the leaf says the time (aria-labelledby), so a screen reader hears the same
// name as before ("agent-0, Reading file 0, Running, 1m 0s") while the row itself is never drawn
// again by the clock. Counted from React's commits (support/rowRenders.ts).
import { createRoot, rowRenders } from "./support/rowRenders";
import { afterAll, beforeAll, expect, jest, spyOn, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, type ReactElement } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";
import type { Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";
import type { BackgroundCommand } from "../src/agent-session/acpmux/session-info/processes";
import type { WorkflowAgent, WorkflowSummary } from "../src/agent-session/acpmux/summary/workflow";

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

const N = 1_000;
const NOW = Date.now();

async function mount(element: ReactElement) {
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root: Root = createRoot(host);
  await act(async () => root.render(element));
  return { host, unmount: () => act(async () => root.unmount()).then(() => host.remove()) };
}

/// The page's clocks moved on by `ms` (one second's tick by default), on the file's fake clock: the
/// ticks are the behaviour counted, so their time is advanced, not waited out.
const tick = (ms = 1_100) =>
  act(async () => {
    jest.advanceTimersByTime(ms);
  });

/// Calls of `fn` on `module` while `during` runs; -1 when the module has no such function.
async function calls(module: object, fn: string, during: () => Promise<void>): Promise<number> {
  if (typeof (module as Record<string, unknown>)[fn] !== "function") {
    await during();
    return -1;
  }
  const spy = spyOn(module as Record<string, (...args: unknown[]) => unknown>, fn);
  try {
    spy.mockClear();
    await during();
    return spy.mock.calls.length;
  } finally {
    spy.mockRestore();
  }
}

/// The accessible name of `node` as a screen reader computes it from these attributes:
/// aria-labelledby's elements' text joined by spaces, else aria-label, else its text.
function accessibleName(node: Element): string {
  const ids = node.getAttribute("aria-labelledby");
  if (ids)
    return ids
      .split(/\s+/)
      .map((id) => node.ownerDocument.getElementById(id)?.textContent?.trim() ?? "")
      .join(" ");
  return node.getAttribute("aria-label") ?? node.textContent ?? "";
}

const runningAgent = (i: number, fields: Partial<Subagent> = {}): Subagent =>
  ({
    id: `run-${i}`,
    parent: null,
    name: `Runner ${i}`,
    task: `Run ${i}`,
    state: "running",
    startedAt: NOW - 60_000 - i * 1_000,
    ...fields,
  }) as Subagent;

const subagents = (running: number, extra: Subagent[] = []): Subagent[] =>
  [
    ...Array.from({ length: running }, (_, i) => runningAgent(i)),
    ...extra,
    ...Array.from({ length: N - running - extra.length }, (_, i) => ({
      id: `done-${i}`,
      parent: null,
      name: `Done ${i}`,
      task: `Did ${i}`,
      state: i % 50 === 0 ? "failed" : "completed",
      startedAt: NOW - 600_000 - i * 1_000,
      endedAt: NOW - 300_000 - i * 1_000,
    })),
  ] as Subagent[];

test("Subagents at N = 1,000: a tick draws no line, counts and sorts nothing; only the times tick", async () => {
  const { SubagentCountsMeta, SubagentsSection } =
    await import("../src/agent-session/acpmux/session-info/SubagentsSection");
  const model = await import("../src/agent-session/acpmux/session-info/subagentsSectionModel");
  const status = await import("../src/agent-session/acpmux/summary/subagentStatusListModel");
  const agents = subagents(3);
  const waiting = new Set<string>();
  const open = (_id: string) => {};
  const list = await mount(
    <div>
      <SubagentCountsMeta agents={agents} waiting={waiting} sessions={[]} />
      <SubagentsSection agents={agents} waiting={waiting} onOpen={open} />
    </div>,
  );
  // The ended lines' row opens their list (windowed: the rows that can show).
  const ended = list.host.querySelector<HTMLElement>(".acpmux-session-info-subagents__ended");
  await act(async () => ended?.click());
  const mounted = list.host.querySelectorAll(".acpmux-agent-line").length;
  const times = () =>
    [...list.host.querySelectorAll(".acpmux-session-info-subagents__running .acpmux-agent-line__time")].map(
      (node) => node.textContent,
    );
  const before = times();
  await tick(200);
  rowRenders.reset();
  let statusCalls = 0;
  const splits = await calls(model, "splitSubagentLines", async () => {
    statusCalls = await calls(status, "subagentStatus", () => tick());
  });
  const counts = {
    lines: rowRenders.count("SubagentLineRow"),
    agentLine: rowRenders.count("AgentLine"),
    section: rowRenders.count("SubagentsSection"),
    leaf: rowRenders.count("SubagentTime"),
    splits,
    statusCalls,
  };
  console.log(`CLOCK subagents ${JSON.stringify(counts)} (items: ${N}, running: 3, mounted lines: ${mounted})`);
  // The three running lines' times moved, drawn by their leaves alone.
  expect(times()).not.toEqual(before);
  expect(times()).toHaveLength(3);
  expect(counts.lines).toBe(0);
  expect(counts.agentLine).toBe(0);
  expect(counts.section).toBe(0);
  expect(counts.leaf).toBe(3);
  expect(counts.splits).toBe(0);
  expect(counts.statusCalls).toBe(0);
  await list.unmount();
});

test("Subagents: a running one crossing into idle sorts once and draws that line alone", async () => {
  const { SubagentsSection } = await import("../src/agent-session/acpmux/session-info/SubagentsSection");
  const model = await import("../src/agent-session/acpmux/session-info/subagentsSectionModel");
  const { IDLE_AFTER_MS } = await import("../src/agent-session/acpmux/subagents/idle");
  // Quiet for all but 1.5 s of the idle window: it turns idle on the second tick from now.
  const quiet = runningAgent(9, { name: "Quiet one", quietSince: Date.now() - IDLE_AFTER_MS + 1_500 });
  const agents = subagents(3, [quiet]);
  const waiting = new Set<string>();
  const list = await mount(<SubagentsSection agents={agents} waiting={waiting} onOpen={() => {}} />);
  const state = () =>
    [...list.host.querySelectorAll(".acpmux-session-info-subagents__running .acpmux-agent-line")].map((line) =>
      line.getAttribute("data-status"),
    );
  // The quiet one started first, so it leads the running ones.
  expect(state()).toEqual(["running", "running", "running", "running"]);
  rowRenders.reset();
  const splits = await calls(model, "splitSubagentLines", () => tick(2_200));
  const counts = { lines: rowRenders.count("SubagentLineRow"), splits };
  console.log(`CLOCK subagents-idle ${JSON.stringify(counts)} (items: ${N}, running: 4, one turns idle)`);
  // Idle keeps its place among the live ones; its line says so.
  expect(state()).toEqual(["idle", "running", "running", "running"]);
  expect(counts.splits).toBe(1);
  expect(counts.lines).toBe(1);
  await list.unmount();
});

test("Background tasks at N = 1,000: a tick draws no row and splits nothing; only the times tick", async () => {
  const { TasksSection } = await import("../src/agent-session/acpmux/session-info/TasksSection");
  const processes = await import("../src/agent-session/acpmux/session-info/processes");
  const commands: BackgroundCommand[] = [
    ...Array.from({ length: 3 }, (_, i) => ({
      id: `p-run-${i}`,
      command: `bun run dev --port ${3000 + i}`,
      state: "running" as const,
      toolCallId: `call-run-${i}`,
      startedAt: NOW - 30_000 - i * 1_000,
    })),
    ...Array.from({ length: N - 3 }, (_, i) => ({
      id: `p-${i}`,
      command: `bun test shard ${i}`,
      state: "completed" as const,
      toolCallId: `call-${i}`,
      startedAt: NOW - 600_000 - i * 1_000,
      endedAt: NOW - 500_000 - i * 1_000,
    })),
  ];
  const list = await mount(<TasksSection commands={commands} />);
  const fold = [...list.host.querySelectorAll<HTMLElement>("button.acpmux-session-info-fold")].at(-1);
  await act(async () => fold?.click());
  const mounted = list.host.querySelectorAll("li.acpmux-session-info-task").length;
  const times = () =>
    [...list.host.querySelectorAll("li[data-state=running] .acpmux-session-info-task__time")].map(
      (node) => node.textContent,
    );
  const before = times();
  await tick(200);
  rowRenders.reset();
  const splits = await calls(processes, "splitCommands", () => tick());
  const counts = {
    rows: rowRenders.count("CommandRow"),
    section: rowRenders.count("TasksSection"),
    leaf: rowRenders.count("Clock"),
    splits,
  };
  console.log(`CLOCK tasks ${JSON.stringify(counts)} (items: ${N}, running: 3, mounted rows: ${mounted})`);
  expect(times()).not.toEqual(before);
  expect(times()).toHaveLength(3);
  expect(counts.rows).toBe(0);
  expect(counts.section).toBe(0);
  expect(counts.leaf).toBe(3);
  expect(counts.splits).toBe(0);
  await list.unmount();
});

/// A running workflow of `N` agents in one phase, each running, openable through the workflow bridge.
function bigWorkflow(): WorkflowSummary {
  const agents: WorkflowAgent[] = Array.from({ length: N }, (_, i) => ({
    id: `wf:${i}`,
    index: i,
    agentId: `agent-${i}`,
    name: `agent-${i}`,
    state: "running",
    doing: `Reading file ${i}`,
    startedAt: NOW - 60_000 - i * 1_000,
  }));
  return {
    id: "wf",
    title: "big-run",
    state: "running",
    sessionId: "s1",
    runId: "run-1",
    startedAt: NOW - 120_000,
    phases: [{ id: "p1", name: "Read", state: "running", agentIds: agents.map((agent) => agent.id) }],
    agents,
  };
}

test("a workflow at N = 1,000 running agents: a tick draws no agent row; each time ticks in its leaf, named", async () => {
  const { WorkflowTasks } = await import("../src/agent-session/acpmux/session-info/WorkflowTasks");
  const view = await import("../src/agent-session/acpmux/summary/workflowView");
  const workflow = bigWorkflow();
  const list = await mount(<WorkflowTasks workflows={[workflow]} onOpenWorkflowAgent={() => {}} />);
  const phase = list.host.querySelector<HTMLElement>(".acpmux-workflow-phase__head");
  await act(async () => phase?.click());
  const buttons = () => [...list.host.querySelectorAll("button.acpmux-workflow-agent__button")];
  const mounted = buttons().length;
  expect(mounted).toBeGreaterThan(0);
  await tick(200);
  const nameBefore = accessibleName(buttons()[0]!);
  rowRenders.reset();
  const splits = await calls(view, "splitAgents", () => tick());
  const nameAfter = accessibleName(buttons()[0]!);
  const counts = {
    rows: rowRenders.count("WorkflowAgentLine"),
    phases: rowRenders.count("WorkflowPhaseRow"),
    task: rowRenders.count("WorkflowTask"),
    leaf: rowRenders.count("ElapsedTime"),
    splits,
  };
  console.log(
    `CLOCK workflow-agents ${JSON.stringify(counts)} (agents: ${N}, mounted rows: ${mounted}) name: ${JSON.stringify(nameBefore)} -> ${JSON.stringify(nameAfter)}`,
  );
  // The name carries the time, and the time moved with the tick.
  expect(nameBefore).toMatch(/^agent-0, Reading file 0, Running, \d+m \d+s$/);
  expect(nameAfter).toMatch(/^agent-0, Reading file 0, Running, \d+m \d+s$/);
  expect(nameAfter).not.toBe(nameBefore);
  // The visible time is the name's time: one text, drawn once.
  const time = buttons()[0]!.querySelector(".acpmux-session-info-task__time")?.textContent;
  expect(nameAfter.endsWith(`, ${time}`)).toBe(true);
  expect(counts.rows).toBe(0);
  expect(counts.phases).toBe(0);
  expect(counts.task).toBe(0);
  // Each mounted agent's time and the workflow's own.
  expect(counts.leaf).toBe(mounted + 1);
  expect(counts.splits).toBe(0);
  await list.unmount();
});
