// l10n-allow-file: test fixture subagent names and commands, not shipped UI.
// Running subagents sit in one tray above the composer, never mid-transcript (Leo 2026-10-20:
// "put the subagent situation at the bottom of the chat and anchor"; subagents/runningTray.ts).
// - The transcript drops the group card where subagents started; a subagent that ended leaves one
//   line where it ended, with its name and how long it ran, a failure in the danger color.
// - The tray lists each running subagent (nested ones under their parent), background command and
//   chat the agent started: name, what it does now, its state and its time. Several get a header;
//   more than three fold.
// - It is the one place running background work shows: no "Running in background" row in the
//   transcript. Between turns a command shows only when acpmux's process registry says it runs; one
//   only the transcript knows (a peer's chat, whose end never arrived) does not pin the tray.
// - The tray's lines are the summary card's Subagents rows: one component (AgentLine.tsx).
import { afterAll, describe, expect, setSystemTime, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 10_000 });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { setPaneLanguage } = await import("../src/agent-session/acpmux/i18n");
const { SUBAGENTS } = await import("../src/agent-session/acpmux/subagents/subagentFold");
const { SUBAGENT_DONE } = await import("../src/agent-session/acpmux/subagents/subagentRows");
const { trayItems, withSubagentLines, configureSubagentTray } =
  await import("../src/agent-session/acpmux/subagents/runningTray");
const { SubagentTray, TRAY_OPEN_MAX } = await import("../src/agent-session/acpmux/subagents/SubagentTray");
const { SubagentStatusList } = await import("../src/agent-session/acpmux/summary/SubagentStatusList");
const { SubagentNavContext } = await import("../src/agent-session/acpmux/subagents/SubagentGroup");
const { backgroundCommands } = await import("../src/agent-session/acpmux/inspector/processes");
type BackgroundCommand = import("../src/agent-session/acpmux/inspector/processes").BackgroundCommand;
type StartedSession = import("../src/agent-session/acpmux/started/startedSessions").StartedSession;
type Row = import("../src/agent-session/acpmux/model").AcpmuxRow;
type Subagent = import("../src/agent-session/acpmux/subagents/subagentFold").Subagent;

afterAll(() => {
  setPaneLanguage("en");
  configureSubagentTray(true);
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});
setPaneLanguage("en");

const T0 = Date.UTC(2026, 9, 20, 9, 0, 0);
const at = (seconds: number) => T0 + seconds * 1000;
const agent = (id: string, fields: Partial<Subagent> = {}): Subagent => ({
  id,
  parent: null,
  name: id,
  state: "running",
  startedAt: at(10),
  ...fields,
});
const command = (id: string, fields: Partial<BackgroundCommand> = {}): BackgroundCommand => ({
  id,
  command: id,
  state: "running",
  startedAt: at(5),
  ...fields,
});
const NONE: StartedSession[] = [];
const row = (id: string, kind: string, seconds: number, fields: Partial<Row> = {}): Row => ({
  id,
  version: 1,
  at: at(seconds),
  kind,
  ...fields,
});

async function render(
  node: ReturnType<typeof createElement>,
): Promise<{ root: HTMLElement; done: () => Promise<void> }> {
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  await act(async () => root.render(node));
  return { root: host, done: async () => act(async () => root.unmount()) };
}

