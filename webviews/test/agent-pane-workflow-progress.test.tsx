// l10n-allow-file: test fixture page titles, not shipped UI.
// Workflow progress traverses the real App memo boundary; unchanged siblings stay untouched.
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
const { AgentProgressStore, markAgentProgressSource } =
  await import("../src/agent-session/acpmux/subagents/agentProgressSource");
const { SubagentFold } = await import("../src/agent-session/acpmux/subagents/subagentFold");
type Subagent = import("../src/agent-session/acpmux/subagents/subagentFold").Subagent;
const agents: Subagent[] = ["workflow-a", "workflow-b"].map((id) => ({
  id,
  name: id,
  parent: null,
  state: "running",
  kind: "workflow",
  startedAt: Date.now(),
  tokens: 1000,
  agents: { started: 3, done: 0 },
}));
const snapshot = (items: Subagent[], changed: readonly Subagent[] = [], sessionId = fixtures.SESSION_ID) =>
  fixtures.chat([fixtures.user("Review both modules", 2), fixtures.row("subagents", 1, { subagents: items })], {
    sessionId,
    isWorking: true,
    ...(changed.length > 0
      ? {
          subagentProgress: Object.fromEntries(
            changed.map((agent) => [
              agent.id,
              {
                agents: agent.agents,
                tokens: agent.tokens,
                toolUses: agent.toolUses,
              },
            ]),
          ),
        }
      : {}),
  });
const receive = (value: unknown) =>
  (
    dom.window as unknown as {
      cmuxAcpmuxBridge?: { receive(value: unknown): void };
    }
  ).cmuxAcpmuxBridge?.receive(value);

for (const producer of [false, true])
  test(`App delivers usage-only snapshots to one workflow row (${producer ? "direct producer" : "bridge"})`, async () => {
    const fold = new SubagentFold();
    let seq = 0;
    let bridgeSnapshot = 0;
    const publish = (items: Subagent[]) => {
      if (!producer) {
        // The bridge protocol publishes a keyed progress delta alongside its full row snapshot.
        // This keeps the compatibility path on the same per-agent update contract as direct mode.
        return snapshot(items, bridgeSnapshot++ === 0 ? [] : [items[0]!]);
      }
      const update = { sessionUpdate: seq === 0 ? "subagent_spawned" : "subagent_progress" };
      fold.reduce({ seq: ++seq, at: Date.now(), msg: { params: { _meta: { acpmux: { subagents: items } } } } }, update);
      const next = fixtures.chat([fixtures.user("Review both modules", 2), ...fold.takeRows()], { isWorking: true });
      markAgentProgressSource(next.rows, fold.progressSource);
      return next;
    };
    configureSubagentTray(true);
    (dom.window as unknown as { webkit: unknown }).webkit = {
      messageHandlers: {
        agentSession: {
          postMessage(message: { method?: string }) {
            if (message.method === "ready")
              return Promise.resolve({
                ok: true,
                value: { protocolVersion: 1, transport: "preview", machineName: "Mac" },
              });
            return Promise.resolve({ ok: true, value: null });
          },
        },
      },
    };
    const root = createRoot(dom.window.document.getElementById("root")!);
    try {
      await act(async () => root.render(<AcpmuxApp />));
      await act(async () => receive(publish(structuredClone(agents))));
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
      const version = fold.progressSource.structureVersion;
      await act(async () => receive(publish(producer ? [updated[0]!] : updated)));
      if (producer) expect(fold.progressSource.structureVersion).toBe(version);
      observer.disconnect();
      expect(rows()[0]).toBe(first);
      expect(rows()[1]).toBe(second);
      expect(first!.querySelector(".acpmux-agent-line__progress")?.textContent).toContain("42K tokens");
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
    } finally {
      await act(async () => root.unmount());
    }
  });

test("bridge repopulates progress when switching sessions", async () => {
  configureSubagentTray(true);
  (dom.window as unknown as { webkit: unknown }).webkit = {
    messageHandlers: {
      agentSession: {
        postMessage(message: { method?: string }) {
          if (message.method === "ready")
            return Promise.resolve({
              ok: true,
              value: { protocolVersion: 1, transport: "preview", machineName: "Mac" },
            });
          return Promise.resolve({ ok: true, value: null });
        },
      },
    },
  };
  const root = createRoot(dom.window.document.getElementById("root")!);
  try {
    const first = { ...agents[0]!, tokens: 42_000 };
    const second = { ...agents[0]!, id: "workflow-session-b", tokens: 84_000 };
    await act(async () => root.render(<AcpmuxApp />));
    await act(async () => receive(snapshot([first], [], "gallery-session-a")));
    expect(dom.window.document.querySelector(".acpmux-agent-line__progress")?.textContent).toContain("42K tokens");
    await act(async () => receive(snapshot([second], [], "gallery-session-b")));
    expect(dom.window.document.querySelector(".acpmux-agent-line__progress")?.textContent).toContain("84K tokens");
  } finally {
    await act(async () => root.unmount());
  }
});

