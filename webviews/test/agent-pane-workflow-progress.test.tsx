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
const { rememberTrayOpen } = await import("../src/agent-session/acpmux/subagents/trayFoldMemory");
// A tray of more than one line starts folded and builds no rows (cmux#29250); these tests read rows.
for (const chat of [fixtures.SESSION_ID, "late-root-tray"]) rememberTrayOpen(chat, true);
// Workflows are on by default (cmux#30192): a running workflow is its transcript card, not a tray
// row. These tests cover the tray and Session Info lines, so they turn workflows off as the app's
// `workflowLabs` push would, as the gallery's tray workflow-progress state does.
const mountApp = async (root: { render(node: unknown): void }) => {
  await act(async () => root.render(<AcpmuxApp />));
  await act(async () =>
    (
      dom.window as unknown as { cmuxAcpmuxBridge?: { applyWorkflowLabs?(on: boolean): void } }
    ).cmuxAcpmuxBridge?.applyWorkflowLabs?.(false),
  );
};
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
      await mountApp(root);
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
      // The tray's rows say no tokens (cmux#29608); the counts are what the usage update brings.
      expect(first!.querySelector(".acpmux-agent-line__progress")?.textContent).not.toContain("tokens");
      expect(first!.textContent).toContain("1/3 agents");
      expect(first!.textContent).toContain("1 failed");
      expect(second!.innerHTML).toBe(before);
      expect(records).toHaveLength(0);
      for (const row of rows()) {
        const button = row.querySelector(".acpmux-agent-line__button")!;
        expect(button.querySelectorAll(".acpmux-agent-line__time")).toHaveLength(1);
        // The row's own trailing tracks (subagent-tray-trailing.test.ts owns their order): a progress
        // update leaves Stop's track and the chevron last.
        const trailing = [...button.children].slice(-2).map((node) => node.className);
        expect(trailing).toEqual(["acpmux-agent-line__stop-track", "acpmux-agent-line__chevron"]);
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
    const first = { ...agents[0]!, tokens: 42_000, agents: { started: 3, done: 1 } };
    const second = { ...agents[0]!, id: "workflow-session-b", tokens: 84_000, agents: { started: 3, done: 2 } };
    await mountApp(root);
    await act(async () => receive(snapshot([first], [], "gallery-session-a")));
    expect(dom.window.document.querySelector(".acpmux-agent-line__progress")?.textContent).toBe("1/3 agents");
    await act(async () => receive(snapshot([second], [], "gallery-session-b")));
    expect(dom.window.document.querySelector(".acpmux-agent-line__progress")?.textContent).toBe("2/3 agents");
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
  const first = { ...agents[0]!, tokens: 42_000, agents: { started: 3, done: 1 } };
  const updated = { ...first, tokens: 84_000, agents: { started: 3, done: 2 } };
  const versioned = (items: Subagent[], changed: Subagent[] = []) => ({
    ...snapshot(items, changed),
    subagentStructureVersion: 1,
  });
  const progress = () => dom.window.document.querySelector(".acpmux-agent-line__progress")?.textContent;
  try {
    await mountApp(root);
    await act(async () => receive(versioned([first])));
    expect(progress()).toBe("1/3 agents");
    await act(async () => receive(versioned([updated], [updated])));
    expect(progress()).toBe("2/3 agents");
    await act(async () => receive(versioned([updated])));
    expect(progress()).toBe("2/3 agents");
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
    const first = { ...agents[0]!, tokens: 42_000, agents: { started: 3, done: 1 } };
    const updated = { ...first, tokens: 84_000, agents: { started: 3, done: 2 } };
    await mountApp(root);
    await act(async () => receive(snapshot([first], [], "compatibility-session")));
    expect(dom.window.document.querySelector(".acpmux-agent-line__progress")?.textContent).toBe("1/3 agents");
    await act(async () => receive(snapshot([updated], [], "compatibility-session")));
    expect(dom.window.document.querySelector(".acpmux-agent-line__progress")?.textContent).toBe("2/3 agents");
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
    await mountApp(root);
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

for (const surface of ["tray", "inspector"] as const)
  test(`late root identification retires phantom progress from the ${surface}`, async () => {
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
    const fold = new SubagentFold();
    const items = [
      { ...agents[0]!, id: "root-native", name: "Owning chat", tokens: 9000 },
      { ...agents[0]!, id: "worker", name: "Real worker", tokens: 42000 },
      { ...agents[0]!, id: "grandchild", name: "Real grandchild", parent: "worker", tokens: 21000 },
    ];
    fold.reduce(
      { seq: 1, at: Date.now(), msg: { params: { _meta: { acpmux: { subagents: items } } } } },
      { sessionUpdate: "subagent_spawned" },
    );
    const publish = () => {
      const next = snapshot(fold.all(), [], `late-root-${surface}`);
      next.subagentStructureVersion = fold.progressSource.structureVersion;
      markAgentProgressSource(next.rows, fold.progressSource);
      return next;
    };
    const root = createRoot(dom.window.document.getElementById("root")!);
    const container = () =>
      dom.window.document.querySelector(surface === "tray" ? ".acpmux-running-tray" : "aside.acpmux-session-info");
    try {
      await mountApp(root);
      await act(async () => receive(publish()));
      if (surface === "inspector")
        await act(async () => {
          (
            dom.window as unknown as {
              cmuxAcpmuxBridge: { applyHeaderState(state: unknown): void };
            }
          ).cmuxAcpmuxBridge.applyHeaderState({ inspector: true, version: 2 });
        });
      expect(container()?.textContent).toContain("Owning chat");
      const version = fold.progressSource.structureVersion;
      const workerProgress = fold.progressSource.get("worker");
      const grandchildProgress = fold.progressSource.get("grandchild");
      fold.setRoot("root-native");
      // No further agent event: the late summary alone must invalidate App's retained list.
      await act(async () => receive(publish()));
      expect(container()).not.toBeNull();
      expect(container()!.textContent).not.toContain("Owning chat");
      expect(container()!.textContent).toContain("Real worker");
      expect(container()!.textContent).toContain("Real grandchild");
      expect(fold.all().map(({ id }) => id)).toEqual(["worker", "grandchild"]);
      expect(fold.progressSource.has("root-native")).toBe(false);
      expect(fold.progressSource.structureVersion).toBeGreaterThan(version);
      expect(fold.progressSource.get("worker")).toBe(workerProgress);
      expect(fold.progressSource.get("grandchild")).toBe(grandchildProgress);
      expect(fold.progressSource.takeChangedProgress()).not.toHaveProperty("root-native");
    } finally {
      await act(async () => root.unmount());
    }
  });
