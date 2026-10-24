// `/btw` in the real agent pane, backed by a protocol mock. A running main
// turn must continue while a dismissible answer stays anchored in its transcript.
// Disabled or refused requests must never become a steer, prompt, or queue item.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-btw-side-session.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-btw-side-session: skipping (run `bunx playwright install chromium`)");
    describe.skip("btw side session", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const MAIN = "btw-main";
  const SIDE = "btw-side-1";
  const QUESTION = "why did the retry test flake?";
  const turn = { turnId: "turn-1", promptId: "p-turn", startedAt: Date.now(), prompt: "Fix the flaky retry test" };
  const main = {
    sessionId: MAIN,
    cwd: "/home/dev/api",
    title: "Fix the flaky retry test",
    harness: "claude",
    status: "running",
    steering: false,
    queued: 0,
    queue: [],
    turn,
    updatedAt: Date.now(),
  };
  const side = {
    sessionId: SIDE,
    cwd: "/home/dev/api",
    title: QUESTION,
    harness: "claude",
    status: "idle",
    tags: { side: MAIN },
    updatedAt: Date.now(),
  };
  const opening = [
    {
      sessionId: MAIN,
      seq: 1,
      at: Date.now(),
      dir: "mux",
      kind: "user_message",
      msg: { text: turn.prompt, promptId: "p-turn", turnId: "turn-1" },
    },
    {
      sessionId: MAIN,
      seq: 2,
      at: Date.now(),
      dir: "mux",
      kind: "turn_started",
      msg: { prompt: turn.prompt, promptId: "p-turn", turnId: "turn-1" },
    },
  ];
  let seq = opening.length;
  const btws: Record<string, unknown>[] = [];
  const prompts: Record<string, unknown>[] = [];
  const cancels: Record<string, unknown>[] = [];
  let mainSocket: { send(data: string): void } | undefined;
  /// The socket that last spoke to the daemon, and the chat it attached to.
  let lastSocket: { send(data: string): void } | undefined;
  let lastSession = MAIN;
  /// `_acpmux/events` reads: a lag resync's refetch.
  let eventReads = 0;

  /// The waits on what the daemon heard: each message it takes wakes them.
  const waiting = new Set<() => void>();
  /// Resolves once `condition` holds, checked as the daemon hears each message; fails naming `what`.
  const until = (condition: () => boolean, what: string, timeout = 5_000) =>
    new Promise<void>((resolve, reject) => {
      const check = () => {
        if (!condition()) return;
        waiting.delete(check);
        clearTimeout(timer);
        resolve();
      };
      const timer = setTimeout(() => {
        waiting.delete(check);
        reject(new Error(`the daemon never saw ${what} within ${timeout} ms`));
      }, timeout);
      waiting.add(check);
      check();
    });
  /// Returns once the page has answered a lag notice sent now (its refetch reached the daemon), so
  /// it has handled what came before, and a call it made before (a prompt, a /btw) has reached the daemon.
  async function settled(): Promise<void> {
    const before = eventReads;
    const notice = { jsonrpc: "2.0", method: "_acpmux/lagged", params: { sessionIds: [lastSession] } };
    lastSocket?.send(JSON.stringify(notice));
    await until(() => eventReads > before, "the lag resync's refetch");
  }

  function answer(method: string, params: Record<string, any>): { result?: unknown; error?: unknown } {
    switch (method) {
      case "initialize":
        return { result: { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [] } } } };
      case "_acpmux/watch":
        return { result: { sessions: [main, side] } };
      case "_acpmux/attach":
        return params.sessionId === SIDE
          ? { result: { session: side, lastSeq: 0, events: [] } }
          : { result: { session: main, lastSeq: opening.length, events: opening } };
      case "_acpmux/events":
        eventReads += 1;
        return { result: { events: [], hasMore: false, lastSeq: params.sessionId === SIDE ? 0 : seq } };
      case "_acpmux/btw":
        btws.push(params);
        return params.question === "refused"
          ? { error: { code: -32602, message: "This chat's agent can't start a side session." } }
          : {
              result: params.inline
                ? { text: "The retry timer raced the mocked clock." }
                : { sessionId: SIDE, model: "haiku", readOnly: "mode" },
            };
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
          if (message.method === "session/prompt") prompts.push(params);
          if (message.method === "session/cancel") cancels.push(params);
          if (message.method === "_acpmux/attach" && params.sessionId !== SIDE) mainSocket = ws;
          if (message.method === "_acpmux/attach") lastSession = String(params.sessionId);
          lastSocket = ws;
          // A prompt mid-turn gets no reply until its turn; this stand-in never gives it one.
          if (message.id !== undefined && message.method !== "session/prompt")
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, ...answer(message.method, params) }));
          for (const wake of waiting) wake();
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
    // A cold dev server's first load can stall in CI: load it once here so the tests time only /btw.
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

  /// Opens `session` with an optional explicit Side sessions (/btw) value (the `sideSessions` of
  /// the header state the app answers `pane.tabState` with), recording what the page asks the app to open
  /// (`chat.sideChat`) on top of the dev host. Omitting it exercises the shipped default.
  async function openChat(session: string, gate?: boolean): Promise<Page> {
    btws.length = 0;
    prompts.length = 0;
    cancels.length = 0;
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.addInitScript((gate: boolean | undefined) => {
      const sideChats: unknown[] = [];
      const handlers: Record<string, unknown> = {};
      let host: { postMessage(message: unknown): Promise<unknown> } | undefined;
      Object.defineProperty(handlers, "cmuxPage", {
        configurable: true,
        enumerable: true,
        get: () =>
          host && {
            postMessage(message: { t?: string; id?: number; op?: string; params?: unknown }) {
              // The chat's header state carries Debug Settings' Side sessions (/btw) toggle.
              if (message?.t === "call" && message.op === "cmux.agent.pane.tabState")
                return Promise.resolve({
                  t: "ok",
                  id: message.id,
                  value: { ...(gate === undefined ? {} : { sideSessions: gate }), version: 1 },
                });
              if (message?.t === "call" && message.op === "cmux.agent.chat.sideChat") {
                sideChats.push(message.params);
                // A test sets `refuseSideChat`: the app does not open the side session.
                if ((window as unknown as { refuseSideChat?: boolean }).refuseSideChat)
                  return Promise.resolve({
                    t: "err",
                    id: message.id,
                    code: "native.failed",
                    message: "The side pane didn't open.",
                  });
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
    }, gate);
    await page.goto(url(session));
    await page.locator(".acpmux-composer-prompt").waitFor();
    if (session === MAIN) await page.getByRole("button", { name: "Stop" }).waitFor();
    return page;
  }

  const composerText = async (page: Page) =>
    (await page.locator(".acpmux-composer-prompt .ProseMirror").innerText()).trim();
  const sideChats = (page: Page) =>
    page.evaluate(() => (window as unknown as { sideChats: Record<string, unknown>[] }).sideChats);

  async function type(page: Page, text: string): Promise<void> {
    await page.locator(".acpmux-composer-prompt").click();
    await page.keyboard.type(text);
    await page.keyboard.press("Enter");
  }

  describe("btw side session", () => {
    test("/btw mid-turn answers in a dismissible transcript aside without a steer, queue, or split", async () => {
      const page = await openChat(MAIN);
      await type(page, `/btw ${QUESTION}`);
      const aside = page.locator(".acpmux-btw-note");
      await aside.getByText("The retry timer raced the mocked clock.").waitFor({ timeout: 15_000 });
      expect(btws).toEqual([{ sessionId: MAIN, question: QUESTION, inline: true }]);
      expect(await sideChats(page)).toEqual([]);
      expect(await composerText(page)).toBe("");
      expect(prompts).toEqual([]);
      expect(cancels).toEqual([]);
      expect(await page.locator(".acpmux-queued").count()).toBe(0);
      stream("Still working on the retry helper.");
      await page.getByText("Still working on the retry helper.").waitFor();
      expect(await page.getByRole("button", { name: "Stop" }).isVisible()).toBe(true);
      await aside.getByRole("button", { name: "Dismiss" }).click();
      await aside.waitFor({ state: "detached" });
      stream("The main turn is still running.");
      await page.getByText("The main turn is still running.", { exact: false }).waitFor();
      expect(await aside.count()).toBe(0);
      expect(cancels).toEqual([]);
      await page.close();
    });

    test("a refused /btw keeps the question in its aside and never sends a main prompt", async () => {
      const page = await openChat(MAIN, true);
      await type(page, "/btw refused");
      await page.getByRole("alert").filter({ hasText: "This chat's agent can't start a side session." }).waitFor();
      expect(btws).toEqual([{ sessionId: MAIN, question: "refused", inline: true }]);
      expect(await sideChats(page)).toEqual([]);
      expect(await page.locator(".acpmux-btw-note").innerText()).toContain("refused");
      expect(prompts).toEqual([]);
      await page.close();
    });

    test("a side-session composer does not offer recursive /btw", async () => {
      const page = await openChat(SIDE, true);
      await page.keyboard.type("/");
      await page.locator(".acpmux-slash-menu").waitFor();
      expect(await page.locator(".acpmux-slash-menu").innerText()).not.toContain("Side question");
      expect(btws).toEqual([]);
      await page.close();
    });

    test("explicitly disabling /btw retains the question without steering the main turn", async () => {
      const page = await openChat(MAIN, false);
      await type(page, `/btw ${QUESTION}`);
      await settled();
      expect(btws).toEqual([]);
      expect(prompts).toEqual([]);
      expect(await composerText(page)).toBe(`/btw ${QUESTION}`);
      await page.close();
    });

    test("the palette's sideQuestion focuses the composer with /btw", async () => {
      const page = await openChat(MAIN, true);
      await page.evaluate(() =>
        (window as unknown as { cmuxAcpmuxBridge: { command(name: string): void } }).cmuxAcpmuxBridge.command(
          "sideQuestion",
        ),
      );
      await page.waitForFunction(
        () => document.querySelector(".acpmux-composer-prompt .ProseMirror")?.textContent === "/btw ",
      );
      expect(await page.evaluate(() => Boolean(document.activeElement?.closest(".acpmux-composer-prompt")))).toBe(true);
      await page.keyboard.type(QUESTION);
      await page.keyboard.press("Enter");
      await page.locator(".acpmux-btw-note").getByText("The retry timer raced the mocked clock.").waitFor();
      expect(btws).toEqual([{ sessionId: MAIN, question: QUESTION, inline: true }]);
      await page.close();
    });

    test("with Side sessions off, the palette's sideQuestion leaves the composer empty", async () => {
      const page = await openChat(MAIN, false);
      await page.evaluate(() =>
        (window as unknown as { cmuxAcpmuxBridge: { command(name: string): void } }).cmuxAcpmuxBridge.command(
          "sideQuestion",
        ),
      );
      await settled();
      expect(await composerText(page)).toBe("");
      await page.close();
    });

    test("turning Side sessions on reaches an open chat without reopening it", async () => {
      const page = await openChat(MAIN, false);
      await page.evaluate(() =>
        (
          window as unknown as { cmuxAcpmuxBridge: { applyHeaderState(state: unknown): void } }
        ).cmuxAcpmuxBridge.applyHeaderState({ sideSessions: true, version: 2 }),
      );
      await type(page, `/btw ${QUESTION}`);
      await page.locator(".acpmux-btw-note").getByText("The retry timer raced the mocked clock.").waitFor();
      expect(btws).toEqual([{ sessionId: MAIN, question: QUESTION, inline: true }]);
      await page.close();
    });
  });
});