describe("the transcript keeps no running card", () => {
  const transcript = (agents: Subagent[]) => [
    row("u1", "user", 0, { text: "Review it" }),
    row("a1", "assistant", 5, { text: "Starting two reviewers." }),
    row(`${SUBAGENTS}-3`, SUBAGENTS, 10, { subagents: agents }),
    row("t1", "activity", 30, { items: [] }),
    row("a2", "assistant", 100, { text: "Both are back." }),
  ];

  test("a running subagent draws no row; the tray has it", () => {
    const rows = transcript([agent("Reviewer", { action: "Read src/app.ts" })]);
    const out = withSubagentLines(rows);
    expect(out.map((entry) => entry.kind)).toEqual(["user", "assistant", "activity", "assistant"]);
    const items = trayItems([agent("Reviewer", { action: "Read src/app.ts" })], [], NONE, true);
    expect(items.map((item) => item.id)).toEqual(["Reviewer"]);
  });

  test("a subagent that ended leaves one line where it ended, after the rows before its end", () => {
    const rows = transcript([
      agent("Reviewer", { state: "completed", endedAt: at(90) }),
      agent("Tester", { state: "failed", endedAt: at(40) }),
    ]);
    const out = withSubagentLines(rows);
    expect(out.map((entry) => entry.id)).toEqual([
      "u1",
      "a1",
      "t1",
      `${SUBAGENT_DONE}:Tester`,
      `${SUBAGENT_DONE}:Reviewer`,
      "a2",
    ]);
    // The rows around them are the same objects, and so is a line whose subagent did not change.
    expect(out[2]).toBe(rows[3]!);
    const cache = new Map();
    const first = withSubagentLines(rows, cache);
    const again = withSubagentLines([...rows], cache);
    expect(again[3]).toBe(first[3]!);
  });

  test("a transcript without subagents is returned as it is", () => {
    const rows = [row("u1", "user", 0), row("a1", "assistant", 5)];
    expect(withSubagentLines(rows)).toBe(rows);
  });

  test("the line names the subagent and how long it ran; a failure is marked failed", async () => {
    const rows = withSubagentLines(
      transcript([
        agent("Reviewer", { state: "completed", startedAt: at(10), endedAt: at(90) }),
        agent("Tester", { state: "failed", startedAt: at(10), endedAt: at(40) }),
      ]),
    ) as Row[];
    const opened: string[] = [];
    const { root, done } = await render(
      createElement(
        SubagentNavContext.Provider,
        { value: (id: string | undefined) => void opened.push(String(id)) },
        createElement(VirtualTranscript, { rows, onToggleActivity: () => {}, expanded: new Set<string>() }),
      ),
    );
    try {
      const lines = [...root.querySelectorAll<HTMLButtonElement>(".cv-subagent-done")];
      expect(lines.map((line) => [line.dataset.state, line.textContent])).toEqual([
        ["failed", "Subagent failed: Tester · 30s"],
        ["completed", "Subagent finished: Reviewer · 1m 20s"],
      ]);
      expect(root.querySelector(".cv-subagents")).toBeNull();
      await act(async () => lines[1]!.click());
      expect(opened).toEqual(["Reviewer"]);
    } finally {
      await done();
    }
  });
});

