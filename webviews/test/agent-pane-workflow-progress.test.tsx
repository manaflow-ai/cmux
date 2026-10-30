// l10n-allow-file: test fixture page titles, not shipped UI.
// A render tool call's card in the real pane (AcpmuxApp on a stand-in for the app's pane bridge, as
// the gallery's agent pane host mounts it): Open shows the page in the side panel, as a
// ```cmux-render fence's card does (cx-ncc.94), and a call with no title reads the page's <title>.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "cmux-agent://pane/index.html",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  location: dom.window.location,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  Event: dom.window.Event,
  KeyboardEvent: dom.window.KeyboardEvent,
  MouseEvent: dom.window.MouseEvent,
  customElements: dom.window.customElements,
  MutationObserver: dom.window.MutationObserver,
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
(dom.window as unknown as { matchMedia: unknown }).matchMedia = replacements.matchMedia;
// jsdom has no layout. A tall viewport mounts every row of this small chat.
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 10_000 });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const fixtures = await import("../src/gallery/fixtures/acpmux");
const { AcpmuxApp } = await import("../src/agent-session/acpmux/App");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});


const { configureSubagentTray } = await import("../src/agent-session/acpmux/subagents/runningTray");
const { AgentProgressStore } = await import("../src/agent-session/acpmux/subagents/agentProgressStore");
type Subagent = import("../src/agent-session/acpmux/subagents/subagentFold").Subagent;
const agents: Subagent[] = ["workflow-a", "workflow-b"].map((id) => ({
  id, name: id, parent: null, state: "running", kind: "workflow", startedAt: Date.now(),
  tokens: 1000, agents: { started: 3, done: 0 },
}));
const snapshot = (items: Subagent[]) => fixtures.chat([
  fixtures.user("Review both modules", 2),
  fixtures.row("subagents", 1, { subagents: items }),
], { isWorking: true });
const receive = (value: unknown) => (dom.window as unknown as {
  cmuxAcpmuxBridge?: { receive(value: unknown): void };
}).cmuxAcpmuxBridge?.receive(value);

test("App delivers usage-only snapshots to one workflow row without replacing its sibling", async () => {
  configureSubagentTray(true);
  (dom.window as unknown as { webkit: unknown }).webkit = {
    messageHandlers: { agentSession: { postMessage(message: { method?: string }) {
      if (message.method === "ready") return Promise.resolve({ ok: true,
        value: { protocolVersion: 1, transport: "preview", machineName: "Mac" } });
      return Promise.resolve({ ok: true, value: null });
    } } },
  };
  const root = createRoot(dom.window.document.getElementById("root")!);
  try {
    await act(async () => root.render(<AcpmuxApp />));
    await act(async () => receive(snapshot(structuredClone(agents))));
    const rows = () => [...dom.window.document.querySelectorAll(".acpmux-running-tray .acpmux-agent-line")];
    expect(rows()).toHaveLength(2);
    const [first, second] = rows();
    const before = second!.innerHTML;
    const records: MutationRecord[] = [];
    const observer = new dom.window.MutationObserver((batch) => records.push(...batch));
    observer.observe(second!, { subtree: true, childList: true, characterData: true });
    const updated = structuredClone(agents);
    updated[0]!.tokens = 42000;
    updated[0]!.agents = { started: 3, done: 1, failed: 1, queued: 2 };
    await act(async () => receive(snapshot(updated)));
    observer.disconnect();
    expect(rows()[0]).toBe(first);
    expect(rows()[1]).toBe(second);
    expect(first!.querySelector(".acpmux-agent-line__progress")?.textContent).toContain("subagents.tokens");
    expect(first!.textContent).toContain("1/3 agents");
    expect(first!.textContent).toContain("1 failed");
    expect(second!.innerHTML).toBe(before);
    expect(records).toHaveLength(0);
    for (const row of rows()) {
      const button = row.querySelector(".acpmux-agent-line__button")!;
      expect(button.querySelectorAll(".acpmux-agent-line__time")).toHaveLength(1);
      const trailing = [...button.children].slice(-3).map((node) => node.className);
      expect(trailing).toEqual([
        "acpmux-agent-line__status",
        "acpmux-summary-meta acpmux-agent-line__time",
        "acpmux-agent-line__chevron",
      ]);
    }
  } finally { await act(async () => root.unmount()); }
});

test("progress source notifies only the changed agent and cleans subscriptions", () => {
  const store = new AgentProgressStore(agents);
  let a = 0, b = 0;
  const offA = store.subscribe(agents[0]!.id, () => a++);
  const offB = store.subscribe(agents[1]!.id, () => b++);
  const originalB = store.get(agents[1]!.id);
  store.update([{ ...agents[0]!, tokens: 42000 }, { ...agents[1]! }]);
  expect([a, b]).toEqual([1, 0]);
  expect(store.get(agents[1]!.id)).toBe(originalB);
  offA(); offB();
  store.update([]);
  expect([a, b]).toEqual([1, 0]);
});
