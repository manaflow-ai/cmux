// l10n-allow-file: test fixture subagent names and commands, not shipped UI.
// Running subagents sit in one tray above the composer, never mid-transcript (Leo 2026-10-20:
// "put the subagent situation at the bottom of the chat and anchor"; subagents/runningTray.ts).
// - The transcript drops the group card where subagents started; a subagent that ended leaves one
//   line where it ended, with its name and how long it ran, a failure in the danger color.
// - The tray lists each running subagent (nested ones under their parent), background command and
//   chat the agent started: name, what it does now, its state and its time. Several get a header;
//   more than three keep a bounded set of status cards with View all.
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
const { trayItems, finishedTrayItems, withSubagentLines, configureSubagentTray } =
  await import("../src/agent-session/acpmux/subagents/runningTray");
const { SubagentTray, TRAY_OPEN_MAX } = await import("../src/agent-session/acpmux/subagents/SubagentTray");
const { SubagentStatusList } = await import("../src/agent-session/acpmux/summary/SubagentStatusList");
const { SubagentNavContext } = await import("../src/agent-session/acpmux/subagents/SubagentGroup");
const { TurnActionsContext } = await import("../src/agent-session/acpmux/conversation/turnActions");
const { backgroundCommands, commandLabel } = await import("../src/agent-session/acpmux/inspector/processes");
const { runningBackgroundTasks } = await import("../src/agent-session/acpmux/summary/sessionSummary");
const { SubagentFold } = await import("../src/agent-session/acpmux/subagents/subagentFold");
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

