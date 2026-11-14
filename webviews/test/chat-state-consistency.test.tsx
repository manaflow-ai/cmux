// l10n-allow-file: test fixtures.
// The chat's chips and cards say what the chat really runs, across a fork, a switch, a restore and
// a reconnect (Leo 2026-11-11: "switching models between chats, and then the permission state gets
// [messed up], the model picker state gets [messed up] ... We cannot have [nonsense] state"). Four
// invariants, each against the code the pane draws with (applySwitch, HarnessSwitch, liveAsk, the
// composer's chips, the held fork pick):
// 1. The model and effort shown are the session's, as acpmux reports them: a pick draws only until
//    the session answers it, and never past the chat it was made in.
// 2. The access chip names the mode the session reports: a pick the agent answered with another
//    mode, or a pick in another chat, never stays on it.
// 3. A permission card shows only while its chat can still be waiting on it, and never on a chat
//    the pane switched away from.
// 4. A held pick of another harness's model belongs to one chat and goes when the pane leaves it.
import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { AcpmuxPermission, AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import type { SwitchPort } from "../src/agent-session/acpmux/harnessSwitch";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "IS_REACT_ACT_ENVIRONMENT",
  "HTMLElement",
  "Element",
  "Node",
  "ShadowRoot",
  "MouseEvent",
  "KeyboardEvent",
  "Event",
  "CustomEvent",
  "customElements",
  "MutationObserver",
  "CSSStyleSheet",
  "DocumentFragment",
  "SVGElement",
  "HTMLTemplateElement",
  "localStorage",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "PointerEvent",
  "FocusEvent",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  Object.assign(dom.window, {
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
  });
  const w = dom.window as unknown as Record<string, unknown>;
  Object.assign(scope, Object.fromEntries(keys.map((key) => [key, w[key]])), {
    IS_REACT_ACT_ENVIRONMENT: true,
    PointerEvent: w.PointerEvent ?? w.MouseEvent,
    FocusEvent: w.FocusEvent ?? w.Event,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  });
  host = dom.window.document.getElementById("root")!;
});

afterEach(async () => {
  const { resetStartModesForTests, setStartModeSource } = await import("../src/agent-session/acpmux/startMode");
  setStartModeSource(undefined);
  resetStartModesForTests();
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
});

