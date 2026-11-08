// `/side` in the real agent pane, backed by a protocol mock (https://github.com/manaflow-ai/cmux/issues/38042).
//
// The page is the pane's dev entry (vite.config.acpmux-pane.mjs) with its browser host, talking
// JSON-RPC over a WebSocket to a stand-in acpmux daemon whose chat has a turn running.
//
// - `/side <prompt>` mid-turn forks the chat as it is now (`acp.session.fork` with `live`), has
//   acpmux tag the fork the chat's side chat (`_acpmux/side`), asks the app to open it as a split
//   right of the chat (`chat.sideChat` with `split: "right"`), then sends the prompt to the fork. The chat itself gets no prompt, no
//   steer and no cancel, and its turn keeps streaming.
// - A bare `/side` opens the side chat and prompts nothing.
// - An idle chat forks through its latest turn (`throughSeq`), not live.
//
// Real Chromium from Playwright (`chromium.launch`); CI fails the file when it cannot launch
// (requireBrowserLane). The only `webkit` here is the `window.webkit.messageHandlers` bridge the
// page talks to, not the engine.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-side-command.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch (error) {
    console.warn("agent-pane-side-command: skipping (run `bunx playwright install chromium`):", error);
    describe.skip("side command", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const MAIN = "side-main";
  const IDLE = "side-idle";
  const FORK = "side-fork-1";
  const PROMPT = "sketch a second approach with a queue";
  const turn = { turnId: "turn-1", promptId: "p-turn", startedAt: Date.now(), prompt: "Fix the flaky retry test" };
  const base = { cwd: "/home/dev/api", harness: "claude", steering: false, queued: 0, queue: [] };
  const main = { ...base, sessionId: MAIN, title: turn.prompt, status: "running", turn, updatedAt: Date.now() };
  const idle = { ...base, sessionId: IDLE, title: "Explain the cache", status: "idle", updatedAt: Date.now() };
  const fork = { ...base, sessionId: FORK, title: turn.prompt, status: "idle", updatedAt: Date.now() };
  const record = (sessionId: string, seq: number, kind: string, msg: Record<string, unknown>) => ({
    sessionId,
    seq,
    at: Date.now(),
    dir: "mux",
    kind,
    msg,
  });
  const opening = [
    record(MAIN, 1, "user_message", { text: turn.prompt, promptId: "p-turn", turnId: "turn-1" }),
    record(MAIN, 2, "turn_started", { prompt: turn.prompt, promptId: "p-turn", turnId: "turn-1" }),
  ];
  const idleOpening = [
    record(IDLE, 1, "user_message", { text: "Explain the cache", promptId: "p-1", turnId: "t-1" }),
    record(IDLE, 2, "turn_started", { prompt: "Explain the cache", promptId: "p-1", turnId: "t-1" }),
    record(IDLE, 3, "turn_result", { promptId: "p-1", turnId: "t-1", stopReason: "end_turn" }),
    record(IDLE, 4, "turn_end", { promptId: "p-1", turnId: "t-1" }),
  ];
  let seq = opening.length;
  const forks: Record<string, unknown>[] = [];
  const sides: Record<string, unknown>[] = [];
  const prompts: Record<string, any>[] = [];
  const cancels: Record<string, unknown>[] = [];
  /// acpmux refuses the fork.
  let refuseFork = false;
  let mainSocket: { send(data: string): void } | undefined;

  function answer(method: string, params: Record<string, any>): { result?: unknown; error?: unknown } {
    switch (method) {
      case "initialize":
        return {
          result: {
            protocolVersion: 1,
            _meta: { acpmux: { origin: "local", extensions: [], operations: ["acp.session.fork"] } },
          },
        };
      case "_acpmux/watch":
        return { result: { sessions: [main, idle, fork] } };
      case "_acpmux/attach":
        if (params.sessionId === FORK) return { result: { session: fork, lastSeq: 0, events: [] } };
        if (params.sessionId === IDLE) return { result: { session: idle, lastSeq: 4, events: idleOpening } };
        return { result: { session: main, lastSeq: opening.length, events: opening } };
      case "_acpmux/events":
        return { result: { events: [], hasMore: false, lastSeq: params.sessionId === MAIN ? seq : 0 } };
      case "acp.session.fork":
        forks.push(params);
        return refuseFork
          ? { error: { code: -32000, message: "the agent is busy compacting" } }
          : { result: { sessionId: FORK } };
      case "_acpmux/side":
        sides.push(params);
        return { result: null };
      default:
        return { result: null };
    }
  }

  /// The chat's turn streams on: one more reply chunk, as acpmux pushes it.
  function stream(text: string): void {
    const msg = {
      method: "session/update",
      params: {
        sessionId: "agent-1",
        update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } },
      },
    };
    const event = { sessionId: MAIN, seq: ++seq, at: Date.now(), dir: "in", kind: "agent_message_chunk", msg };
    mainSocket?.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }));
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
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          const params = message.params ?? {};
          if (message.method === "session/prompt") {
            prompts.push(params);
            promptArrived?.();
          }
          if (message.method === "session/cancel") cancels.push(params);
          if (message.method === "_acpmux/attach" && params.sessionId === MAIN) mainSocket = ws;
          // A prompt gets no reply until its turn ends; this stand-in never gives it one.
          if (message.id !== undefined && message.method !== "session/prompt")
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, ...answer(message.method, params) }));
        },
      },
    });
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      configLoader: "native",
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: null },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/");
    browser = await chromium.launch({ headless: true });
    // A cold dev server's first load can stall in CI: load it once here so the tests time only /side.
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url(MAIN));
        await warm.locator(".acpmux-composer-prompt").waitFor({ timeout: 25_000 });
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

  function url(session: string): string {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${session}`;
  }

  /// Opens `session`, recording what the page asks the app to open (`chat.sideChat`) on top of the
  /// dev host.
  async function openChat(session: string): Promise<Page> {
    forks.length = 0;
    sides.length = 0;
    prompts.length = 0;
    cancels.length = 0;
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.addInitScript(() => {
      const sideChats: unknown[] = [];
      const handlers: Record<string, unknown> = {};
      let host: { postMessage(message: unknown): Promise<unknown> } | undefined;
      Object.defineProperty(handlers, "cmuxPage", {
        configurable: true,
        enumerable: true,
        get: () =>
          host && {
            postMessage(message: { t?: string; id?: number; op?: string; params?: unknown }) {
              if (message?.t === "call" && message.op === "cmux.agent.pane.tabState")
                return Promise.resolve({ t: "ok", id: message.id, value: { version: 1 } });
              if (message?.t === "call" && message.op === "cmux.agent.chat.sideChat") {
                sideChats.push(message.params);
                return Promise.resolve({ t: "ok", id: message.id, value: null });
              }
              return host!.postMessage(message);
            },
          },
        set: (value: typeof host) => {
          host = value;
        },
      });
      Object.assign(window, { sideChats, webkit: { messageHandlers: handlers } });
    });
    await page.goto(url(session));
    await page.locator(".acpmux-composer-prompt").waitFor();
    if (session === MAIN) await page.getByRole("button", { name: "Stop" }).waitFor();
    return page;
  }

  const composerText = async (page: Page) =>
    (await page.locator(".acpmux-composer-prompt .ProseMirror").innerText()).trim();
  const sideChats = (page: Page) =>
    page.evaluate(() => (window as unknown as { sideChats: Record<string, unknown>[] }).sideChats);
  /// Resolves on the stand-in daemon's first `session/prompt` (or at once when one came already).
  let promptArrived: (() => void) | undefined;
  const firstPrompt = () =>
    prompts.length > 0 ? Promise.resolve() : new Promise<void>((resolve) => (promptArrived = resolve));
  /// Resolves once the page asked the app to open a side chat.
  const sideChatOpened = (page: Page) =>
    page.waitForFunction(() => (window as unknown as { sideChats: unknown[] }).sideChats.length > 0, undefined, {
      timeout: 15_000,
    });

  async function type(page: Page, text: string): Promise<void> {
    await page.locator(".acpmux-composer-prompt").click();
    await page.keyboard.type(text);
    await page.keyboard.press("Enter");
  }

  describe("side command", () => {
    test("/side <prompt> mid-turn forks the chat live, opens it beside, and prompts only the fork", async () => {
      const page = await openChat(MAIN);
      await type(page, `/side ${PROMPT}`);
      await firstPrompt();
      expect(forks).toEqual([{ sessionId: MAIN, live: true }]);
      expect(sides).toEqual([{ sessionId: FORK, chat: MAIN }]);
      expect(await sideChats(page)).toEqual([{ sessionId: FORK, split: "right" }]);
      expect(prompts.map((prompt) => prompt.sessionId)).toEqual([FORK]);
      expect(JSON.stringify(prompts[0]?.prompt)).toContain(PROMPT);
      expect(cancels).toEqual([]);
      expect(await composerText(page)).toBe("");
      expect(await page.locator(".acpmux-attachment-note").count()).toBe(0);
      // The chat's own turn goes on.
      stream("Still working on the retry helper.");
      await page.getByText("Still working on the retry helper.").waitFor();
      expect(await page.getByRole("button", { name: "Stop" }).isVisible()).toBe(true);
      await page.close();
    });

    test("a bare /side opens the side chat and prompts nothing", async () => {
      const page = await openChat(MAIN);
      await type(page, "/side");
      await sideChatOpened(page);
      expect(await sideChats(page)).toEqual([{ sessionId: FORK, split: "right" }]);
      expect(forks).toEqual([{ sessionId: MAIN, live: true }]);
      expect(sides).toEqual([{ sessionId: FORK, chat: MAIN }]);
      expect(await composerText(page)).toBe("");
      expect(prompts).toEqual([]);
      expect(cancels).toEqual([]);
      await page.close();
    });

    test("a refused fork keeps /side <prompt> in the composer and says why", async () => {
      refuseFork = true;
      try {
        const page = await openChat(MAIN);
        await type(page, `/side ${PROMPT}`);
        await page.locator(".acpmux-attachment-note").getByText("the agent is busy compacting").waitFor();
        expect(await composerText(page)).toBe(`/side ${PROMPT}`);
        expect(sides).toEqual([]);
        expect(await sideChats(page)).toEqual([]);
        expect(prompts).toEqual([]);
        expect(cancels).toEqual([]);
        await page.close();
      } finally {
        refuseFork = false;
      }
    });

    test("an idle chat's /side forks through its latest turn", async () => {
      const page = await openChat(IDLE);
      await type(page, `/side ${PROMPT}`);
      await firstPrompt();
      expect(forks).toHaveLength(1);
      expect(forks[0]?.sessionId).toBe(IDLE);
      expect(forks[0]?.live).toBeUndefined();
      expect(typeof forks[0]?.throughSeq).toBe("number");
      expect(prompts.map((prompt) => prompt.sessionId)).toEqual([FORK]);
      await page.close();
    });
  });
});