async function render(node: ReturnType<typeof createElement>): Promise<{
  root: HTMLElement;
  show: (next: ReturnType<typeof createElement>) => Promise<void>;
  done: () => Promise<void>;
}> {
  const host = dom.window.document.getElementById("root")!;
  const root = createRoot(host);
  await act(async () => root.render(node));
  return {
    root: host,
    show: async (next) => act(async () => root.render(next)),
    done: async () => act(async () => root.unmount()),
  };
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

describe("a stopped subagent's line says why, and offers Restart", () => {
  const lineOf = (agents: Subagent[]) =>
    withSubagentLines([
      row("u1", "user", 0, { text: "Review it" }),
      row(`${SUBAGENTS}-3`, SUBAGENTS, 10, { subagents: agents }),
      row("a2", "assistant", 100, { text: "Done." }),
    ]) as Row[];
  const draw = (rows: Row[], restartSubagent?: (agent: Subagent) => void) =>
    render(
      createElement(
        TurnActionsContext.Provider,
        { value: restartSubagent ? { restartSubagent } : {} },
        createElement(VirtualTranscript, { rows, onToggleActivity: () => {}, expanded: new Set<string>() }),
      ),
    );

  test("the reason follows the name: stopped by you, interrupted by Send now; unknown shows none", async () => {
    const stopped = (id: string, stopReason?: Subagent["stopReason"]) =>
      agent(id, { state: "cancelled", endedAt: at(40), ...(stopReason && { stopReason }) });
    const { root, done } = await draw(
      lineOf([stopped("Reviewer", "user"), stopped("Tester", "sendNow"), stopped("Linter")]),
    );
    try {
      const lines = [...root.querySelectorAll<HTMLButtonElement>(".cv-subagent-done")];
      expect(lines.map((line) => line.textContent)).toEqual([
        "Subagent stopped: Linter · 30s",
        "Subagent stopped: Reviewer · stopped by you · 30s",
        "Subagent stopped: Tester · interrupted by Send now · 30s",
      ]);
    } finally {
      await done();
    }
  });

  test("Restart sends the subagent to the chat's restart; a finished one or one without its prompt has none", async () => {
    const restarted: Subagent[] = [];
    const { root, done } = await draw(
      lineOf([
        agent("Reviewer", { state: "cancelled", endedAt: at(40), prompt: "Review src/app.ts", kind: "Explore" }),
        agent("Tester", { state: "completed", endedAt: at(41), prompt: "Run the tests" }),
        agent("Linter", { state: "failed", endedAt: at(42) }),
      ]),
      (each) => void restarted.push(each),
    );
    try {
      const buttons = [...root.querySelectorAll<HTMLButtonElement>(".cv-subagent-restart")];
      expect(buttons).toHaveLength(1);
      expect(buttons[0]!.getAttribute("aria-label")).toBe("Restart");
      expect(buttons[0]!.closest(".cv-subagent-done-row")?.textContent).toContain("Reviewer");
      await act(async () => buttons[0]!.click());
      expect(restarted.map((each) => each.id)).toEqual(["Reviewer"]);
    } finally {
      await done();
    }
  });

  test("without a restart (a disconnected chat) no line offers it", async () => {
    const { root, done } = await draw(
      lineOf([agent("Reviewer", { state: "cancelled", endedAt: at(40), prompt: "Review src/app.ts" })]),
    );
    try {
      expect(root.querySelector(".cv-subagent-restart")).toBeNull();
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

  test("a running card keeps its DOM node when the subagent completes", async () => {
    const running = agent("Reviewer", { startedAt: Date.now() });
    const { root, show, done } = await render(
      createElement(SubagentTray, {
        items: [{ kind: "agent", id: running.id, agent: running, depth: 0 }],
        finished: [],
        working: true,
        waiting: new Set<string>(),
        onOpen: () => {},
      }),
    );
    try {
      const before = root.querySelector<HTMLElement>(".acpmux-agent-line")!;
      const completed = { ...running, state: "completed" as const, endedAt: Date.now() };
      await show(
        createElement(SubagentTray, {
          items: [],
          finished: [{ kind: "agent", id: completed.id, agent: completed, depth: 0 }],
          working: true,
          waiting: new Set<string>(),
          onOpen: () => {},
        }),
      );
      const after = root.querySelector<HTMLElement>(".acpmux-agent-line")!;
      expect(after).toBe(before);
      expect(after.dataset.status).toBe("done");
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
        "Running in background · 2 subagents · 1 command",
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
    // Only the tray clock's one-second interval is recorded; the page's frame loop (jsdom's
    // requestAnimationFrame, which the shared page-reveal gate uses) keeps its real timers.
    globalThis.setInterval = ((handler: () => void, ms?: number) => {
      if (ms !== 1000) return realSet(handler, ms);
      ids += 1;
      intervals.add(ids);
      return ids;
    }) as unknown as typeof setInterval;
    globalThis.clearInterval = ((id?: unknown) => {
      if (typeof id === "number" && intervals.has(id)) intervals.delete(id);
      else realClear(id as Parameters<typeof clearInterval>[0]);
    }) as typeof clearInterval;
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

// Leo 2026-10-21 on the running strip above the composer: ""padding" this one tho i think is
// mostly a matter of like... well why is that even highlighted in the first place? you can click
// on it to go somewhere? is that a command or a subagent?" A line says what it is first, ends in a
// chevron when a click opens something, keeps the whole shell line as its tooltip, and has one stop
// control, which stops only that command (the composer's Stop cancels the turn, which a background
// command outlives). How it looks at rest and on hover: running-strip.test.ts.
describe("a tray line says what it is and what a click does", () => {
  const raw = "cd /Users/you/fun/cmux-wt/chromium-transparency && RED=cb8f4178; GREEN=1 bun test";

  test("a command leads with Command, its tooltip is the whole shell line, its chevron opens it, one stop", async () => {
    const items = trayItems(
      [],
      [command("s/1", { command: raw, processId: "s/1", toolCallId: "call-1", startedAt: Date.now() })],
      NONE,
      true,
    );
    const opened: string[] = [];
    const stopped: string[] = [];
    const { root, done } = await render(
      createElement(SubagentTray, {
        items,
        working: true,
        waiting: new Set<string>(),
        onOpen: () => {},
        onOpenCommand: (entry: BackgroundCommand) => opened.push(entry.id),
        stopProcess: async (id: string) => void stopped.push(id),
      }),
    );
    try {
      const line = root.querySelector<HTMLElement>(".acpmux-agent-line")!;
      const button = line.querySelector<HTMLButtonElement>(".acpmux-agent-line__button")!;
      expect(line.querySelector(".acpmux-agent-line__kind")?.textContent).toBe("Command");
      expect(button.querySelector(".acpmux-summary-text")?.textContent?.startsWith("Command")).toBe(true);
      expect(button.getAttribute("title")).toBe(raw);
      expect(button.querySelector(".acpmux-agent-line__chevron")).not.toBeNull();
      await act(async () => button.click());
      expect(opened).toEqual(["s/1"]);
      // One stop control on the line, and it says exactly what it stops.
      const stops = [...root.querySelectorAll<HTMLButtonElement>("button")].filter((each) =>
        /stop/i.test(`${each.getAttribute("aria-label") ?? ""} ${each.getAttribute("title") ?? ""}`),
      );
      expect(stops.length).toBe(1);
      expect(stops[0]!.getAttribute("title")).toBe("Stop only this command");
      await act(async () => stops[0]!.click());
      expect(stopped).toEqual(["s/1"]);
    } finally {
      await done();
    }
  });

  test("a subagent leads with Subagent and ends in a chevron", async () => {
    const items = trayItems([agent("Reviewer", { startedAt: Date.now(), action: "Read src/app.ts" })], [], NONE, true);
    const { root, done } = await render(
      createElement(SubagentTray, { items, working: true, waiting: new Set<string>(), onOpen: () => {} }),
    );
    try {
      const line = root.querySelector<HTMLElement>(".acpmux-agent-line")!;
      expect(line.querySelector(".acpmux-agent-line__kind")?.textContent).toBe("Subagent");
      expect(line.querySelector(".acpmux-summary-agent__name")?.textContent).toBe("Reviewer");
      expect(line.querySelector(".acpmux-agent-line__chevron")).not.toBeNull();
    } finally {
      await done();
    }
  });

  test("a line with nothing to open is disabled and has no chevron", async () => {
    const items = trayItems([], [command("call-1", { command: raw, startedAt: Date.now() })], NONE, true);
    const { root, done } = await render(
      createElement(SubagentTray, { items, working: true, waiting: new Set<string>(), onOpen: () => {} }),
    );
    try {
      const button = root.querySelector<HTMLButtonElement>(".acpmux-agent-line__button")!;
      expect(button.disabled).toBe(true);
      expect(button.querySelector(".acpmux-agent-line__chevron")).toBeNull();
      expect(root.querySelector(".acpmux-agent-line__kind")?.textContent).toBe("Command");
    } finally {
      await done();
    }
  });
});

// Leo 2026-10-21 on the tray: "2 subagents running · 2 commands · 32 sessions" over a list of five
// lines, one subagent already finished, a raw "cd ~/Projects/..." command: "Is stuff actually
// running? THIS IS LYING." and "SHOULDN'T THIS SAY SUBAGENTS?"
describe("the tray tells the truth", () => {
  const liveLines = (root: HTMLElement) => [
    ...root.querySelectorAll<HTMLElement>(".acpmux-running-tray__list > li:not([data-finished]) .acpmux-agent-line"),
  ];
  const names = (lines: HTMLElement[]) =>
    lines.map((line) => line.querySelector(".acpmux-summary-agent__name")?.textContent);

  test("the head counts only what runs or waits, and finished work keeps bounded status cards", async () => {
    const now = Date.now();
    const agents = [
      agent("Reviewer", { startedAt: now - 9000 }),
      agent("Tester", { startedAt: now - 8000 }),
      agent("Linter", { state: "completed", startedAt: now - 7000, endedAt: now - 6000 }),
      agent("Fuzzer", { state: "failed", startedAt: now - 6500, endedAt: now - 5000 }),
    ];
    const commands = [
      command("bg1", { command: "cd ~/Projects/cmux && bun run dev", description: "Start the dev server" }),
      command("bg2", { command: "make", state: "completed" }),
    ];
    const chats: StartedSession[] = [
      { sessionId: "c1", title: "Port the history page", state: "running", doing: "Run the tests" },
      { sessionId: "c2", title: "Draft the notes", state: "waiting" },
      { sessionId: "c3", title: "Fix the dock", state: "idle" },
      { sessionId: "c4", title: "Retry the upload", state: "failed" },
    ];
    const items = trayItems(agents, commands, chats, true);
    const finished = finishedTrayItems(agents, chats);
    expect(items.map((item) => item.id)).toEqual(["Reviewer", "Tester", "bg1", "c1", "c2"]);
    // What ended last comes first: the few the tray shows are the latest.
    // (c3 and c4 have no creation time: they keep their order, after any chat that has one.)
    expect(finished.map((item) => item.id)).toEqual(["Fuzzer", "Linter", "c3", "c4"]);
    const { root, done } = await render(
      createElement(SubagentTray, { items, finished, working: true, waiting: new Set<string>(), onOpen: () => {} }),
    );
    try {
      const head = root.querySelector<HTMLButtonElement>(".acpmux-running-tray__head")!;
      // Four subagents (two harness subagents, two chats it started, one waiting) and one command: five rows.
      // A chat that waits on the person is counted as waiting, never as running.
      expect(head.querySelector(".acpmux-running-tray__title")?.textContent).toBe(
        "3 subagents running · 1 waiting · 1 command",
      );
      if (head.getAttribute("aria-expanded") !== "true") await act(async () => head.click());
      const lines = liveLines(root);
      expect(lines.length).toBe(5);
      expect(names(lines)).toEqual([
        "Reviewer",
        "Tester",
        "Start the dev server",
        "Port the history page",
        "Draft the notes",
      ]);
      // A chat says what it does now; one waiting on the person says so.
      expect(lines[3]!.querySelector(".acpmux-summary-agent__kind")?.textContent).toBe("Run the tests");
      expect(lines[4]!.querySelector(".acpmux-summary-agent__state")?.textContent).toBe("Waiting");
      // Finished work is visible as cards without changing the running count.
      const more = root.querySelector<HTMLButtonElement>(".acpmux-running-tray__finished")!;
      expect(more.textContent).toContain("View all 4");
      expect(more.getAttribute("aria-expanded")).toBe("false");
      expect(names([...root.querySelectorAll<HTMLElement>("li[data-finished] .acpmux-agent-line")])).toEqual([
        "Fuzzer",
        "Linter",
        "Fix the dock",
      ]);
      await act(async () => more.click());
      const ended = [...root.querySelectorAll<HTMLElement>("li[data-finished] .acpmux-agent-line")];
      expect(names(ended)).toEqual(["Fuzzer", "Linter", "Fix the dock", "Retry the upload"]);
      expect(ended.map((line) => line.querySelector(".acpmux-summary-agent__state")?.textContent)).toEqual([
        "Failed",
        "Done",
        "Done",
        "Failed",
      ]);
      expect(more.textContent).toContain("Show fewer");
      expect(more.getAttribute("aria-expanded")).toBe("true");
      expect(liveLines(root).length).toBe(5);
    } finally {
      await done();
    }
  });

  test("between turns it says subagents, never agents or sessions", async () => {
    const now = Date.now();
    const items = trayItems(
      [agent("Watcher", { background: true, startedAt: now }), agent("Scout", { background: true, startedAt: now })],
      [command("s/1", { command: "cargo watch", processId: "s/1", startedAt: now })],
      [{ sessionId: "c1", title: "Port the history page", state: "running" }],
      false,
    );
    const { root, done } = await render(
      createElement(SubagentTray, { items, working: false, waiting: new Set<string>(), onOpen: () => {} }),
    );
    try {
      expect(root.querySelector(".acpmux-running-tray__title")?.textContent).toBe(
        "Running in background · 3 subagents · 1 command",
      );
      expect(root.querySelector(".acpmux-running-tray__finished")).toBeNull();
    } finally {
      await done();
    }
  });

  test("a subagent that ended is done at once: a late progress report does not run it again", () => {
    let seq = 0;
    const fold = new SubagentFold();
    const feed = (update: Record<string, unknown>, acpmux: Record<string, unknown>) => {
      seq += 1;
      fold.reduce(
        { seq, at: seq * 1000, msg: { method: "session/update", params: { update, _meta: { acpmux } } } },
        update,
      );
    };
    feed(
      { sessionUpdate: "subagent_spawned" },
      { subagents: [{ id: "a", parent: null, name: "Audit", state: "running" }] },
    );
    feed({ sessionUpdate: "subagent_state_update" }, { subagents: [{ id: "a", state: "completed" }] });
    // Claude's last task_progress can trail its end.
    feed({ sessionUpdate: "subagent_progress" }, { subagents: [{ id: "a", state: "running", tokens: 900 }] });
    const audit = fold.all().find((one) => one.id === "a")!;
    expect(audit.state).toBe("completed");
    expect(trayItems(fold.all(), [], NONE, true)).toEqual([]);
    expect(finishedTrayItems(fold.all(), NONE).map((item) => item.id)).toEqual(["a"]);
  });

  test("a row says what it does now: an older call's update does not take its line back", () => {
    let seq = 0;
    const fold = new SubagentFold();
    const feed = (update: Record<string, unknown>, acpmux: Record<string, unknown>) => {
      seq += 1;
      fold.reduce(
        { seq, at: seq * 1000, msg: { method: "session/update", params: { update, _meta: { acpmux } } } },
        update,
      );
    };
    feed(
      { sessionUpdate: "subagent_spawned" },
      { subagents: [{ id: "a", parent: null, name: "Audit", state: "running" }] },
    );
    feed(
      { sessionUpdate: "tool_call", toolCallId: "t1", title: "Read fetch.ts", status: "in_progress" },
      { subagent: "a" },
    );
    feed(
      { sessionUpdate: "tool_call", toolCallId: "t2", title: "Run the tests", status: "in_progress" },
      { subagent: "a" },
    );
    feed(
      { sessionUpdate: "tool_call_update", toolCallId: "t1", title: "Read fetch.ts", status: "completed" },
      { subagent: "a" },
    );
    expect(fold.all().find((one) => one.id === "a")!.action).toBe("Run the tests");
    // A call met first through its update is the newest one.
    feed(
      { sessionUpdate: "tool_call_update", toolCallId: "t3", title: "Grep retries", status: "in_progress" },
      { subagent: "a" },
    );
    expect(fold.all().find((one) => one.id === "a")!.action).toBe("Grep retries");
    expect(fold.all().find((one) => one.id === "a")!.actionShell).toBeUndefined();
    // A shell call (ACP kind execute) marks its title as a command; a progress summary clears it.
    feed(
      { sessionUpdate: "tool_call", toolCallId: "t4", title: "git status", kind: "execute", status: "in_progress" },
      { subagent: "a" },
    );
    expect(fold.all().find((one) => one.id === "a")!.actionShell).toBe(true);
    // A new call met through an update that omits its kind is not the shell call before it.
    feed(
      { sessionUpdate: "tool_call_update", toolCallId: "t5", title: "read_file", status: "in_progress" },
      { subagent: "a" },
    );
    expect(fold.all().find((one) => one.id === "a")!.actionShell).toBeUndefined();
    // Its own later update (no kind) keeps the shell call's provenance.
    feed(
      { sessionUpdate: "tool_call", toolCallId: "t6", title: "ls", kind: "execute", status: "pending" },
      { subagent: "a" },
    );
    feed(
      { sessionUpdate: "tool_call_update", toolCallId: "t6", title: "ls -la", status: "in_progress" },
      { subagent: "a" },
    );
    expect(fold.all().find((one) => one.id === "a")!.actionShell).toBe(true);
    feed({ sessionUpdate: "subagent_state_update" }, { subagents: [{ id: "a", action: "find the bug" }] });
    const after = fold.all().find((one) => one.id === "a")!;
    expect([after.action, after.actionShell]).toEqual(["find the bug", undefined]);
  });

  test("a command shows its description, else the command without its cd and env prefixes", async () => {
    const tool = (id: string, input: Record<string, unknown>) => ({
      id,
      title: String(input.command),
      kind: "execute",
      status: "in_progress",
      inputSummary: JSON.stringify({ ...input, run_in_background: true }),
      startedAt: at(5),
    });
    const rows = [
      row("t1", "activity", 5, {
        items: [
          {
            tool: tool("call-1", { command: "cd ~/Projects/cmux && bun run dev", description: "Start the dev server" }),
          },
          { tool: tool("call-2", { command: "cd ~/Projects/cmux/webviews && export CI=1 && FOO=bar nice bun test" }) },
        ],
      } as Partial<Row>),
    ];
    const commands = backgroundCommands([], runningBackgroundTasks(rows), false);
    expect(commands.map(commandLabel)).toEqual(["Start the dev server", "nice bun test"]);
    // The registry's process takes the description of the call that started it.
    const registry = backgroundCommands(
      [
        {
          id: "s/1",
          toolCallId: "call-1",
          command: "cd ~/Projects/cmux && bun run dev",
          startedAt: at(5),
          state: "running",
        },
      ],
      runningBackgroundTasks(rows),
      true,
    );
    expect(registry.map(commandLabel)).toEqual(["Start the dev server"]);
    expect(commandLabel(command("x", { command: "PORT=3000 bun run dev" }))).toBe("bun run dev");
    expect(commandLabel(command("y", { command: "cd /tmp; ls -la" }))).toBe("ls -la");
    expect(commandLabel(command("z", { command: "cd ~/Projects" }))).toBe("cd ~/Projects");
    expect(commandLabel(command("w", { command: "X=1 && echo $X" }))).toBe("echo $X");
    expect(commandLabel(command("v", { command: "env -u FOO bar" }))).toBe("env -u FOO bar");
    // A long run of assignments that never reaches a command reads in one pass, not exponentially.
    const long = `export ${Array.from({ length: 30 }, (_, index) => `A${index}="v"`).join(" ")} | x`;
    const started = performance.now();
    expect(commandLabel(command("u", { command: long }))).toBe(long);
    expect(performance.now() - started).toBeLessThan(50);
    const items = trayItems([], commands, NONE, true);
    const { root, done } = await render(
      createElement(SubagentTray, { items, working: true, waiting: new Set<string>(), onOpen: () => {} }),
    );
    try {
      expect(names(liveLines(root))).toEqual(["Start the dev server", "nice bun test"]);
      // The whole command stays one hover away.
      expect(liveLines(root)[0]!.querySelector("button")?.getAttribute("title")).toBe(
        "cd ~/Projects/cmux && bun run dev",
      );
    } finally {
      await done();
    }
  });
});

describe('the tray\'s header stays (Leo 2026-10-25: "sometimes it disappears")', () => {
  const panel = (running: number, ended: number) => {
    const now = Date.now();
    const agents = [
      ...Array.from({ length: running }, (_, index) => agent(`Run ${index}`, { startedAt: now - 60_000 + index })),
      ...Array.from({ length: ended }, (_, index) =>
        agent(`Done ${index}`, { state: "completed", startedAt: now - 90_000, endedAt: now - 80_000 + index }),
      ),
    ];
    return { items: trayItems(agents, [], NONE, true), finished: finishedTrayItems(agents, NONE) };
  };

  test("with 118 agents the header is pinned outside the list that scrolls, and View all under it", async () => {
    const { items, finished } = panel(2, 116);
    const { root, done } = await render(
      createElement(SubagentTray, { items, finished, working: true, waiting: new Set<string>(), onOpen: () => {} }),
    );
    try {
      const tray = root.querySelector<HTMLElement>(".acpmux-running-tray")!;
      const list = tray.querySelector<HTMLElement>(".acpmux-running-tray__list")!;
      const more = tray.querySelector<HTMLButtonElement>(".acpmux-running-tray__finished")!;
      // The tray is the header, then the fold (trayMotion.tsx) with the list and View all under it:
      // neither pinned part is inside the scroller.
      expect([...tray.children].map((child) => child.className)).toEqual([
        expect.stringContaining("acpmux-running-tray__head"),
        "acpmux-running-tray__fold",
      ]);
      expect([...tray.children[1]!.children].map((child) => child.className)).toEqual([
        "acpmux-running-tray__list",
        expect.stringContaining("acpmux-running-tray__finished"),
      ]);
      expect(more.textContent).toContain("View all 116");
      await act(async () => more.click());
      expect(list.querySelectorAll("li").length).toBe(118);
      // Scrolling the list to its end leaves the header mounted, first, and the same node.
      const head = tray.querySelector<HTMLElement>(".acpmux-running-tray__head")!;
      list.scrollTop = 118 * 28;
      await act(async () => void list.dispatchEvent(new dom.window.Event("scroll")));
      expect(tray.firstElementChild).toBe(head);
      expect(head.isConnected).toBe(true);
      expect(head.getAttribute("aria-expanded")).toBe("true");
      // Running first, then what ended last.
      const names = [...list.querySelectorAll(".acpmux-summary-agent__name")].map((node) => node.textContent);
      expect(names.slice(0, 3)).toEqual(["Run 0", "Run 1", "Done 115"]);
      expect(names.at(-1)).toBe("Done 0");
    } finally {
      await done();
    }
  });

  test("one of two running ending keeps the same header node, its collapse and its focus", async () => {
    const now = Date.now();
    const runs = [agent("Run 0", { startedAt: now - 9000 }), agent("Run 1", { startedAt: now - 8000 })];
    const tray = (agents: Subagent[]) =>
      createElement(SubagentTray, {
        items: trayItems(agents, [], NONE, true),
        finished: finishedTrayItems(agents, NONE),
        working: true,
        waiting: new Set<string>(),
        onOpen: () => {},
      });
    const { root, show, done } = await render(tray(runs));
    try {
      const head = root.querySelector<HTMLButtonElement>(".acpmux-running-tray__head")!;
      expect(head.querySelector(".acpmux-running-tray__title")?.textContent).toBe("2 subagents running");
      head.focus();
      // Run 1 ends: one runs, one ended. The header stays, the same node, focused and open.
      await show(tray([runs[0]!, { ...runs[1]!, state: "completed", endedAt: now }]));
      expect(root.querySelector(".acpmux-running-tray__head")).toBe(head);
      expect(dom.window.document.activeElement).toBe(head);
      expect(head.getAttribute("aria-expanded")).toBe("true");
      expect(head.getAttribute("aria-controls")).toBe(root.querySelector(".acpmux-running-tray__list")!.id);
      expect(head.querySelector(".acpmux-running-tray__title")?.textContent).toBe("1 subagent running");
      await act(async () => head.click());
      expect(root.querySelectorAll(".acpmux-agent-line").length).toBe(0);
      expect(root.querySelector(".acpmux-running-tray__head")).toBe(head);
    } finally {
      await done();
    }
    // Nothing runs, the ended lines stay: the header says Subagents, never an empty title.
    const ended = panel(0, 2);
    const idle = await render(
      createElement(SubagentTray, {
        items: ended.items,
        finished: ended.finished,
        working: true,
        waiting: new Set<string>(),
        onOpen: () => {},
      }),
    );
    try {
      expect(idle.root.querySelector(".acpmux-running-tray__title")?.textContent).toBe("Subagents");
    } finally {
      await idle.done();
    }
  });

  test("only a tool call's title becomes a command; plan prose stays as written", async () => {
    const { toolDetail, doingDetail, isCommandTitle } =
      await import("../src/agent-session/acpmux/subagents/trayDetail");
    const t = (key: string, values?: Record<string, unknown>) =>
      key === "tools.runningCommand" ? `Running ${String(values?.command)}` : key;
    // ACP titles other calls in capitalized words; a shell call's title is the command as typed.
    for (const title of ["Read AgentCard.tsx", "Run cargo test -p acpmux", "Edit 2 files", "Grep retries"])
      expect(isCommandTitle(title)).toBe(false);
    for (const command of [
      "git status",
      "ls",
      "cat -n README.md",
      "make test -j4",
      "./x.sh",
      "FOO=1 bun test",
      "~/bin/x",
    ])
      expect(isCommandTitle(command)).toBe(true);
    // Without shell provenance a lowercase title needs a known program or shell structure.
    for (const prose of ["find the issue", "make a plan", "go ahead", "cat README.md"])
      expect(isCommandTitle(prose)).toBe(false);
    // A shell call's own title (ACP execute) is its command whatever it starts with.
    expect(isCommandTitle("cat README.md", true)).toBe(true);
    expect(isCommandTitle("terraform plan", true)).toBe(true);
    expect(toolDetail(t as never, "cd repo && terraform plan")).toBe("Running terraform plan");
    expect(toolDetail(t as never, "Read AgentCard.tsx")).toBe("Read AgentCard.tsx");
    // A plan step is prose, whatever it starts with, and is never split: only the tool part changes.
    const step = 'find the bug in `SubagentTray.tsx` · make sure --help says "a · b"';
    expect(doingDetail(t as never, step, undefined)).toBe(step);
    expect(doingDetail(t as never, `${step} · git status`, "git status")).toBe(`${step} · Running git status`);
    const quoted = 'echo "a \\" · git status"';
    expect(doingDetail(t as never, quoted, quoted)).toBe(`Running ${quoted}`);
    expect(doingDetail(t as never, "Check the card · Read AgentCard.tsx", "Read AgentCard.tsx")).toBe(
      "Check the card · Read AgentCard.tsx",
    );
    // An ended agent keeps its kind, never a "Running …" of its last call.
    const now = Date.now();
    const ended = agent("Linter", {
      state: "completed",
      kind: "Explore",
      action: "git status",
      startedAt: now - 9000,
      endedAt: now - 1000,
    });
    const { root, done } = await render(
      createElement(SubagentTray, {
        items: [],
        finished: finishedTrayItems([ended], NONE),
        working: true,
        waiting: new Set<string>(),
        onOpen: () => {},
      }),
    );
    try {
      expect(root.querySelector(".acpmux-summary-agent__kind")?.textContent).toBe("Explore");
    } finally {
      await done();
    }
  });

  test("what ended last leads: a late nested child lifts its parent; a chat with no time goes last", () => {
    const agents = [
      agent("old", { state: "completed", startedAt: at(0), endedAt: at(10) }),
      agent("parent", { state: "completed", startedAt: at(0), endedAt: at(5) }),
      agent("child", { parent: "parent", state: "completed", startedAt: at(1), endedAt: at(30) }),
      agent("mid", { state: "completed", startedAt: at(0), endedAt: at(20) }),
    ];
    const chats: StartedSession[] = [
      { sessionId: "untimed", title: "Untimed", state: "idle" },
      { sessionId: "first", title: "First", state: "idle", createdAt: at(1) },
      { sessionId: "second", title: "Second", state: "idle", createdAt: at(2) },
    ];
    expect(finishedTrayItems(agents, chats).map((item) => item.id)).toEqual([
      "parent",
      "child",
      "mid",
      "old",
      "second",
      "first",
      "untimed",
    ]);
  });

  test("a line says what the agent does in words, never a raw shell line", async () => {
    const chats: StartedSession[] = [
      {
        sessionId: "c1",
        title: "fanout-infra",
        state: "running",
        doing: "cd /Users/you/Projects/checkouts/ws/broker && sed -i '' 's/a/b/' broker.ts",
        doingTool: "cd /Users/you/Projects/checkouts/ws/broker && sed -i '' 's/a/b/' broker.ts",
      },
      {
        sessionId: "c2",
        title: "card",
        state: "running",
        doing: "Check the card · Read AgentCard.tsx",
        doingTool: "Read AgentCard.tsx",
      },
    ];
    const items = trayItems(
      [
        agent("Reviewer", {
          startedAt: Date.now(),
          action: "FOO=1 bun test test/subagent-tray.test.tsx",
          actionShell: true,
        }),
        // A progress summary is words, lowercase or not: never "Running find the bug".
        agent("Planner", { startedAt: Date.now() + 1, action: "find the bug in the fold" }),
      ],
      [],
      chats,
      true,
    );
    const { root, done } = await render(
      createElement(SubagentTray, { items, working: true, waiting: new Set<string>(), onOpen: () => {} }),
    );
    try {
      // Four running, none waiting: the header counts them all as running.
      expect(root.querySelector(".acpmux-running-tray__title")?.textContent).toBe("4 subagents running");
      // Four lines start folded: open them.
      await act(async () => root.querySelector<HTMLButtonElement>(".acpmux-running-tray__head")!.click());
      const details = [...root.querySelectorAll(".acpmux-summary-agent__kind")].map((node) => node.textContent);
      expect(details).toEqual([
        "Running bun test test/subagent-tray.test.tsx",
        "find the bug in the fold",
        "Running sed -i '' 's/a/b/' broker.ts",
        "Check the card · Read AgentCard.tsx",
      ]);
      // The whole doing line is still the chat line's tooltip.
      const chat = [...root.querySelectorAll<HTMLElement>(".acpmux-agent-line__button")][2]!;
      expect(chat.title).toContain("cd /Users/you/Projects/checkouts/ws/broker");
    } finally {
      await done();
    }
  });
});
