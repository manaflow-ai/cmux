// cmux-web-test-timeout: 600
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The running turn's live line stays drawn, and in sight over the bottom stack, from the send to the
// final reply, while a background command from an earlier turn runs in the tray (Leo, 2026-11-04,
// on a new turn under a running background command's card: "why does it not display Thinking or
// anything here???", then "it appears and disappears????"). The line is the turn's last row
// (conversation/turns.ts), and the room under it keeps it above the tray and the composer
// (App.tsx `room`), at every phase: thinking before any output, a thought streaming, a call
// running, the call done, thinking again.
//
// Real Chromium from Playwright against the pane's dev entry and a stand-in acpmux daemon; CI fails
// the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import type { ServerWebSocket } from "bun";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-live-line-under-tray.test.ts", async () => {
  setDefaultTimeout(300_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-live-line-under-tray: skipping (run `bunx playwright install chromium`)");
    describe.skip("live line under the tray", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-00000000b9c1";
  const START = Date.now() - 20 * 60_000;
  const update = (update: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update },
  });
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  const devServer = "cd ~/Projects/app && bun run dev";
  const watcher = "cd ~/Projects/app && bun run watch:css";
  /// A call that starts `command` in the background and returns at once.
  const background = (call: string, task: string, command: string, description: string): Step[] => [
    [
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: call,
        title: command,
        kind: "execute",
        status: "in_progress",
        rawInput: { command, description, run_in_background: true },
      }),
    ],
    [
      "in",
      "tool_call_update",
      update({
        sessionUpdate: "tool_call_update",
        toolCallId: call,
        status: "completed",
        content: [
          { type: "content", content: { type: "text", text: `Command running in background with ID: ${task}` } },
        ],
      }),
    ],
  ];
  // Earlier turns fill more than the view, so it follows the latest row at the bottom, over the
  // stack; the last of them started a command in the background and ended; the command runs on.
  const filler: Step[] = Array.from(
    { length: 12 },
    (_, turn) =>
      [
        ["mux", "user_message", { text: `Look at part ${turn + 1}`, promptId: `f${turn}`, turnId: `ft${turn}` }],
        ["mux", "turn_started", { turnId: `ft${turn}`, promptId: `f${turn}` }],
        [
          "in",
          "agent_message_chunk",
          update({
            sessionUpdate: "agent_message_chunk",
            content: { type: "text", text: `Part ${turn + 1} reads well. `.repeat(12) },
          }),
        ],
        ["mux", "turn_end", { turnId: `ft${turn}`, stopReason: "end_turn" }],
        [
          "mux",
          "turn_result",
          { turnId: `ft${turn}`, promptId: `f${turn}`, status: "completed", stopReason: "end_turn" },
        ],
      ] as Step[],
  ).flat();
  const history: Step[] = [
    ...filler,
    ["mux", "user_message", { text: "Start the dev server and keep it running", promptId: "p1", turnId: "t1" }],
    ["mux", "turn_started", { turnId: "t1", promptId: "p1" }],
    // Two commands, so the tray has its header, which opens and folds its list.
    ...background("bg1", "b1", devServer, "Run the dev server"),
    ...background("bg0", "b0", watcher, "Watch the styles"),
    [
      "in",
      "agent_message_chunk",
      update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "The dev server runs." } }),
    ],
    ["mux", "turn_end", { turnId: "t1", stopReason: "end_turn" }],
    ["mux", "turn_result", { turnId: "t1", promptId: "p1", status: "completed", stopReason: "end_turn" }],
    ["mux", "status", { status: "ready" }],
  ];
  const record = (step: Step, seq: number, at: number) => ({
    sessionId: CHAT,
    seq,
    at,
    dir: step[0],
    kind: step[1],
    msg: step[2],
  });
  const events = history.map((step, index) => record(step, index + 1, START + index * 1000));
  const settled = events.slice();
  /// What acpmux's process registry lists for the chat (`_acpmux/process/list`).
  let processes: Record<string, unknown>[] = [];
  const devProcess = (state: string, fields: Record<string, unknown> = {}) => ({
    id: `${CHAT}/b1`,
    sessionId: CHAT,
    toolCallId: "bg1",
    command: devServer,
    description: "Run the dev server",
    origin: "background",
    startedAt: START + 3000,
    state,
    ...fields,
  });
  const running = {
    turnId: "t2",
    promptId: "p2",
    startedAt: Date.now(),
    client: "cmux",
    prompt: "Why so slow",
    turnSeq: 0,
  };
  const session: Record<string, unknown> = {
    sessionId: CHAT,
    cwd: "/home/dev/app",
    title: "Dev server",
    harness: "claude",
    family: "claude",
    status: "ready",
    turn: null,
    turnCount: 1,
    updatedAt: START,
  };

  function answer(method: string): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: events.length, events, hasMore: false };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: events.length };
      case "_acpmux/process/list":
        return { processes };
      default:
        return null;
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const sockets = new Set<ServerWebSocket<unknown>>();
  const send = (method: string, params: unknown) => {
    for (const ws of sockets) ws.send(JSON.stringify({ jsonrpc: "2.0", method, params }));
  };
  /// One live record, as acpmux sends it: a mux record as `_acpmux/event`, an agent update as ACP's
  /// `session/update` with the record's seq in its meta.
  const push = (step: Step) => {
    const event = record(step, events.length + 1, Date.now());
    events.push(event);
    if (step[0] === "mux") send("_acpmux/event", event);
    else {
      const params = step[2].params as Record<string, unknown>;
      send("session/update", {
        ...params,
        sessionId: CHAT,
        _meta: { acpmux: { seq: event.seq, at: event.at, kind: event.kind } },
      });
    }
  };
  /// A `session_changed` with the summary as acpmux builds it when it sends it.
  const changed = (fields: Record<string, unknown>) => {
    Object.assign(session, fields);
    send("_acpmux/session_changed", { sessionId: CHAT, session: { ...session }, kind: "status", seq: events.length });
  };
  const url = () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${CHAT}`;
  };
  const drawn = (page: Page) => page.locator(".acpmux-row", { hasText: "The dev server runs." });

  beforeAll(async () => {
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        open(ws) {
          sockets.add(ws);
        },
        close(ws) {
          sockets.delete(ws);
        },
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string };
          if (message.id !== undefined)
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method) }));
        },
      },
    });
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/");
    browser = await chromium.launch({ headless: true });
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url());
        await drawn(warm).waitFor({ timeout: 25_000 });
        await warm.close();
        break;
      } catch (error) {
        await warm.close();
        if (attempt === 3) throw error;
      }
    }
    sockets.clear();
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  /// The live line as drawn: whether it is there, draws its words, and stands in sight over the
  /// bottom stack (its box above the stack's top, and its centre hits it).
  const liveLine = (page: Page) =>
    page.evaluate(() => {
      const line = document.querySelector<HTMLElement>(".acpmux-row--below .cv-worked--live");
      const stack = document.querySelector(".acpmux-main > .acpmux-dock")?.getBoundingClientRect();
      const tray = document.querySelector(".acpmux-running-tray")?.getBoundingClientRect();
      const scroll = document.querySelector(".acpmux-main .acpmux-scroll")?.getBoundingClientRect();
      if (!line) return { present: false, rows: document.querySelectorAll(".acpmux-row").length };
      const rect = line.getBoundingClientRect();
      const hit = document.elementFromPoint(rect.left + 4, rect.top + rect.height / 2);
      return {
        present: true,
        text: line.textContent?.replace(/\s+/g, " ").trim(),
        quiet: line.classList.contains("is-quiet"),
        bottom: Math.round(rect.bottom),
        stackTop: stack ? Math.round(stack.top) : null,
        trayTop: tray ? Math.round(tray.top) : null,
        scrollBottom: scroll ? Math.round(scroll.bottom) : null,
        aboveStack: stack ? rect.bottom <= stack.top + 0.5 : true,
        hit: hit ? line.contains(hit) || hit === line : false,
      };
    });

  const thought = (text: string) =>
    [
      "in",
      "agent_thought_chunk",
      update({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text } }),
    ] as Step;

  type Phase = [name: string, step: (page: Page) => unknown];
  /// The reader opens or folds the running tray (its header's disclosure).
  const toggleTray = (page: Page) => page.click(".acpmux-running-tray__head");
  /// Opens the chat as it was after the earlier turns, sends the new turn's phases one by one and
  /// checks the live line at each, and in every frame from its first.
  async function stepThrough(extra: Phase[] = []) {
    events.splice(0, events.length, ...settled);
    Object.assign(session, { status: "ready", turn: null });
    const page = await browser!.newPage({ viewport: { width: 900, height: 640 } });
    await installPaintedFrames(page);
    await page.goto(url());
    await drawn(page).waitFor();
    const phases: Phase[] = [
      [
        "sent",
        () => {
          push(["mux", "user_message", { text: "Why has this taken so long?", promptId: "p2", turnId: "t2" }]);
          push(["mux", "turn_started", { turnId: "t2", promptId: "p2" }]);
          push(["mux", "status", { status: "running" }]);
          changed({ status: "running", turn: running });
        },
      ],
      ["thinking", () => push(thought("Looking at what ran"))],
      [
        "call running",
        () =>
          push([
            "in",
            "tool_call",
            update({
              sessionUpdate: "tool_call",
              toolCallId: "c2",
              title: "git log --oneline -5",
              kind: "execute",
              status: "in_progress",
              rawInput: { command: "git log --oneline -5" },
            }),
          ]),
      ],
      [
        "call done",
        () =>
          push([
            "in",
            "tool_call_update",
            update({
              sessionUpdate: "tool_call_update",
              toolCallId: "c2",
              status: "completed",
              content: [{ type: "content", content: { type: "text", text: "abc123 fix\n" } }],
              rawOutput: { exit_code: 0 },
            }),
          ]),
      ],
      ["thinking again", () => push(thought("Now the reasons"))],
      ...extra,
    ];
    const seen: Record<string, unknown> = {};
    let sampling = false;
    for (const [name, step] of phases) {
      await step(page);
      if (!sampling) {
        sampling = true;
        // From the first frame the line draws, every frame until the turn ends: a frame with no
        // line, a quiet one or one under the stack is a blink (Leo's "it appears and disappears").
        await page.waitForSelector(".acpmux-row--below .cv-worked--live:not(.is-quiet)");
        await page.evaluate(() => {
          const misses: string[] = [];
          (window as unknown as { __misses: string[] }).__misses = misses;
          // Every painted frame, from here to the reply.
          window.cmuxAfterPaint(() => {
            const line = document.querySelector(".acpmux-row--below .cv-worked--live");
            const stack = document.querySelector(".acpmux-main > .acpmux-dock")?.getBoundingClientRect();
            const box = line?.getBoundingClientRect();
            const miss = !line
              ? "absent"
              : line.classList.contains("is-quiet")
                ? "quiet"
                : stack && box && box.bottom > stack.top + 0.5
                  ? `under the stack (${Math.round(box.bottom)} > ${Math.round(stack.top)})`
                  : undefined;
            if (miss && misses.at(-1) !== miss) misses.push(miss);
          });
        });
      }
      // The line must hold through the phase, past its quiet hold (Thinking.tsx QUIET_MS), with the
      // per-frame sampler watching; no event marks "the phase has settled and stayed".
      await page.waitForTimeout(1500); // fixed-wait: the line has to hold for a stretch, not reach a state
      const line = await liveLine(page);
      seen[name] = line;
      expect({ phase: name, present: line.present, quiet: "quiet" in line ? line.quiet : undefined }).toEqual({
        phase: name,
        present: true,
        quiet: false,
      });
      expect({
        phase: name,
        aboveStack: "aboveStack" in line && line.aboveStack,
        hit: "hit" in line && line.hit,
      }).toEqual({
        phase: name,
        aboveStack: true,
        hit: true,
      });
    }
    console.log(JSON.stringify(seen, null, 2));
    const misses = await page.evaluate(() => (window as unknown as { __misses: string[] }).__misses);
    expect({ blinks: misses }).toEqual({ blinks: [] });
    await page.close();
  }

  test("the live line stays drawn and in sight from the send to the reply, under a background command only the transcript knows", async () => {
    processes = [];
    await stepThrough();
  });

  test("the live line stays drawn and in sight while acpmux's registry lists the command and its card updates", async () => {
    // The tray shows the command before the send (the registry says it runs), and the turn's
    // commands come and go in it while the turn runs, each with the chat's summary sent again.
    const watch = {
      ...devProcess("running"),
      id: `${CHAT}/b0`,
      toolCallId: "bg0",
      command: watcher,
      description: "Watch the styles",
    };
    processes = [devProcess("running"), watch];
    const second = {
      id: `${CHAT}/b2`,
      sessionId: CHAT,
      toolCallId: "c3",
      command: "bun test --watch",
      origin: "background",
      startedAt: Date.now(),
      state: "running",
    };
    const registry = (process: Record<string, unknown>) => {
      send("_acpmux/process_update", { sessionId: CHAT, process });
      changed({ commandsRunning: processes.filter((item) => item.state === "running").length });
    };
    await stepThrough([
      // What the reader opens in the tray lies over the transcript's foot (App.tsx `trayHold`), but
      // never over the running turn's line: Leo's line went under a tray he had opened.
      ["the reader opens the tray", toggleTray],
      ["thinking under the open tray", () => push(thought("Checking the server"))],
      ["the reader folds the tray", toggleTray],
      [
        "a second command starts",
        () => {
          processes = [...processes, second];
          registry(second);
        },
      ],
      [
        "the first command's card updates",
        () => {
          processes = [devProcess("running", { outputBytes: 4096 }), watch, second];
          registry(processes[0]!);
        },
      ],
      ["thinking after the update", () => push(thought("Reading the server log"))],
      [
        "the second command ends",
        () => {
          const ended = { ...second, state: "exited", endedAt: Date.now() };
          processes = [processes[0]!, watch, ended];
          registry(ended);
        },
      ],
    ]);
  });
});
