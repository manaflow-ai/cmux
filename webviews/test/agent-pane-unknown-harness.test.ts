// l10n-allow-file: test fixture prompts, not shipped UI.
// A chat with a harness the model catalog does not know (a user's own ACP agent in acpmux's
// config) still draws after its first prompt (cx-us3l3). acpmux reports such a session with no
// models, modes or config options; the pane showed "The agent pane could not be drawn" the moment
// the prompt went out, on every build, before the agent said anything. The session summary below
// is acpmux's own, from a capture run's wire log.
//
// Real Chromium from Playwright; skipped where it is not installed (the hosted webviews job).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-unknown-harness.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-unknown-harness: skipping (run `bunx playwright install chromium`)");
    describe.skip("unknown harness", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const SESSION = "01a1392b-f140-7862-9d1a-7411b3080fdc";
  const CWD = "/home/dev/cg-next-reds";
  // acpmux's summary of a new chat on a harness it only knows from config.
  const summary = {
    harness: "scripted",
    eventCount: 7,
    lastMessage: null,
    pendingPermissions: 0,
    policy: null,
    queuePaused: false,
    moving: false,
    family: "scripted",
    preview: null,
    steering: false,
    updatedAt: Date.now(),
    agentCapabilities: { loadSession: false },
    configOptions: null,
    queued: 0,
    currentModeId: null,
    usage: null,
    pending: [],
    lastPrompt: null,
    turn: null,
    turnCount: 0,
    indicator: null,
    createdAt: Date.now(),
    name: "scripted",
    shown: true,
    model: null,
    enforcement: {
      policy: "ask",
      label: "native_policy",
      detail: "scripted mode unknown; acpmux policy ask (the daemon default); host isolation unverified",
      isolation: "unverified",
    },
    models: null,
    status: "ready",
    attached: 1,
    tags: {},
    unread: false,
    cwd: CWD,
    lastSeq: 7,
    agentSessionId: "scripted-session-0001",
    rules: false,
    modes: null,
    agentInfo: { name: "scripted", version: "0" },
    parentId: null,
    queue: [],
    rulesJson: null,
    sessionId: SESSION,
    title: null,
    lastTurn: null,
    stateSeq: 2,
    forkSeq: null,
  };
  const harnesses = {
    diagnostics: [],
    defaults: {},
    families: { scripted: ["scripted"] },
    harnesses: {
      scripted: {
        family: "scripted",
        argv: ["/usr/bin/python3", "agent.py"],
        description: "Scripted turn",
      },
    },
  };
  const prompts: Record<string, unknown>[] = [];
  /// The daemon's first prompt, and its answer to the trust check (the last thing an opening pane asks).
  let prompted: () => void = () => {};
  const firstPrompt = new Promise<void>((resolve) => (prompted = resolve));
  let trusted: () => void = () => {};
  const trustAnswered = new Promise<void>((resolve) => (trusted = resolve));
  /// `promise`, or a failure naming `what` after `ms`.
  const within = (promise: Promise<void>, ms: number, what: string) =>
    Promise.race([
      promise,
      new Promise<void>((_, reject) => setTimeout(() => reject(new Error(`no ${what} in ${ms} ms`)), ms)),
    ]);

  function answer(method: string, params: Record<string, any>): unknown {
    switch (method) {
      case "initialize":
        return {
          protocolVersion: 1,
          _meta: { acpmux: { origin: "local", extensions: [], operations: [] } },
        };
      case "_acpmux/watch":
        return { sessions: [summary] };
      case "_acpmux/attach":
        return { session: summary, lastSeq: 7, events: [], hasMore: false };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: 7 };
      case "_acpmux/harnesses":
        return harnesses;
      case "_acpmux/models":
        return { catalog: { schemaVersion: 1 }, harnesses: [] };
      case "acp.trust.get":
        return { harnesses: {}, decided: true, level: "trusted", cwd: params.cwd ?? CWD };
      default:
        return null;
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
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
            params?: Record<string, any>;
          };
          // The agent has not answered yet: acpmux holds the prompt's reply until the turn ends.
          if (message.method === "session/prompt") {
            prompts.push(message.params ?? {});
            prompted();
            return;
          }
          if (message.id !== undefined)
            ws.send(
              JSON.stringify({
                jsonrpc: "2.0",
                id: message.id,
                result: answer(message.method, message.params ?? {}),
              }),
            );
          if (message.method === "acp.trust.get") trusted();
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
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  test("a chat on a harness the catalog does not know still draws after its first prompt", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await installPaintedFrames(page);
    const errors: string[] = [];
    page.on("pageerror", (error) => errors.push(`${error.message}\n${error.stack ?? ""}`));
    page.on("console", (message) => message.type() === "error" && errors.push(message.text()));
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
    const drawn = page.locator(".acpmux-composer-prompt, .acpmux-pane-failed").first();
    await drawn.waitFor({ timeout: 60_000 });
    // The pane has heard everything it asked while opening, and drawn what that earns.
    await within(trustAnswered, 15_000, "trust check from the opening pane");
    await page.evaluate(() => window.cmuxPaintFrame());
    const failedOpening = await page.locator(".acpmux-pane-failed").count();
    let failedSending = failedOpening;
    if (!failedOpening) {
      await page.locator(".acpmux-composer-prompt").click();
      await page.keyboard.type("Is feat-cmux-next green?");
      await page.keyboard.press("Enter");
      // Wait for the prompt to reach the daemon (the composer's own text would satisfy a text wait at once),
      // then for the transcript to draw it, or for the pane to fail drawing it.
      await within(firstPrompt, 15_000, "prompt at the daemon");
      await page
        .locator(".acpmux-scroll")
        .getByText("Is feat-cmux-next green?")
        .or(page.locator(".acpmux-pane-failed"))
        .first()
        .waitFor({ timeout: 15_000 });
      failedSending = await page.locator(".acpmux-pane-failed").count();
    }
    if (failedOpening || failedSending) console.error(errors.join("\n---\n"));
    expect({ failedOpening, failedSending, prompts: prompts.length }).toEqual({
      failedOpening: 0,
      failedSending: 0,
      prompts: 1,
    });
    await page.close();
  });
});