describe("the tray", () => {
  test("lists running subagents, nested ones under their parent, then running commands", () => {
    const agents = [
      agent("Tester", { startedAt: at(12) }),
      agent("Reviewer", { startedAt: at(10) }),
      agent("Scout", { parent: "Reviewer", startedAt: at(14) }),
      agent("Linter", { state: "completed", endedAt: at(20) }),
    ];
    const commands = [command("bg1", { command: "bun run dev" }), command("bg2", { state: "completed" })];
    const chats: StartedSession[] = [
      { sessionId: "c1", title: "Port the history page", state: "running" },
      { sessionId: "c2", title: "Draft the notes", state: "idle" },
    ];
    expect(
      trayItems(agents, commands, chats, true).map((item) => [item.id, item.kind === "agent" ? item.depth : -1]),
    ).toEqual([
      ["Reviewer", 0],
      ["Scout", 1],
      ["Tester", 0],
      ["bg1", -1],
      ["c1", -1],
    ]);
    // Between turns only background subagents still run; a foreground one left "running" pins nothing.
    const between = trayItems([...agents, agent("Watcher", { background: true })], commands, chats, false);
    expect(between.map((item) => item.id)).toEqual(["Watcher", "c1"]);
  });

  test("one running subagent is its line alone: name, what it does now, its time and state", async () => {
    const now = Date.now();
    const items = trayItems([agent("Explore the daemon", { startedAt: now - 80_000, action: "Bash" })], [], NONE, true);
    const opened: string[] = [];
    const { root, done } = await render(
      createElement(SubagentTray, {
        items,
        working: true,
        waiting: new Set<string>(),
        onOpen: (id: string) => opened.push(id),
      }),
    );
    try {
      expect(root.querySelector(".acpmux-running-tray__head")).toBeNull();
      const lines = [...root.querySelectorAll(".acpmux-running-tray .acpmux-agent-line")];
      expect(lines.length).toBe(1);
      const text = (selector: string) => lines[0]!.querySelector(selector)?.textContent;
      expect(text(".acpmux-summary-agent__name")).toBe("Explore the daemon");
      expect(text(".acpmux-summary-agent__kind")).toBe("Bash");
      expect(text(".acpmux-summary-agent__state")).toBe("Running");
      expect(text(".acpmux-agent-line__time")).toMatch(/^1m 2\ds$/);
      expect(lines[0]!.querySelector(".acpmux-lineage__icon")?.getAttribute("data-state")).toBe("running");
      await act(async () => lines[0]!.querySelector("button")!.click());
      expect(opened).toEqual(["Explore the daemon"]);
    } finally {
      await done();
    }
  });

  test("several get a header; past three they start folded", async () => {
    const now = Date.now();
    const few = trayItems(
      [agent("A", { startedAt: now - 5000 }), agent("B", { startedAt: now - 4000 })],
      [command("bg1", { command: "bun run dev", startedAt: now - 3000 })],
      NONE,
      true,
    );
    const shown = await render(
      createElement(SubagentTray, { items: few, working: true, waiting: new Set<string>(), onOpen: () => {} }),
    );
    try {
      const head = shown.root.querySelector<HTMLButtonElement>(".acpmux-running-tray__head")!;
      expect(head.getAttribute("aria-expanded")).toBe("true");
      expect(head.querySelector(".acpmux-running-tray__title")?.textContent).toBe("2 subagents running · 1 command");
      expect(shown.root.querySelectorAll(".acpmux-agent-line").length).toBe(3);
      // The header's time is its own, not a fourth line's.
      expect(shown.root.querySelectorAll(".acpmux-agent-line__time").length).toBe(3);
      expect(head.querySelector(".acpmux-running-tray__time")?.textContent).toMatch(/^[56]s$/);
      await act(async () => head.click());
      expect(shown.root.querySelectorAll(".acpmux-agent-line").length).toBe(0);
    } finally {
      await shown.done();
    }
    const many = trayItems(
      Array.from({ length: TRAY_OPEN_MAX + 1 }, (_, index) => agent(`Agent ${index}`, { startedAt: now - index })),
      [],
      NONE,
      true,
    );
    const folded = await render(
      createElement(SubagentTray, { items: many, working: true, waiting: new Set<string>(), onOpen: () => {} }),
    );
    try {
      const head = folded.root.querySelector<HTMLButtonElement>(".acpmux-running-tray__head")!;
      expect(head.getAttribute("aria-expanded")).toBe("false");
      expect(folded.root.querySelectorAll(".acpmux-agent-line").length).toBe(0);
      await act(async () => head.click());
      expect(folded.root.querySelectorAll(".acpmux-agent-line").length).toBe(TRAY_OPEN_MAX + 1);
    } finally {
      await folded.done();
    }
  });

  test("a subagent waiting on the person says so", async () => {
    const items = trayItems([agent("Reviewer", { startedAt: Date.now() })], [], NONE, true);
    const { root, done } = await render(
      createElement(SubagentTray, { items, working: true, waiting: new Set(["Reviewer"]), onOpen: () => {} }),
    );
    try {
      expect(root.querySelector(".acpmux-summary-agent__state")?.textContent).toBe("Waiting");
      expect(root.querySelector(".acpmux-agent-line")?.getAttribute("data-status")).toBe("waiting");
    } finally {
      await done();
    }
  });

  test("between turns a command only the transcript knows is not in the tray; the registry's is", () => {
    // A peer's chat: acpmux cannot list its registry, and the dev server's end never arrived.
    const transcript = [{ id: "call-dev", command: "bun run dev", state: "running" as const, startedAt: at(5) }];
    const peer = backgroundCommands([], transcript, false);
    expect(trayItems([], peer, NONE, true).map((item) => item.id)).toEqual(["call-dev"]);
    expect(trayItems([], peer, NONE, false)).toEqual([]);
    // The registry lists a watcher it runs: it shows between turns too, by its process.
    const processes = [
      { id: "s/1", toolCallId: "call-watch", command: "cargo watch", startedAt: at(6), state: "running" },
      { id: "s/2", toolCallId: "call-make", command: "make", startedAt: at(7), state: "exited" },
    ];
    const local = backgroundCommands(processes, transcript, false);
    expect(trayItems([], local, NONE, false).map((item) => item.id)).toEqual(["s/1"]);
  });

  test("between turns the header says it runs in the background; a line opens it, a process stops", async () => {
    const now = Date.now();
    const registry = command("s/1", {
      command: "cargo watch",
      processId: "s/1",
      toolCallId: "call-watch",
      startedAt: now,
    });
    const items = trayItems(
      [agent("Watcher", { background: true, startedAt: now })],
      [registry],
      [{ sessionId: "c1", title: "Port the history page", state: "running" }],
      false,
    );
    const opened: string[] = [];
    const stopped: string[] = [];
    const { root, done } = await render(
      createElement(SubagentTray, {
        items,
        working: false,
        waiting: new Set<string>(),
        onOpen: (id: string) => opened.push(`agent:${id}`),
        onOpenCommand: (entry: BackgroundCommand) => opened.push(`command:${entry.id}`),
        onOpenSession: (id: string) => opened.push(`chat:${id}`),
        stopProcess: async (id: string) => void stopped.push(id),
      }),
    );
    try {
      expect(root.querySelector(".acpmux-running-tray__title")?.textContent).toBe(
        "Running in background · 1 agent · 1 command · 1 session",
      );
      const lines = [...root.querySelectorAll<HTMLElement>(".acpmux-agent-line")];
      expect(lines.map((line) => line.querySelector(".acpmux-summary-agent__name")?.textContent)).toEqual([
        "Watcher",
        "cargo watch",
        "Port the history page",
      ]);
      for (const line of lines) await act(async () => line.querySelector<HTMLButtonElement>("button")!.click());
      expect(opened).toEqual(["agent:Watcher", "command:s/1", "chat:c1"]);
      await act(async () => lines[1]!.querySelector<HTMLButtonElement>(".acpmux-chat-inspector-stop")!.click());
      expect(stopped).toEqual(["s/1"]);
    } finally {
      await done();
    }
  });

  test("the transcript draws no Running in background row", async () => {
    const rows = [
      row("u1", "user", 0, { text: "Start the dev server" }),
      row("a1", "assistant", 5, { text: "It runs." }),
      row("backgroundWork", "backgroundWork", 5),
    ];
    const { root, done } = await render(
      createElement(VirtualTranscript, { rows, onToggleActivity: () => {}, expanded: new Set<string>() }),
    );
    try {
      expect(root.querySelector(".cv-bgwork")).toBeNull();
      expect(root.textContent).not.toContain("Running in background");
    } finally {
      await done();
    }
  });

  test("a hidden pane's tray clock rests and catches up when the pane shows", async () => {
    // The clock's interval is recorded instead of run, and the time moves by hand: no real waits.
    const intervals = new Set<number>();
    const realSet = globalThis.setInterval;
    const realClear = globalThis.clearInterval;
    let ids = 0;
    globalThis.setInterval = (() => {
      ids += 1;
      intervals.add(ids);
      return ids;
    }) as unknown as typeof setInterval;
    globalThis.clearInterval = ((id?: number) => void intervals.delete(id as number)) as typeof clearInterval;
    let visibility = "visible";
    Object.defineProperty(dom.window.document, "visibilityState", { configurable: true, get: () => visibility });
    const shown = (state: string) =>
      act(async () => {
        visibility = state;
        dom.window.document.dispatchEvent(new dom.window.Event("visibilitychange"));
      });
    setSystemTime(new Date(at(100)));
    const items = trayItems([agent("Reviewer", { startedAt: at(90) })], [], NONE, true);
    const { root, done } = await render(
      createElement(SubagentTray, { items, working: true, waiting: new Set<string>(), onOpen: () => {} }),
    );
    const time = () => root.querySelector(".acpmux-agent-line__time")?.textContent;
    try {
      expect(time()).toBe("10s");
      expect(intervals.size).toBe(1);
      await shown("hidden");
      expect(intervals.size).toBe(0);
      setSystemTime(new Date(at(130)));
      expect(time()).toBe("10s");
      await shown("visible");
      expect(time()).toBe("40s");
      expect(intervals.size).toBe(1);
    } finally {
      await done();
      setSystemTime();
      visibility = "visible";
      globalThis.setInterval = realSet;
      globalThis.clearInterval = realClear;
    }
  });

  test("the summary card's Subagents list draws the tray's own line", async () => {
    const { root, done } = await render(
      createElement(SubagentStatusList, {
        agents: [agent("Reviewer", { startedAt: Date.now() })],
        waiting: new Set<string>(),
        onOpen: () => {},
      }),
    );
    try {
      const line = root.querySelector(".acpmux-summary-agents .acpmux-agent-line");
      expect(line).not.toBeNull();
      expect(line!.querySelector(".acpmux-summary-agent__name")?.textContent).toBe("Reviewer");
      expect(line!.querySelector(".acpmux-summary-agent__state")?.textContent).toBe("Running");
    } finally {
      await done();
    }
  });
});
