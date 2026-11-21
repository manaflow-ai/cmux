// l10n-allow-file: test fixture subagent names, not shipped UI.
// The subagent lists' rows render only when their own data changed: the summary card's Subagents tab
// (SubagentsTab.tsx), its Subagents section (SubagentStatusList.tsx) and the agents pill's list
// (AgentsPill.tsx). One subagent's change draws its row alone, the list drawn again with the same
// subagents draws none, and a second's tick draws no ended row (the pill's rows none at all: each
// time is a leaf on its own clock). Counted from React's commits (support/rowRenders.ts).
import { createRoot, rowRenders } from "./support/rowRenders";
import { afterAll, beforeAll, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, type ReactElement } from "react";
import type { Root } from "react-dom/client";
import type { Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";
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
/// Two running subagents and twenty ended ones, a fresh object each as the app's state is.
const fleet = (): Subagent[] => [
  ...Array.from({ length: 2 }, (_, i) => ({
    id: `run-${i}`,
    parent: null,
    name: `Runner ${i}`,
    task: `Run ${i}`,
    state: "running",
    startedAt: NOW - 60_000 - i * 1_000,
  })),
  ...Array.from({ length: 20 }, (_, i) => ({
    id: `done-${i}`,
    parent: null,
    name: `Done ${i}`,
    task: `Task ${i}`,
    state: "completed",
    startedAt: NOW - 600_000 - i * 1_000,
    endedAt: NOW - 300_000 - i * 1_000,
  })),
];
/// The same fleet with ended subagent `done-3` renamed.
const oneChanged = (agents: Subagent[]) =>
  agents.map((agent) => (agent.id === "done-3" ? { ...agent, name: "Done 3, renamed" } : agent));

const WAITING: ReadonlySet<string> = new Set();
const open = (_id: string) => {};

async function mount(element: (agents: Subagent[]) => ReactElement) {
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root: Root = createRoot(host);
  let agents = fleet();
  await act(async () => root.render(element(agents)));
  return {
    host,
    set: async (next: Subagent[]) => {
      agents = next;
      await act(async () => root.render(element(agents)));
    },
    current: () => agents,
    unmount: () => act(async () => root.unmount()).then(() => host.remove()),
  };
}

/// One tick of the page's second clock, on fake timers: the tick is the behaviour counted, so its time
/// is advanced, not waited out.
const tick = () =>
  act(async () => {
    jest.advanceTimersByTime(1_100);
  });

test("Subagents tab: one subagent's change, a parent render with the same subagents, a tick", async () => {
  const { SubagentsTab } = await import("../src/agent-session/acpmux/summary/SubagentsTab");
  const list = await mount((agents) => <SubagentsTab agents={agents} waiting={WAITING} onOpen={open} />);
  expect(list.host.querySelectorAll(".cv-subagent").length).toBe(22);
  rowRenders.reset();
  await list.set(oneChanged(list.current()));
  const change = rowRenders.count("SubagentListRow");
  rowRenders.reset();
  await list.set(list.current());
  const same = rowRenders.count("SubagentListRow");
  rowRenders.reset();
  await tick();
  const ticked = rowRenders.count("SubagentListRow");
  console.log(
    `SUBAGENT-LISTS tab: one-item change=${change} parent same data=${same} tick=${ticked} (running rows: 2)`,
  );
  expect(change).toBe(1);
  expect(same).toBe(0);
  // Only the two running rows keep a clock.
  expect(ticked).toBeLessThanOrEqual(2);
  await list.unmount();
});

test("Subagents section: one subagent's change, a parent render with the same subagents, a tick", async () => {
  const { SubagentStatusList } = await import("../src/agent-session/acpmux/summary/SubagentStatusList");
  const list = await mount((agents) => <SubagentStatusList agents={agents} waiting={WAITING} onOpen={open} />);
  expect(list.host.querySelectorAll(".acpmux-summary-list > li").length).toBe(22);
  rowRenders.reset();
  await list.set(oneChanged(list.current()));
  const change = rowRenders.count("AgentLine");
  rowRenders.reset();
  await list.set(list.current());
  const same = rowRenders.count("AgentLine");
  rowRenders.reset();
  await tick();
  const ticked = rowRenders.count("AgentLine");
  console.log(
    `SUBAGENT-LISTS section: one-item change=${change} parent same data=${same} tick=${ticked} (running rows: 2)`,
  );
  expect(change).toBe(1);
  expect(same).toBe(0);
  expect(ticked).toBeLessThanOrEqual(2);
  await list.unmount();
});

test("agents pill: one subagent's change, a parent render with the same subagents, a tick", async () => {
  const { AgentsPill } = await import("../src/agent-session/acpmux/subagents/AgentsPill");
  const tones: ReadonlyMap<string, number> = new Map();
  const list = await mount((agents) => <AgentsPill agents={agents} waiting={WAITING} tones={tones} onOpen={open} />);
  await act(async () => list.host.querySelector<HTMLButtonElement>(".acpmux-agents-pill")!.click());
  expect(list.host.querySelectorAll(".acpmux-agents-list__row").length).toBe(22);
  rowRenders.reset();
  await list.set(oneChanged(list.current()));
  const change = rowRenders.count("AgentIdentity");
  rowRenders.reset();
  await list.set(list.current());
  const same = rowRenders.count("AgentIdentity");
  rowRenders.reset();
  await tick();
  const ticked = rowRenders.count("AgentIdentity");
  const times = rowRenders.count("PillElapsed");
  console.log(
    `SUBAGENT-LISTS pill: one-item change=${change} parent same data=${same} tick rows=${ticked} tick time leaves=${times}`,
  );
  expect(change).toBe(1);
  expect(same).toBe(0);
  expect(ticked).toBe(0);
  // A row picked closes the list and calls back with its id.
  await act(async () => list.host.querySelector<HTMLButtonElement>(".acpmux-agents-list__row")!.click());
  expect(list.host.querySelector(".acpmux-agents-list")).toBeNull();
  await list.unmount();
});
