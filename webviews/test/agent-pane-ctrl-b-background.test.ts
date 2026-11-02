// l10n-allow-file: test fixture prompts and commands, not shipped UI.
// Ctrl-B moves a Claude Code chat's running work to the background, as in Claude Code
// (conversation/runInBackground.ts): the turn's live line, which names the running command, says
// "⌃B to run in background", and Ctrl-B, with the composer focused too, asks acpmux
// `_acpmux/process/background`. A chat whose turn holds no running call keeps Ctrl-B for the
// composer's caret. Which chats offer it is acpmux's word (the summary's `backgroundsWork`), not the
// harness's name: the model router's `cmux` chat does, a Codex chat and an ACP agent named
// `claude-acp` never show the hint. A running subagent draws no tool row, and takes Ctrl-B by
// itself. A notice above the composer says what Ctrl-B did until the next key
// (conversation/backgroundNotice.ts): the work moved, Claude Code said so but the command still
// runs in the foreground, or nothing moved (acpmux found nothing in the foreground, refused, never
// answered, or the connection closed). The page is the pane's dev entry with its browser host,
// talking JSON-RPC to a stand-in acpmux daemon.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, beforeEach, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { BACKGROUND_NOTICE_TEXT } from "../src/agent-session/acpmux/conversation/backgroundNotice";
import { translate } from "../src/agent-session/acpmux/i18n";

