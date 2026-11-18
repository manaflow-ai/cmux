// l10n-allow-file: test fixture subagent names, not shipped UI.
// Session Info's Subagents rows draw again only when what they draw changed. Every snapshot acpmux
// sends is new objects, and a running subagent's progress moves fields no row draws
// (`progressVersion`, `quietSince` short of the idle window). At 1,000 subagents, three fresh
// snapshots that move only those draw no line; one more that renames a single subagent draws its
// line alone. Counted from React's commits (support/rowRenders.ts).
import { createRoot, rowRenders } from "./support/rowRenders";
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
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
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const N = 1_000;
const NOW = Date.now();

/// Three running subagents (quiet for a few seconds, far from idle) and N - 3 ended ones.
const fleet = (): Subagent[] => [
  ...Array.from({ length: 3 }, (_, i) => ({
    id: `run-${i}`,
    parent: null,
    name: `Runner ${i}`,
    task: `Run ${i}`,
    state: "running",
    startedAt: NOW - 60_000 - i * 1_000,
    progressVersion: 1,
    quietSince: NOW - 5_000,
  })),
  ...Array.from({ length: N - 3 }, (_, i) => ({
    id: `done-${i}`,
    parent: null,
    name: `Done ${i}`,
    task: `Task ${i}`,
    state: i % 50 === 0 ? "failed" : "completed",
    startedAt: NOW - 600_000 - i * 1_000,
    endedAt: NOW - 300_000 - i * 1_000,
    progressVersion: 1,
  })),
];

/// The next snapshot: every object new, the fields no row draws moved on.
const nextSnapshot = (agents: Subagent[], step: number): Subagent[] =>
  structuredClone(agents).map((agent) => ({
    ...agent,
    progressVersion: (agent.progressVersion ?? 0) + step,
    ...(agent.state === "running" ? { quietSince: NOW - 5_000 + step * 100 } : {}),
  }));

test("Session Info Subagents at N = 1,000: fresh snapshots draw no line; one rename draws one", async () => {
  const { SubagentsSection } = await import("../src/agent-session/acpmux/session-info/SubagentsSection");
  const waiting: ReadonlySet<string> = new Set();
  const open = (_id: string) => {};
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root: Root = createRoot(host);
  const show = (agents: Subagent[]) =>
    act(async () => root.render(<SubagentsSection agents={agents} waiting={waiting} onOpen={open} />));
  let agents = fleet();
  await show(agents);
  // The ended lines' row opens their list.
  await act(async () => host.querySelector<HTMLElement>(".acpmux-session-info-subagents__ended")?.click());
  const lines = host.querySelectorAll(".acpmux-agent-line").length;
  rowRenders.reset();
  for (let step = 1; step <= 3; step++) await show((agents = nextSnapshot(agents, step)));
  const fresh = rowRenders.count("SubagentLineRow");
  rowRenders.reset();
  await show(
    nextSnapshot(agents, 4).map((agent) => (agent.id === "done-3" ? { ...agent, name: "Done 3, renamed" } : agent)),
  );
  const change = rowRenders.count("SubagentLineRow");
  console.log(`SUBAGENT-ROWS ${JSON.stringify({ fresh, change })} (subagents: ${N}, drawn lines: ${lines})`);
  expect(fresh).toBe(0);
  expect(change).toBe(1);
  expect(host.textContent).toContain("Done 3, renamed");
  await act(async () => root.unmount());
  host.remove();
});
