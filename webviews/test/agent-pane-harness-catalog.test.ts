// Leo 2026-10-12, on nightly-next: the Harnesses page called every harness "Not installed",
// Claude Code included. The pane's acpmux client fetches the harness list apart from the chat
// (catalog.ts), and the page drew from the client's own snapshot, whose list stays empty. The page is the pane's dev entry
// with its browser host, talking JSON-RPC to a stand-in acpmux daemon that has Claude Code.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-harness-catalog.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-harness-catalog: skipping (run `bunx playwright install chromium`)");
    describe.skip("harness catalog", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-0000000000c1";
  const START = Date.UTC(2026, 9, 12, 9, 0, 0);
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/app",
    title: "App",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 1,
    updatedAt: START,
  };
  const events = [
    {
      sessionId: CHAT,
      seq: 1,
      at: START,
      dir: "mux",
      kind: "user_message",
      msg: { text: "Hello" },
    },
    {
      sessionId: CHAT,
      seq: 2,
      at: START + 1000,
      dir: "in",
      kind: "agent_message_chunk",
      msg: {
        method: "session/update",
        params: {
          sessionId: "agent-1",
          update: {
            sessionUpdate: "agent_message_chunk",
            content: { type: "text", text: "Hi there." },
          },
        },
      },
    },
  ];
  // What acpmux answered on a Mac with Claude Code on PATH (nightly-next, 2026-10-12), cut down.
  const model = (id: string, shortName: string, family: string) => ({
    id,
    name: `Claude ${shortName}`,
    shortName,
    family,
  });
  const claudeModels = [
    { id: "default", name: "Default (Claude Code's choice)" },
    model("claude-fable-5-1", "Fable 5.1", "Fable"),
    model("claude-fable-5", "Fable 5", "Fable"),
    model("claude-opus-5-5", "Opus 5.5", "Opus"),
    model("claude-opus-5", "Opus 5", "Opus"),
    model("claude-opus-4-8", "Opus 4.8", "Opus"),
    model("claude-sonnet-5-5", "Sonnet 5.5", "Sonnet"),
    model("claude-sonnet-5", "Sonnet 5", "Sonnet"),
    model("claude-haiku-5-5", "Haiku 5.5", "Haiku"),
    model("claude-haiku-4-5", "Haiku 4.5", "Haiku"),
  ];
  const harnesses = {
    harnesses: {
      claude: {
        kind: "claude-stdio",
        description: "found on PATH",
        family: "claude",
      },
    },
    families: { claude: ["claude"] },
    defaultHarness: "claude",
  };
  const models = {
    harnesses: [
      {
        harness: "claude",
        kind: "claude-stdio",
        isDefault: true,
        models: claudeModels,
      },
    ],
  };

  function answer(method: string): unknown {
    switch (method) {
      case "initialize":
        return {
          protocolVersion: 1,
          _meta: {
            acpmux: { origin: "local", extensions: [], operations: [] },
          },
        };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: events.length, events };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: events.length };
      case "_acpmux/harnesses":
        return harnesses;
      case "_acpmux/models":
        return models;
      default:
        return null;
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${CHAT}`;
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
          const message = JSON.parse(String(raw)) as {
            id?: number;
            method: string;
          };
          if (message.id !== undefined)
            ws.send(
              JSON.stringify({
                jsonrpc: "2.0",
                id: message.id,
                result: answer(message.method),
              }),
            );
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
    // again if it stalls, so the test times only the page.
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url());
        await warm.getByText("Hi there.").waitFor({ timeout: 25_000 });
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

  test("the Harnesses page has Claude Code ready", async () => {
    const page = await browser!.newPage({
      viewport: { width: 900, height: 760 },
    });
    await page.goto(url());
    await page.getByText("Hi there.").waitFor();
    // Add harness& in the compact menu's More models submenu opens Harnesses in place. The
    // started-chat harness switch is enabled so this chat offers the harness rail and its action.
    // Cmd-Ctrl-M and the model button open this same compact picker.
    await page.evaluate(() => window.cmuxAcpmuxComposer?.({ harnessSwitch: true }));
    await page.locator(".acpmux-model .acpmux-picker-button").waitFor();
    await page.keyboard.press("Meta+Control+m");
    const menu = page.locator(".acpmux-quick-menu").first();
    await menu.waitFor();
    await menu.getByRole("menuitem", { name: "More models" }).hover();
    await page
      .locator(".acpmux-quick-more")
      .getByRole("menuitem", { name: /Add harness/ })
      .click();
    const claude = page.locator("[data-harness-row]").filter({ hasText: "Claude Code" });
    await claude.waitFor();
    expect(await claude.getAttribute("data-harness-status")).toBe("ready");
    await page.close();
  });
});