await requireBrowserLane("agent-pane-ctrl-b-background.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-ctrl-b-background: skipping (run `bunx playwright install chromium`)");
    describe.skip("ctrl-b background", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CLAUDE = "0190a000-0000-7000-8000-0000000000b1";
  const CODEX = "0190a000-0000-7000-8000-0000000000b2";
  const IDLE = "0190a000-0000-7000-8000-0000000000b3";
  const SUBAGENT = "0190a000-0000-7000-8000-0000000000b4";
  const ROUTER = "0190a000-0000-7000-8000-0000000000b5";
  const CLAUDE_ACP = "0190a000-0000-7000-8000-0000000000b6";
  const START = Date.UTC(2026, 9, 20, 9, 0, 0);
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  const update = (update: Record<string, unknown>, meta?: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update, ...(meta ? { _meta: { acpmux: meta } } : {}) },
  });
  /// A Bash call still running in the foreground: no result yet.
  const running = (id: string, command: string): Step => [
    "in",
    "tool_call",
    update({
      sessionUpdate: "tool_call",
      toolCallId: id,
      title: command,
      kind: "execute",
      status: "in_progress",
      rawInput: { command },
      _meta: { claude: { tool: "Bash" } },
    }),
  ];
  const say = (text: string): Step => [
    "in",
    "agent_message_chunk",
    update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } }),
  ];
  /// A turn running `cargo test --workspace` in the foreground, as call `id`.
  const suite = (id: string): Step[] => [
    ["mux", "user_message", { text: "Run the full test suite" }],
    ["mux", "turn_started", {}],
    say("Running the suite."),
    running(id, "cargo test --workspace"),
  ];
  /// Each chat's harness, whether acpmux moves its work (`backgroundsWork` on its summary), and its events.
  const chats: Record<string, { harness: string; moves: boolean; steps: Step[] }> = {
    [CLAUDE]: { harness: "claude", moves: true, steps: suite("fg1") },
    [CODEX]: { harness: "codex", moves: false, steps: suite("fg2") },
    // The model router's profile: Claude Code under acpmux, named `cmux`.
    [ROUTER]: { harness: "cmux", moves: true, steps: suite("fg3") },
    // A user's config named an ACP agent after Claude: acpmux refuses its Ctrl-B.
    [CLAUDE_ACP]: { harness: "claude-acp", moves: false, steps: suite("fg4") },
    [SUBAGENT]: {
      harness: "claude",
      moves: true,
      steps: [
        ["mux", "user_message", { text: "Explore the uploader" }],
        ["mux", "turn_started", {}],
        say("Running the suite."),
        [
          "in",
          "subagent_spawned",
          update(
            { sessionUpdate: "subagent_spawned" },
            { subagents: [{ id: "sub1", parent: null, name: "Explore", state: "running" }] },
          ),
        ],
      ],
    },
    [IDLE]: {
      harness: "claude",
      moves: true,
      steps: [
        ["mux", "user_message", { text: "Say hi" }],
        ["mux", "turn_started", {}],
        say("Running the suite."),
        ["mux", "turn_result", { status: "completed" }],
      ],
    },
  };
  const sessionOf = (id: string) => ({
    sessionId: id,
    cwd: "/home/dev/uploader",
    title: "Tests",
    harness: chats[id]!.harness,
    family: chats[id]!.harness,
    backgroundsWork: chats[id]!.moves,
    status: chats[id]!.steps.some(([, kind]) => kind === "turn_result") ? "idle" : "running",
    turnCount: 1,
    updatedAt: START,
  });
  const eventsOf = (id: string) =>
    chats[id]!.steps.map(([dir, kind, msg], index) => ({
      sessionId: id,
      seq: index + 1,
      at: START + index * 1000,
      dir,
      kind,
      msg,
    }));

  /// What the page asked the daemon to background, in order.
  const backgrounded: Record<string, unknown>[] = [];
  /// How the daemon answers a background request: moved the work, found nothing in the foreground,
  /// refused it (invalid params, as for another harness), never answers, or closes the connection.
  let backgroundReply: "moved" | "nothing" | "refused" | "silent" | "closed" = "moved";
  /// Background requests the daemon has answered.
  let backgroundAnswers = 0;
  /// Called after each background request the daemon hears, and each it answers.
  const heard = new Set<() => void>();
  /// Resolves once `done` holds, checking after each background request heard or answered.
  const once = (done: () => boolean, what: string) =>
    new Promise<void>((resolve, reject) => {
      const check = () => {
        if (!done()) return;
        heard.delete(check);
        resolve();
      };
      heard.add(check);
      check();
      setTimeout(() => {
        heard.delete(check);
        if (!done()) reject(new Error(`the daemon never ${what}`));
      }, 2_500);
    });
  const SILENT = Symbol("silent");
  const REFUSED = Symbol("refused");
  const CLOSED = Symbol("closed");
  function answer(method: string, params: Record<string, any> | undefined): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: Object.keys(chats).map(sessionOf) };
      case "_acpmux/attach": {
        const id = String(params?.sessionId);
        const events = eventsOf(id);
        return { session: sessionOf(id), lastSeq: events.length, events };
      }
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: 0 };
      case "_acpmux/process/background":
        backgrounded.push(params ?? {});
        for (const check of heard) check();
        if (backgroundReply === "silent") return SILENT;
        if (backgroundReply === "refused") return REFUSED;
        if (backgroundReply === "closed") return CLOSED;
        return { backgrounded: backgroundReply === "moved" };
      default:
        return null;
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = (session: string) => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${session}`;
  };
  beforeAll(async () => {
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          if (message.id === undefined) return;
          const result = answer(message.method, message.params);
          if (result === SILENT) return;
          if (result === CLOSED) return ws.close();
          if (message.method === "_acpmux/process/background") {
            backgroundAnswers += 1;
            for (const check of heard) check();
          }
          if (result === REFUSED)
            ws.send(
              JSON.stringify({
                jsonrpc: "2.0",
                id: message.id,
                error: { code: -32602, message: "process/background needs a Claude Code session" },
              }),
            );
          else ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
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
    // A cold dev server's first load can stall in CI (agent-pane-replay.test.ts): load it here,
    // again if it stalls, so the tests time only the pane.
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url(CLAUDE));
        await warm.getByText("Running the suite.").waitFor({ timeout: 25_000 });
        await warm.close();
        break;
      } catch (error) {
        await warm.close();
        if (attempt === 3) throw error;
      }
    }
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  const open = async (session: string): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    const frames: string[] = [];
    Object.assign(page, { backgroundFrames: frames });
    page.on("websocket", (socket) =>
      socket.on("framesent", (frame) => {
        if (String(frame.payload).includes("_acpmux/process/background")) frames.push(String(frame.payload));
      }),
    );
    // The pane ships on macOS, where the editor's Mod is Cmd: Cmd-B is bold and Ctrl-B is the
    // caret's, unbound. On Linux, CI's platform, Mod is Ctrl and the editor took Ctrl-B as bold.
    await page.addInitScript(() => Object.defineProperty(Navigator.prototype, "platform", { get: () => "MacIntel" }));
    await page.goto(url(session));
    await page.getByText("Running the suite.").waitFor();
    return page;
  };
  const composer = (page: Page) => page.locator("[contenteditable=true]").first();
  /// Records each Ctrl-B the page left alone, from the window's bubble phase. A Ctrl-B the page
  /// takes stops at its capture listener and never shows here.
  const watchCtrlB = (page: Page) =>
    page.evaluate(() => {
      const taken: boolean[] = [];
      (window as unknown as { ctrlB: boolean[] }).ctrlB = taken;
      window.addEventListener("keydown", (event) => {
        if (event.ctrlKey && event.key.toLowerCase() === "b") taken.push(event.defaultPrevented);
      });
    });
  const ctrlBTaken = (page: Page) => page.evaluate(() => (window as unknown as { ctrlB: boolean[] }).ctrlB);
  beforeEach(() => {
    backgrounded.length = 0;
    backgroundAnswers = 0;
    backgroundReply = "moved";
  });
  /// The notice line, holding notice `kind`'s text.
  const noticeText = (page: Page, kind: keyof typeof BACKGROUND_NOTICE_TEXT) =>
    page.locator(".acpmux-background-notice").getByText(translate(BACKGROUND_NOTICE_TEXT[kind]));
  const requested = async () => {
    await once(() => backgrounded.length > 0, "heard a background request").catch(() => {});
    return backgrounded;
  };
  /// The background requests the page sent, up to the moment it handled everything before this
  /// call: a console marker the page logs after them comes after their frames.
  const sentBackground = async (page: Page) => {
    const marker = `ctrl-b-mark-${Math.random()}`;
    await Promise.all([
      page.waitForEvent("console", (message) => message.text() === marker),
      page.evaluate((marker) => console.log(marker), marker),
    ]);
    return (page as Page & { backgroundFrames: string[] }).backgroundFrames;
  };

  test("a running command's live line says Ctrl-B runs it in the background", async () => {
    const page = await open(CLAUDE);
    // The command in flight draws no row of its own (Debug toggles agentPane.debug.codexToolRuns
    // and liveLineBelow, on by default): the live line at the turn's foot names it and offers the
    // hint its row did (Thinking.tsx).
    const line = page.locator(".cv-worked.is-below");
    const hint = line.getByText("⌃B to run in background");
    await hint.waitFor({ timeout: 5_000 });
    expect(await line.locator(".cv-thinking").textContent()).toBe("Running cargo test --workspace");
    // The hint shows only while the pointer is on the line (Leo, 2026-10-21).
    const opacity = () => hint.evaluate((node) => getComputedStyle(node).opacity);
    expect(await opacity()).toBe("0");
    await line.hover();
    await page.waitForFunction(
      () => getComputedStyle(document.querySelector(".cv-worked.is-below .cv-command__bg")!).opacity === "1",
    );
    await page.close();
  });

  test("Ctrl-B in the composer moves the chat's running work to the background", async () => {
    backgrounded.length = 0;
    const page = await open(CLAUDE);
    await page.getByText("⌃B to run in background").waitFor({ timeout: 5_000 });
    await composer(page).click();
    await page.keyboard.press("Control+b");
    expect(await requested()).toEqual([{ sessionId: CLAUDE }]);
    await page.close();
  });

  test("work that moved says so, and a command still in the foreground a moment later says it stayed", async () => {
    const page = await open(CLAUDE);
    await page.getByText("⌃B to run in background").waitFor({ timeout: 5_000 });
    await composer(page).click();
    await page.keyboard.press("Control+b");
    expect(await requested()).toEqual([{ sessionId: CLAUDE }]);
    await once(() => backgroundAnswers > 0, "answered the background request").catch(() => {});
    expect(backgroundAnswers).toBe(1);
    await noticeText(page, "moved").waitFor({ timeout: 5_000 });
    // The stand-in daemon says it moved, but its transcript's command never ends: the check after
    // BACKGROUND_CHECK_MS finds it still running in the foreground.
    await noticeText(page, "kept").waitFor({ timeout: 5_000 });
    await page.close();
  });

  test("nothing in the foreground: a notice says so, and the next key clears it", async () => {
    backgroundReply = "nothing";
    const page = await open(CLAUDE);
    await page.getByText("⌃B to run in background").waitFor({ timeout: 5_000 });
    await composer(page).click();
    await page.keyboard.press("Control+b");
    await noticeText(page, "nothing").waitFor({ timeout: 5_000 });
    await page.keyboard.type("x");
    await page.locator(".acpmux-background-notice").waitFor({ state: "detached", timeout: 2_000 });
    await page.close();
  });

  test("a refused request: a notice says the chat can't move work", async () => {
    backgroundReply = "refused";
    const page = await open(CLAUDE);
    await page.getByText("⌃B to run in background").waitFor({ timeout: 5_000 });
    await composer(page).click();
    await page.keyboard.press("Control+b");
    await noticeText(page, "refused").waitFor({ timeout: 5_000 });
    await page.close();
  });

  test("no answer: after the request's 10 s deadline a notice says the work still runs", async () => {
    backgroundReply = "silent";
    const page = await open(CLAUDE);
    await page.getByText("⌃B to run in background").waitFor({ timeout: 5_000 });
    await composer(page).click();
    await page.keyboard.press("Control+b");
    expect(await requested()).toEqual([{ sessionId: CLAUDE }]);
    await noticeText(page, "timedOut").waitFor({ timeout: 20_000 });
    await page.close();
  });

  test("the connection closes mid-request: a notice says it was lost, not that the agent didn't answer", async () => {
    backgroundReply = "closed";
    const page = await open(CLAUDE);
    await page.getByText("⌃B to run in background").waitFor({ timeout: 5_000 });
    await composer(page).click();
    await page.keyboard.press("Control+b");
    expect(await requested()).toEqual([{ sessionId: CLAUDE }]);
    await noticeText(page, "disconnected").waitFor({ timeout: 5_000 });
    expect(await noticeText(page, "timedOut").count()).toBe(0);
    await page.close();
  });

  test("Ctrl-B moves a running subagent, which draws no tool row", async () => {
    backgrounded.length = 0;
    const page = await open(SUBAGENT);
    await composer(page).click();
    await page.keyboard.press("Control+b");
    expect(await requested()).toEqual([{ sessionId: SUBAGENT }]);
    await page.close();
  });

  test("with no running call, Ctrl-B stays the composer's and asks nothing", async () => {
    backgrounded.length = 0;
    const page = await open(IDLE);
    await watchCtrlB(page);
    await composer(page).click();
    await page.keyboard.type("ab");
    await page.keyboard.press("Control+b");
    await page.keyboard.type("X");
    expect(await ctrlBTaken(page)).toEqual([false]);
    expect(await composer(page).innerText()).toContain("X");
    expect(await sentBackground(page)).toEqual([]);
    expect(backgrounded).toEqual([]);
    expect(await page.getByText("⌃B to run in background").count()).toBe(0);
    await page.close();
  });

  test("the model router's chat, Claude Code named `cmux`, shows the hint and moves its work", async () => {
    const page = await open(ROUTER);
    await page.getByText("⌃B to run in background").waitFor({ timeout: 5_000 });
    await composer(page).click();
    await page.keyboard.press("Control+b");
    expect(await requested()).toEqual([{ sessionId: ROUTER }]);
    await page.close();
  });

  for (const [name, session] of [
    ["a Codex chat", CODEX],
    ["an ACP agent named claude-acp", CLAUDE_ACP],
  ] as const) {
    test(`${name} shows no hint and keeps Ctrl-B`, async () => {
      const page = await open(session);
      await page.getByText("cargo test --workspace").first().waitFor();
      await watchCtrlB(page);
      await composer(page).click();
      await page.keyboard.press("Control+b");
      expect(await ctrlBTaken(page)).toEqual([false]);
      expect(await sentBackground(page)).toEqual([]);
      expect(backgrounded).toEqual([]);
      expect(await page.getByText("⌃B to run in background").count()).toBe(0);
      await page.close();
    });
  }
});
