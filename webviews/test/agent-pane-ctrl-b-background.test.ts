// l10n-allow-file: test fixture prompts and commands, not shipped UI.
// Ctrl-B moves a Claude Code chat's running work to the background, as in Claude Code
// (conversation/runInBackground.ts): a running command's row says "⌃B to run in background", and
// Ctrl-B, with the composer focused too, asks acpmux `_acpmux/process/background`. A chat whose
// turn holds no running call keeps Ctrl-B for the composer's caret, and a Codex chat never shows
// the hint. The page is the pane's dev entry with its browser host, talking JSON-RPC to a
// stand-in acpmux daemon.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

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
  const START = Date.UTC(2026, 9, 20, 9, 0, 0);
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  const update = (update: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update },
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
  const chats: Record<string, { harness: string; steps: Step[] }> = {
    [CLAUDE]: {
      harness: "claude",
      steps: [
        ["mux", "user_message", { text: "Run the full test suite" }],
        ["mux", "turn_started", {}],
        say("Running the suite."),
        running("fg1", "cargo test --workspace"),
      ],
    },
    [CODEX]: {
      harness: "codex",
      steps: [
        ["mux", "user_message", { text: "Run the full test suite" }],
        ["mux", "turn_started", {}],
        say("Running the suite."),
        running("fg2", "cargo test --workspace"),
      ],
    },
    [IDLE]: {
      harness: "claude",
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
        return { backgrounded: true };
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
          if (message.id !== undefined)
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params) }));
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
    await page.goto(url(session));
    await page.getByText("Running the suite.").waitFor();
    return page;
  };
  const composer = (page: Page) => page.locator("[contenteditable=true]").first();

  test("a running command's row says Ctrl-B runs it in the background", async () => {
    const page = await open(CLAUDE);
    await page.getByText("⌃B to run in background").waitFor({ timeout: 5_000 });
    await page.close();
  });

  test("Ctrl-B in the composer moves the chat's running work to the background", async () => {
    backgrounded.length = 0;
    const page = await open(CLAUDE);
    await page.getByText("⌃B to run in background").waitFor({ timeout: 5_000 });
    await composer(page).click();
    await page.keyboard.press("Control+b");
    await page.waitForFunction(() => true);
    for (let wait = 0; wait < 50 && backgrounded.length === 0; wait++) await Bun.sleep(50);
    expect(backgrounded).toEqual([{ sessionId: CLAUDE }]);
    await page.close();
  });

  test("with no running call, Ctrl-B stays the composer's and asks nothing", async () => {
    backgrounded.length = 0;
    const page = await open(IDLE);
    await composer(page).click();
    await page.keyboard.type("ab");
    await page.keyboard.press("Control+b");
    await page.keyboard.type("X");
    await Bun.sleep(300);
    expect(backgrounded).toEqual([]);
    expect(await page.getByText("⌃B to run in background").count()).toBe(0);
    await page.close();
  });

  test("a Codex chat shows no hint and keeps Ctrl-B", async () => {
    backgrounded.length = 0;
    const page = await open(CODEX);
    await page.getByText("cargo test --workspace").first().waitFor();
    await composer(page).click();
    await page.keyboard.press("Control+b");
    await Bun.sleep(300);
    expect(backgrounded).toEqual([]);
    expect(await page.getByText("⌃B to run in background").count()).toBe(0);
    await page.close();
  });
});