test("versioned bridge snapshots retain progress when an unrelated snapshot omits the delta", async () => {
  configureSubagentTray(true);
  (dom.window as unknown as { webkit: unknown }).webkit = {
    messageHandlers: {
      agentSession: {
        postMessage(message: { method?: string }) {
          if (message.method === "ready")
            return Promise.resolve({
              ok: true,
              value: { protocolVersion: 1, transport: "preview", machineName: "Mac" },
            });
          return Promise.resolve({ ok: true, value: null });
        },
      },
    },
  };
  const root = createRoot(dom.window.document.getElementById("root")!);
  const first = { ...agents[0]!, tokens: 42_000 };
  const updated = { ...first, tokens: 84_000, agents: { started: 3, done: 2 } };
  const versioned = (items: Subagent[], changed: Subagent[] = []) => ({
    ...snapshot(items, changed),
    subagentStructureVersion: 1,
  });
  const progress = () => dom.window.document.querySelector(".acpmux-agent-line__progress")?.textContent;
  try {
    await act(async () => root.render(<AcpmuxApp />));
    await act(async () => receive(versioned([first])));
    expect(progress()).toContain("42K tokens");
    await act(async () => receive(versioned([updated], [updated])));
    expect(progress()).toContain("84K tokens");
    await act(async () => receive(versioned([updated])));
    expect(progress()).toContain("84K tokens");
    expect(progress()).toContain("2/3 agents");
  } finally {
    await act(async () => root.unmount());
  }
});

test("compatibility snapshots without a progress delta refresh the row from its latest agent", async () => {
  configureSubagentTray(true);
  (dom.window as unknown as { webkit: unknown }).webkit = {
    messageHandlers: {
      agentSession: {
        postMessage(message: { method?: string }) {
          if (message.method === "ready")
            return Promise.resolve({
              ok: true,
              value: { protocolVersion: 1, transport: "preview", machineName: "Mac" },
            });
          return Promise.resolve({ ok: true, value: null });
        },
      },
    },
  };
  const root = createRoot(dom.window.document.getElementById("root")!);
  try {
    const first = { ...agents[0]!, tokens: 42_000 };
    const updated = { ...first, tokens: 84_000, agents: { started: 3, done: 2 } };
    await act(async () => root.render(<AcpmuxApp />));
    await act(async () => receive(snapshot([first], [], "compatibility-session")));
    expect(dom.window.document.querySelector(".acpmux-agent-line__progress")?.textContent).toContain("42K tokens");
    await act(async () => receive(snapshot([updated], [], "compatibility-session")));
    expect(dom.window.document.querySelector(".acpmux-agent-line__progress")?.textContent).toContain("84K tokens");
    expect(dom.window.document.querySelector(".acpmux-agent-line__progress")?.textContent).toContain("2/3 agents");
  } finally {
    await act(async () => root.unmount());
  }
});

test("a rebuilt producer source refreshes rows even when its structure counter restarts", async () => {
  configureSubagentTray(true);
  (dom.window as unknown as { webkit: unknown }).webkit = {
    messageHandlers: {
      agentSession: {
        postMessage(message: { method?: string }) {
          if (message.method === "ready")
            return Promise.resolve({
              ok: true,
              value: { protocolVersion: 1, transport: "preview", machineName: "Mac" },
            });
          return Promise.resolve({ ok: true, value: null });
        },
      },
    },
  };
  const root = createRoot(dom.window.document.getElementById("root")!);
  const direct = (name: string, tokens: number) => {
    const store = new AgentProgressStore([{ ...agents[0]!, name, tokens }]);
    const next = fixtures.chat(
      [
        fixtures.user("Review the module", 2),
        fixtures.row("subagents", 1, {
          subagents: [{ ...agents[0]!, name, tokens }],
        }),
      ],
      { isWorking: true, subagentStructureVersion: store.structureVersion },
    );
    markAgentProgressSource(next.rows, store);
    return next;
  };
  try {
    await act(async () => root.render(<AcpmuxApp />));
    await act(async () => receive(direct("First producer", 42_000)));
    expect(dom.window.document.querySelector(".acpmux-agent-line__button")?.textContent).toContain("First producer");
    await act(async () => receive(direct("Rebuilt producer", 84_000)));
    expect(dom.window.document.querySelector(".acpmux-agent-line__button")?.textContent).toContain("Rebuilt producer");
  } finally {
    await act(async () => root.unmount());
  }
});

test("progress source notifies only the changed agent and cleans subscriptions", () => {
  const store = new AgentProgressStore(agents);
  let a = 0,
    b = 0;
  const offA = store.subscribe(agents[0]!.id, () => a++);
  const offB = store.subscribe(agents[1]!.id, () => b++);
  const originalB = store.get(agents[1]!.id);
  store.update([{ ...agents[0]!, tokens: 42000 }, { ...agents[1]! }]);
  expect([a, b]).toEqual([1, 0]);
  expect(store.get(agents[1]!.id)).toBe(originalB);
  offA();
  offB();
  store.remove(agents[0]!.id);
  store.remove(agents[1]!.id);
  expect([a, b]).toEqual([1, 0]);
});

test("one usage event touches one source entry regardless of sibling count", () => {
  for (const count of [10, 1000]) {
    const fold = new SubagentFold();
    const update = { sessionUpdate: "subagent_spawned" };
    const entries = Array.from({ length: count }, (_, i) => ({ ...agents[0]!, id: `agent-${i}` }));
    const event = (seq: number, items: Subagent[]) => ({
      seq,
      at: seq,
      msg: { params: { _meta: { acpmux: { subagents: items } } } },
    });
    fold.reduce(event(1, entries), update);
    const source = fold.progressSource;
    const version = source.structureVersion;
    let touches = 0;
    const original = source.updateAgent.bind(source);
    source.updateAgent = (agent) => {
      touches++;
      original(agent);
    };
    fold.reduce(event(2, [{ ...entries[0]!, tokens: 42000 }]), { sessionUpdate: "subagent_progress" });
    expect(touches).toBe(1);
    expect(source.structureVersion).toBe(version);
    expect(source.get("agent-0").tokens).toBe(42000);
    console.log(
      `progress-update agents=${count} source_entries=${touches} structural_rebuilds=${source.structureVersion - version}`,
    );
  }
});
