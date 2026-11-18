// l10n-allow-file: test fixture names and commands, not shipped UI.
// Session Info's lists render a row only when its own data changed: Usage's all chats, Also here's
// chats (ChildSessionRows), Subagents' lines, Background tasks, Connectors and a workflow's agents.
// One item's change draws that row alone, the section drawn again with the same data (fresh objects,
// as every snapshot acpmux sends is) draws none, and a second's tick draws no row whose time does not
// move. Counted from React's commits (support/rowRenders.ts) by a component each row draws once (its
// icon, its line, its clock), so base and head count the same thing.
import { createRoot, rowRenders } from "./support/rowRenders";
import { afterAll, beforeAll, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, type ReactElement } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";
import type { UsageEntry } from "../src/agent-session/acpmux/session-info/usageEntries";
import type { StartedSession } from "../src/agent-session/acpmux/started/startedSessions";
import type { Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";
import type { BackgroundCommand } from "../src/agent-session/acpmux/session-info/processes";

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

const N = 30;
const NOW = Date.now();

/// Mounts `element(data)` and hands back a way to draw it again with new data.
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

/// One tick of the page's second clock, on fake timers: the tick is the behaviour counted, so its time
/// is advanced, not waited out.
const tick = () =>
  act(async () => {
    jest.advanceTimersByTime(1_100);
  });

/// Counts `name`'s renders for: one item changed, the same data again (fresh objects), and a tick.
async function count<D>(
  name: string | string[],
  list: { show: (data: D) => Promise<void> },
  data: () => D,
  changed: () => D,
): Promise<{ change: number; same: number; tick: number }> {
  const names = Array.isArray(name) ? name : [name];
  const total = () => names.reduce((sum, each) => sum + rowRenders.count(each), 0);
  await list.show(data());
  rowRenders.reset();
  await list.show(changed());
  const change = total();
  await list.show(changed());
  rowRenders.reset();
  await list.show(changed());
  const same = total();
  rowRenders.reset();
  await tick();
  return { change, same, tick: total() };
}

const stats = (cost: number) =>
  ({
    launcher: "claude",
    autocompact: "none",
    autocompactCap: null,
    contextTokens: 10_000 + cost,
    contextWindow: null,
    compactions24h: 0,
    subagentsLive: 0,
    subagents1h: 0,
    subagents24h: 0,
    tokens24h: 1_000,
    costUsd24h: cost,
  }) as unknown as UsageEntry["usageStats"];

test("Usage's all chats: one chat's numbers change, the same chats again, a tick", async () => {
  const { UsageSection } = await import("../src/agent-session/acpmux/session-info/UsageSection");
  const entries = (bump = -1): UsageEntry[] =>
    Array.from({ length: N }, (_, i) => ({
      sessionId: `chat-${i}`,
      title: `Chat ${i}`,
      harness: "claude",
      usageStats: stats(1_000 - i + (i === bump ? 0.5 : 0)),
    }));
  const open = (_id: string) => {};
  const list = await mount(entries(), (sessions) => (
    <UsageSection sessions={sessions} onOpen={open} expanded chatId="chat-0" />
  ));
  const counts = await count(
    "SenderIcon",
    list,
    () => entries(),
    () => entries(7),
  );
  console.log(`SECTION-ROWS usage ${JSON.stringify(counts)} (rows: ${N})`);
  expect(counts.change).toBe(1);
  expect(counts.same).toBe(0);
  expect(counts.tick).toBe(0);
  await list.unmount();
});

test("Also here's chats: one chat's state changes, the same chats again", async () => {
  const { ChildSessionRows } = await import("../src/agent-session/acpmux/session-info/ChildSessionRows");
  const sessions = (bump = -1): StartedSession[] =>
    Array.from({ length: N }, (_, i) => ({
      sessionId: `child-${i}`,
      title: i === bump ? `Child ${i}, renamed` : `Child ${i}`,
      state: "idle",
      createdAt: NOW - i * 1_000,
    })) as StartedSession[];
  const open = (_id: string) => {};
  const list = await mount(sessions(), (data) => (
    <ul>
      <ChildSessionRows sessions={data} onOpen={open} />
    </ul>
  ));
  const counts = await count(
    "SenderIcon",
    list,
    () => sessions(),
    () => sessions(4),
  );
  console.log(`SECTION-ROWS also-here ${JSON.stringify(counts)} (rows: ${N})`);
  expect(counts.change).toBe(1);
  expect(counts.same).toBe(0);
  expect(counts.tick).toBe(0);
  await list.unmount();
});

test("Subagents' lines: one ended subagent changes, the same subagents again, a tick", async () => {
  const { SubagentsSection } = await import("../src/agent-session/acpmux/session-info/SubagentsSection");
  const agents = (bump = -1): Subagent[] =>
    [
      ...Array.from({ length: 2 }, (_, i) => ({
        id: `run-${i}`,
        parent: null,
        name: `Runner ${i}`,
        task: `Run ${i}`,
        state: "running",
        startedAt: NOW - 60_000 - i * 1_000,
      })),
      ...Array.from({ length: N - 2 }, (_, i) => ({
        id: `done-${i}`,
        parent: null,
        name: i === bump ? `Done ${i}, renamed` : `Done ${i}`,
        task: `Did ${i}`,
        state: "completed",
        startedAt: NOW - 600_000 - i * 1_000,
        endedAt: NOW - 300_000 - i * 1_000,
      })),
    ] as Subagent[];
  const waiting = new Set<string>();
  const open = (_id: string) => {};
  const list = await mount(agents(), (data) => <SubagentsSection agents={data} waiting={waiting} onOpen={open} />);
  // The ended lines' row opens their list.
  const ended = list.host.querySelector<HTMLElement>(".acpmux-session-info-subagents__ended");
  await act(async () => ended?.click());
  const counts = await count(
    "AgentLine",
    list,
    () => agents(),
    () => agents(5),
  );
  console.log(`SECTION-ROWS subagents ${JSON.stringify(counts)} (lines: ${N}, running: 2)`);
  expect(counts.change).toBe(1);
  expect(counts.same).toBe(0);
  // The running lines' times move; no ended line draws.
  expect(counts.tick).toBeLessThanOrEqual(2);
  await list.unmount();
});

test("Background tasks: one finished command changes, the same commands again, a tick", async () => {
  const { TasksSection } = await import("../src/agent-session/acpmux/session-info/TasksSection");
  const commands = (bump = -1): BackgroundCommand[] => [
    { id: "p-run", command: "bun run dev", state: "running", toolCallId: "call-run", startedAt: NOW - 30_000 },
    ...Array.from({ length: N - 1 }, (_, i) => ({
      id: `p-${i}`,
      command: i === bump ? `bun test shard ${i} --bail` : `bun test shard ${i}`,
      state: "completed" as const,
      toolCallId: `call-${i}`,
      startedAt: NOW - 600_000 - i * 1_000,
      endedAt: NOW - 500_000 - i * 1_000,
    })),
  ];
  const list = await mount(commands(), (data) => <TasksSection commands={data} />);
  const fold = [...list.host.querySelectorAll<HTMLElement>("button.acpmux-session-info-fold")].at(-1);
  await act(async () => fold?.click());
  expect(list.host.querySelectorAll("ul[data-finished] > li").length).toBe(N - 1);
  const counts = await count(
    "Clock",
    list,
    () => commands(),
    () => commands(3),
  );
  console.log(`SECTION-ROWS tasks ${JSON.stringify(counts)} (rows: ${N}, running: 1)`);
  expect(counts.change).toBe(1);
  expect(counts.same).toBe(0);
  // The running command's time moves; no finished row draws.
  expect(counts.tick).toBe(1);
  await list.unmount();
});

test("Connectors: one server's state changes, the same servers again", async () => {
  const { ConnectorsSection } = await import("../src/agent-session/acpmux/session-info/ConnectorsSection");
  const servers = (bump = -1) =>
    Array.from({ length: N }, (_, i) => ({ name: `server-${i}`, status: i === bump ? "failed" : "connected" }));
  const list = await mount(servers(), (data) => (
    <ConnectorsSection servers={data as Parameters<typeof ConnectorsSection>[0]["servers"]} />
  ));
  const counts = await count(
    "Icon",
    list,
    () => servers(),
    () => servers(9),
  );
  console.log(`SECTION-ROWS connectors ${JSON.stringify(counts)} (rows: ${N})`);
  expect(counts.change).toBe(1);
  expect(counts.same).toBe(0);
  expect(counts.tick).toBe(0);
  await list.unmount();
});

test("a workflow's finished agents: one agent changes, the same workflow again, a tick", async () => {
  const { WorkflowTasks } = await import("../src/agent-session/acpmux/session-info/WorkflowTasks");
  const { createWorkflowAdapter } = await import("../src/agent-session/acpmux/summary/foldWorkflows");
  const { workflowFixture } = await import("../src/agent-session/acpmux/summary/workflowFixture");
  type Summary = ReturnType<ReturnType<typeof createWorkflowAdapter>>[number];
  // A fresh fold each time, as each snapshot is: new objects with the same values.
  const workflows = (bump = false): Summary[] =>
    createWorkflowAdapter()(workflowFixture("running", NOW), "s1").map((workflow) => ({
      ...workflow,
      agents: workflow.agents.map((agent, index) =>
        bump && index === workflow.agents.findIndex((each) => each.state === "completed")
          ? { ...agent, name: `${agent.name}, renamed` }
          : agent,
      ),
    }));
  const list = await mount(workflows(), (data) => <WorkflowTasks workflows={data} />);
  const rows = list.host.querySelectorAll(".acpmux-workflow-finished__agents > li").length;
  expect(rows).toBeGreaterThan(0);
  const counts = await count(
    ["WorkflowAgentRow", "WorkflowAgentLine"],
    list,
    () => workflows(),
    () => workflows(true),
  );
  console.log(`SECTION-ROWS workflow-agents ${JSON.stringify(counts)} (finished rows: ${rows})`);
  expect(counts.change).toBe(1);
  expect(counts.same).toBe(0);
  expect(counts.tick).toBe(0);
  await list.unmount();
});