afterAll(async () => {
  for (let turn = 0; turn < 3; turn += 1) await new Promise((resolve) => setImmediate(resolve));
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const flush = () => act(async () => await new Promise((done) => setTimeout(done, 0)));

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;

const CLAUDE_MODES = [
  { id: "auto", name: "Auto" },
  { id: "default", name: "Ask before edits" },
  { id: "acceptEdits", name: "Accept edits" },
  { id: "bypassPermissions", name: "Bypass permissions" },
];

function summaryOf(sessionId: string, extra: Partial<Summary> = {}): Summary {
  return {
    sessionId,
    harness: "claude",
    model: "claude-opus-5-5",
    turnCount: 1,
    configOptions: [
      {
        id: "effort",
        name: "Effort",
        category: "thought_level",
        currentValue: "medium",
        options: [{ value: "low" }, { value: "medium" }, { value: "high" }],
      },
    ],
    modes: { currentModeId: "default", availableModes: CLAUDE_MODES },
    ...extra,
  } as Summary;
}

function snapshotOf(summary: Summary | undefined, extra: Partial<AcpmuxSnapshot> = {}): AcpmuxSnapshot {
  return {
    type: "snapshot",
    protocolVersion: 1,
    sessionId: summary?.sessionId,
    rows: [],
    sessions: [],
    connection: "test",
    isWorking: false,
    queue: [],
    canLoadOlder: false,
    catalog: [],
    summary,
    ...extra,
  } as unknown as AcpmuxSnapshot;
}

function ask(permissionId: string, extra: Partial<AcpmuxPermission> = {}): AcpmuxPermission {
  return {
    permissionId,
    title: "Run npm test",
    pending: true,
    options: [
      { id: "allow", name: "Allow", allow: true },
      { id: "deny", name: "Deny", allow: false },
    ],
    ...extra,
  };
}

/// A HarnessSwitch on a port whose agent answers `setModel` and `setConfig` when the test says.
async function liveSwitch(shown: () => { sessionId: string; harness?: string; model?: string }) {
  const { HarnessSwitch } = await import("../src/agent-session/acpmux/harnessSwitch");
  const answers: (() => void)[] = [];
  const later = () => new Promise<void>((resolve) => answers.push(resolve));
  const harnessSwitch = new HarnessSwitch();
  harnessSwitch.connect({
    turnRunning: () => false,
    shown: () => ({ ...shown(), empty: false }),
    create: async () => undefined,
    leave: () => undefined,
    open: async () => undefined,
    send: async () => undefined,
    setModel: later,
    setMode: async () => undefined,
    setConfig: later,
    discard: () => undefined,
    prewarm: () => undefined,
    prewarmSupported: () => false,
  } as unknown as SwitchPort);
  return {
    harnessSwitch,
    async answer() {
      while (answers.length) answers.shift()!();
      await Promise.resolve();
      await Promise.resolve();
    },
  };
}

/// The snapshot as App.tsx draws it: the client's, reconciled with the switch, the switch drawn
/// over it, then the permission card checked against the chat's state.
async function drawn(
  raw: AcpmuxSnapshot,
  harnessSwitch: import("../src/agent-session/acpmux/harnessSwitch").HarnessSwitch,
) {
  const { applySwitch } = await import("../src/agent-session/acpmux/harnessSwitch");
  const { liveAsk } = await import("../src/agent-session/acpmux/liveAsk");
  harnessSwitch.reconcile(raw);
  return liveAsk(applySwitch(raw, harnessSwitch.view(), raw.catalog));
}

const effortOf = (snapshot: AcpmuxSnapshot) =>
  snapshot.summary?.configOptions?.find((option) => option.id === "effort")?.currentValue;

describe("1. the model and effort shown are the session's", () => {
  test("a model pick draws at once, then gives way to the session's report", async () => {
    let model = "claude-opus-5-5";
    const { harnessSwitch, answer } = await liveSwitch(() => ({ sessionId: "s1", harness: "claude", model }));
    void harnessSwitch.pickModel("claude-sonnet-5-5", { sessionId: "s1", model });
    expect((await drawn(snapshotOf(summaryOf("s1", { model })), harnessSwitch)).summary?.model).toBe(
      "claude-sonnet-5-5",
    );
    model = "claude-sonnet-5-5";
    await answer();
    const after = await drawn(snapshotOf(summaryOf("s1", { model })), harnessSwitch);
    expect(after.summary?.model).toBe("claude-sonnet-5-5");
    expect(after.summary?.confirmedModel).toBeUndefined();
    expect(harnessSwitch.view().model).toBeUndefined();
  });

  test("a pick answered in one chat never draws over that chat's model after the pane showed another (fork, new chat, list pick)", async () => {
    const { harnessSwitch, answer } = await liveSwitch(() => ({ sessionId: "s1", harness: "claude" }));
    void harnessSwitch.pickModel("claude-sonnet-5-5", { sessionId: "s1", model: "claude-opus-5-5" });
    await answer();
    // The pane opens the fork (or another chat) before s1 reported the new model.
    const fork = await drawn(snapshotOf(summaryOf("s2", { model: "claude-haiku-5-5" })), harnessSwitch);
    expect(fork.summary?.model).toBe("claude-haiku-5-5");
    expect(harnessSwitch.view().model).toBeUndefined();
    // Back on s1, which still reports the model it runs: the chip names it, not the old pick.
    const back = await drawn(snapshotOf(summaryOf("s1", { model: "claude-opus-5-5" })), harnessSwitch);
    expect(back.summary?.model).toBe("claude-opus-5-5");
    expect(back.summary?.confirmedModel).toBeUndefined();
  });

  test("a reconnect (no chat in the snapshot yet) keeps a pick in flight; the restored chat's report settles it", async () => {
    const { harnessSwitch, answer } = await liveSwitch(() => ({ sessionId: "s1", harness: "claude" }));
    void harnessSwitch.pickModel("claude-sonnet-5-5", { sessionId: "s1", model: "claude-opus-5-5" });
    await drawn(snapshotOf(undefined, { connection: "connecting" }), harnessSwitch);
    expect(harnessSwitch.view().model?.model).toBe("claude-sonnet-5-5");
    await answer();
    const restored = await drawn(snapshotOf(summaryOf("s1", { model: "claude-sonnet-5-5" })), harnessSwitch);
    expect(restored.summary?.model).toBe("claude-sonnet-5-5");
    expect(harnessSwitch.view().model).toBeUndefined();
  });

  test("an answered model pick gives way to another model the session reports (changed elsewhere)", async () => {
    const { harnessSwitch, answer } = await liveSwitch(() => ({ sessionId: "s1", harness: "claude" }));
    void harnessSwitch.pickModel("claude-sonnet-5-5", { sessionId: "s1", model: "claude-opus-5-5" });
    await answer();
    const moved = await drawn(snapshotOf(summaryOf("s1", { model: "claude-haiku-5-5" })), harnessSwitch);
    expect(moved.summary?.model).toBe("claude-haiku-5-5");
    expect(harnessSwitch.view().model).toBeUndefined();
  });

  test("a pick not answered yet draws over an earlier pick's report landing on the way", async () => {
    const { harnessSwitch } = await liveSwitch(() => ({ sessionId: "s1", harness: "claude" }));
    void harnessSwitch.pickModel("claude-sonnet-5-5", { sessionId: "s1", model: "claude-opus-5-5" });
    void harnessSwitch.pickModel("claude-haiku-5-5", { sessionId: "s1", model: "claude-opus-5-5" });
    const between = await drawn(snapshotOf(summaryOf("s1", { model: "claude-sonnet-5-5" })), harnessSwitch);
    expect(between.summary?.model).toBe("claude-haiku-5-5");
  });

  test("an effort pick the agent answered gives way to the level the session reports", async () => {
    const { harnessSwitch, answer } = await liveSwitch(() => ({ sessionId: "s1", harness: "claude" }));
    harnessSwitch.pickConfig("effort", "high", { sessionId: "s1", current: "medium" });
    const now = await drawn(snapshotOf(summaryOf("s1")), harnessSwitch);
    expect(effortOf(now)).toBe("high");
    await answer();
    // Another window (or the CLI) set Low before this pick's report came: the chip says Low.
    const set = summaryOf("s1");
    set.configOptions![0]!.currentValue = "low";
    expect(effortOf(await drawn(snapshotOf(set), harnessSwitch))).toBe("low");
    expect(harnessSwitch.view().config).toBeUndefined();
  });

  test("an effort pick in one chat never draws on another, nor on the first again", async () => {
    const { harnessSwitch } = await liveSwitch(() => ({ sessionId: "s1", harness: "claude" }));
    harnessSwitch.pickConfig("effort", "high", { sessionId: "s1", current: "medium" });
    expect(effortOf(await drawn(snapshotOf(summaryOf("s2")), harnessSwitch))).toBe("medium");
    expect(effortOf(await drawn(snapshotOf(summaryOf("s1")), harnessSwitch))).toBe("medium");
  });

  test("a switch to another harness names that harness and its model, never the old chat's", async () => {
    const { applySwitch } = await import("../src/agent-session/acpmux/harnessSwitch");
    const raw = snapshotOf(
      summaryOf("s1", { modes: { currentModeId: "bypassPermissions", availableModes: CLAUDE_MODES } }),
      {
        catalog: [
          { id: "claude", name: "Claude Code", models: [{ id: "claude-opus-5-5", name: "Opus 5.5" }] },
          { id: "codex", name: "Codex", models: [{ id: "gpt-6-astra", name: "GPT-6 Astra" }] },
        ] as AcpmuxSnapshot["catalog"],
        permission: ask("p1"),
      },
    );
    const switched = applySwitch(raw, {
      intent: {
        id: 1,
        harness: "codex",
        phase: "starting",
        shown: true,
        queued: [],
        config: { model: "gpt-6-astra", options: {} },
      },
    });
    expect(switched.summary?.harness).toBe("codex");
    expect(switched.summary?.model).toBe("gpt-6-astra");
    // 2. The old harness's mode is not the new chat's: it names none until acpmux answers one.
    expect(switched.summary?.modes?.currentModeId).not.toBe("bypassPermissions");
    // 3. The old chat's ask does not ride along.
    expect(switched.permission).toBeUndefined();
  });
});

async function renderPickers(
  snapshot: AcpmuxSnapshot,
  onMode: (modeId: string) => void | Promise<unknown>,
  extra = {},
) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  root ??= createRoot(host);
  const client = new QueryClient();
  await act(async () => {
    root!.render(
      <QueryClientProvider client={client}>
        <ComposerPickers
          snapshot={snapshot}
          onModel={() => undefined}
          onMode={onMode}
          onEffort={() => undefined}
          showPlan={false}
          {...extra}
        />
      </QueryClientProvider>,
    );
  });
}

const chipText = () => (host.querySelector(".acpmux-mode .acpmux-mode-text")?.textContent ?? "").trim();
const item = (name: string) =>
  [...dom.window.document.querySelectorAll<HTMLElement>(".acpmux-access-item")].find((row) =>
    row.textContent?.includes(name),
  );

describe("2. the access chip names the session's mode", () => {
  test("a pick the agent answered with another mode shows the mode the session runs", async () => {
    const withMode = (mode: string) =>
      snapshotOf(summaryOf("s1", { modes: { currentModeId: mode, availableModes: CLAUDE_MODES } }));
    await renderPickers(withMode("default"), async () => undefined);
    expect(chipText()).toBe("Manual");
    const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
    await act(async () => void openPicker("Mode"));
    await act(async () => item("Accept edits")!.click());
    await flush();
    // Drawn at once, before the session reports.
    expect(chipText()).toBe("Accept edits");
    // The agent took the pick but runs Auto (it mapped it, or another window changed it).
    await renderPickers(withMode("auto"), async () => undefined);
    await flush();
    expect(chipText()).toBe("Auto");
  });

  test("a pick in one chat never shows on the chat the pane opens next, nor on the first again", async () => {
    const withMode = (sessionId: string, mode: string) =>
      snapshotOf(summaryOf(sessionId, { modes: { currentModeId: mode, availableModes: CLAUDE_MODES } }));
    // The agent never answers this pick (a fork opens first).
    await renderPickers(withMode("s1", "default"), () => new Promise(() => undefined));
    const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
    await act(async () => void openPicker("Mode"));
    await act(async () => item("Bypass permissions")!.click());
    await flush();
    expect(chipText()).toBe("Bypass permissions");
    await renderPickers(withMode("s2", "acceptEdits"), () => undefined);
    await flush();
    expect(chipText()).toBe("Accept edits");
    await renderPickers(withMode("s1", "default"), () => undefined);
    await flush();
    expect(chipText()).toBe("Manual");
  });

  test("a mode the new harness does not have is never shown under the old label", async () => {
    // A fork onto Codex reports Codex's modes: Claude's Bypass permissions is not among them.
    await renderPickers(
      snapshotOf(
        summaryOf("s2", {
          harness: "codex",
          family: "codex",
          model: "gpt-6-astra",
          modes: {
            currentModeId: "agent",
            availableModes: [
              { id: "read-only", name: "Read Only" },
              { id: "agent", name: "Agent" },
              { id: "agent-full-access", name: "Agent (full access)" },
            ],
          },
        } as Partial<Summary>),
      ),
      () => undefined,
    );
    // Codex's own name for the mode the fork reports.
    expect(chipText()).toBe("Ask for approval");
  });
});

describe("3. a permission card shows only while its chat can wait on it", () => {
  test("an ask kept past its turn (the chat reports idle, ready, closed or gone) draws no card", async () => {
    const { liveAsk } = await import("../src/agent-session/acpmux/liveAsk");
    for (const status of ["idle", "ready", "closed", "disconnected"]) {
      const shown = liveAsk(
        snapshotOf(summaryOf("s1", { status }), {
          permission: ask("p1"),
          permissionsWaiting: 1,
          permissionsQueued: [ask("p2")],
        }),
      );
      expect(shown.permission, status).toBeUndefined();
      expect(shown.permissionsWaiting, status).toBeUndefined();
      expect(shown.permissionsQueued, status).toBeUndefined();
    }
  });

  test("an ask of a chat that runs, waits on it, works, or has not reported a status yet stays", async () => {
    const { liveAsk } = await import("../src/agent-session/acpmux/liveAsk");
    const cases: AcpmuxSnapshot[] = [
      snapshotOf(summaryOf("s1", { status: "running" }), { permission: ask("p1") }),
      snapshotOf(summaryOf("s1", { status: "waiting" }), { permission: ask("p1") }),
      snapshotOf(summaryOf("s1"), { permission: ask("p1") }),
      snapshotOf(summaryOf("s1", { status: "idle" }), { permission: ask("p1"), isWorking: true }),
    ];
    // The same snapshot: nothing redraws when nothing is dropped.
    for (const snapshot of cases) expect(liveAsk(snapshot)).toBe(snapshot);
  });

  test("an answered ask (no longer pending) is left as it is", async () => {
    const { liveAsk } = await import("../src/agent-session/acpmux/liveAsk");
    const snapshot = snapshotOf(summaryOf("s1", { status: "idle" }), { permission: ask("p1", { pending: false }) });
    expect(liveAsk(snapshot)).toBe(snapshot);
  });

  test("a switch shown before its chat opens carries no ask of the chat it left", async () => {
    const { harnessSwitch } = await liveSwitch(() => ({ sessionId: "s1", harness: "claude" }));
    const { applySwitch } = await import("../src/agent-session/acpmux/harnessSwitch");
    const raw = snapshotOf(summaryOf("s1", { status: "waiting" }), { permission: ask("p1") });
    expect(applySwitch(raw, harnessSwitch.view()).permission?.permissionId).toBe("p1");
    const shown = applySwitch(raw, {
      intent: { id: 1, harness: "codex", phase: "starting", shown: true, queued: [], config: { options: {} } },
    });
    expect(shown.permission).toBeUndefined();
  });
});

describe("4. a held pick belongs to one chat", () => {
  test("a held pick is per chat: another chat's send never forks with it", async () => {
    const { holdFork, heldFork, clearHeldFork } = await import("../src/agent-session/acpmux/forkHold");
    holdFork({ sessionId: "s1", harness: "codex", model: "gpt-6-astra" });
    expect(heldFork("s2")).toBeUndefined();
    expect(heldFork("s1")?.model).toBe("gpt-6-astra");
    clearHeldFork("s1");
    expect(heldFork("s1")).toBeUndefined();
  });

  test("the pane leaving the chat (a fork, a new chat, another chat) drops its held pick", async () => {
    const { holdFork, heldFork } = await import("../src/agent-session/acpmux/forkHold");
    const started = (sessionId: string) =>
      snapshotOf(summaryOf(sessionId), {
        rows: [{ id: "u1", version: 1, kind: "user", text: "hi" }] as AcpmuxSnapshot["rows"],
        canFork: true,
      });
    await renderPickers(started("s1"), () => undefined, { fork: true });
    holdFork({ sessionId: "s1", harness: "codex", model: "gpt-6-astra" });
    expect(heldFork("s1")).toBeDefined();
    await renderPickers(started("s2"), () => undefined, { fork: true });
    expect(heldFork("s1")).toBeUndefined();
    // Back on s1: nothing held comes back.
    await renderPickers(started("s1"), () => undefined, { fork: true });
    expect(heldFork("s1")).toBeUndefined();
  });

  test("the composer closing drops the held pick", async () => {
    const { holdFork, heldFork } = await import("../src/agent-session/acpmux/forkHold");
    await renderPickers(
      snapshotOf(summaryOf("s1"), {
        rows: [{ id: "u1", version: 1, kind: "user", text: "hi" }] as AcpmuxSnapshot["rows"],
        canFork: true,
      }),
      () => undefined,
      { fork: true },
    );
    holdFork({ sessionId: "s1", harness: "codex", model: "gpt-6-astra" });
    act(() => root?.unmount());
    root = undefined;
    expect(heldFork("s1")).toBeUndefined();
  });
});
