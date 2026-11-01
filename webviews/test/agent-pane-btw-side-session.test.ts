// `/btw` in the real agent pane, backed by a protocol mock. A running main
// turn must continue while a dismissible answer stays anchored in its transcript.
// Disabled or refused requests must never become a steer, prompt, or queue item.
//
// The page is the pane's dev entry (vite.config.acpmux-pane.mjs) with its browser host, talking
// JSON-RPC over a WebSocket to a stand-in acpmux daemon whose chat has a turn running, plus one
// side session of that chat.
//
// - With the side-sessions gate on, `/btw <question>` mid-turn asks acpmux `_acpmux/btw` for a side
//   session, then asks the app to open it beside the chat (`chat.sideChat`). It is not a prompt:
//   nothing is queued or cancelled, the composer clears, and the chat's turn keeps streaming.
// - When acpmux refuses, the question stays in the composer and the reason shows above it.
// - With the gate off, `/btw` is not a cmux command: no side session starts.
// - A side session's composer says "Reply in this session…".
// - The palette's Side Question (`sideQuestion`, carrying the selected session) focuses the composer
//   with `/btw ` in it, and only for the shown, selected chat that is not itself a side session.
//
// Real Chromium from Playwright (`chromium.launch`); CI fails the file when it cannot launch
// (requireBrowserLane). The only `webkit` here is the `window.webkit.messageHandlers` bridge the
// page talks to, not the engine.
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
  /// A chat with no turn yet: it shows its empty state until something is in it.
  const EMPTY = "btw-empty";
  const QUESTION = "why did the retry test flake?";
  const turn = {
    turnId: "turn-1",
    promptId: "p-turn",
    startedAt: Date.now(),
    prompt: "Fix the flaky retry test",
  };
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
    side: true,
    updatedAt: Date.now(),
  };
  const empty = {
    sessionId: EMPTY,
    cwd: "/home/dev/api",
    title: "New chat",
    harness: "claude",
    status: "idle",
    steering: false,
    queued: 0,
    queue: [],
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
  let capabilities: string[] = ["btw-inline-v1"];
  let inlineHostFailure: "unsupported" | "trust.pending" | "trust.untrusted" | undefined;
  let trustMode = false;
  let trustResolved = false;
  let trustRefusalRemaining = 0;
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
    const notice = {
      jsonrpc: "2.0",
      method: "_acpmux/lagged",
      params: { sessionIds: [lastSession] },
    };
    lastSocket?.send(JSON.stringify(notice));
    await until(() => eventReads > before, "the lag resync's refetch");
  }

  function answer(method: string, params: Record<string, any>): { result?: unknown; error?: unknown } {
    switch (method) {
      case "initialize":
        return {
          result: {
            protocolVersion: 1,
            _meta: { acpmux: { origin: "local", extensions: [], capabilities } },
          },
        };
      case "_acpmux/watch":
        return { result: { sessions: [main, side, empty] } };
      case "_acpmux/attach":
        return params.sessionId === SIDE
          ? { result: { session: side, lastSeq: 0, events: [] } }
          : params.sessionId === EMPTY
            ? { result: { session: empty, lastSeq: 0, events: [] } }
            : { result: { session: main, lastSeq: opening.length, events: opening } };
      case "_acpmux/events":
        eventReads += 1;
        return {
          result: {
            events: [],
            hasMore: false,
            lastSeq: params.sessionId === SIDE || params.sessionId === EMPTY ? 0 : seq,
          },
        };
      case "acp.trust.get":
        return trustMode
          ? {
              result: {
                cwd: "/home/dev/api",
                level: trustResolved ? "trusted" : inlineHostFailure === "trust.untrusted" ? "untrusted" : "unknown",
              },
            }
          : { result: null };
      case "acp.trust.set":
        trustResolved = params.level === "trusted";
        if (params.level === "unknown") inlineHostFailure = "trust.pending";
        return { result: { cwd: params.cwd, level: params.level } };
      case "_acpmux/btw":
        btws.push(params);
        if (params.inline && trustRefusalRemaining > 0) {
          trustRefusalRemaining -= 1;
          trustResolved = false;
          return {
            error: {
              code: -32000,
              message: "Answer the folder trust question first",
              data: { reason: inlineHostFailure, cwd: "/home/dev/api" },
            },
          };
        }
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
    const event = {
      sessionId: MAIN,
      seq: ++seq,
      at: Date.now(),
      dir: "in",
      kind: "agent_message_chunk",
      msg,
    };
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
          const message = JSON.parse(String(raw)) as {
            id?: number;
            method: string;
            params?: Record<string, any>;
          };
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
  async function openChat(
    session: string,
    gate?: boolean,
    inline = true,
    hostFailure?: "unsupported" | "trust.pending" | "trust.untrusted",
    trust = false,
  ): Promise<Page> {
    capabilities = inline ? ["btw-inline-v1"] : [];
    inlineHostFailure = hostFailure;
    trustMode = trust;
    trustResolved = true;
    trustRefusalRemaining = hostFailure === "trust.pending" || hostFailure === "trust.untrusted" ? 1 : 0;
    btws.length = 0;
    prompts.length = 0;
    cancels.length = 0;
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.exposeFunction("btwNative", (params: Record<string, unknown>) =>
      hostFailure === "unsupported"
        ? { error: { code: "unsupported", message: "chat.btw.inline is unavailable" } }
        : (() => {
            const reply = answer("_acpmux/btw", { ...params, inline: true });
            return reply.error && hostFailure
              ? { error: { code: hostFailure, message: String((reply.error as any).message) } }
              : reply;
          })(),
    );
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
              if (message?.t === "call" && message.op === "cmux.agent.chat.btw.inline") {
                const native = window as unknown as {
                  btwNative(params: unknown): Promise<{
                    result?: unknown;
                    error?: { code?: string; message: string; details?: unknown };
                  }>;
                };
                return native.btwNative(message.params).then((reply) =>
                  reply.error
                    ? {
                        t: "err",
                        id: message.id,
                        code: reply.error.code ?? "btw_failed",
                        message: reply.error.message,
                        details:
                          reply.error.code === "trust.pending" || reply.error.code === "trust.untrusted"
                            ? {
                                origin: "session_host",
                                details: { reason: reply.error.code, cwd: "/home/dev/api" },
                              }
                            : undefined,
                      }
                    : { t: "ok", id: message.id, value: reply.result },
                );
              }
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

    test("an older daemon gets the legacy request and opens the side chat", async () => {
      const page = await openChat(MAIN, true, false);
      await type(page, `/btw ${QUESTION}`);
      await page.locator(".acpmux-btw-note").getByText("Opened a side session for this question.").waitFor();
      expect(btws).toEqual([{ sessionId: MAIN, question: QUESTION }]);
      expect(await sideChats(page)).toEqual([{ sessionId: SIDE }]);
      expect(prompts).toEqual([]);
      await page.close();
    });

    test("an advertised inline daemon falls back when the app host is too old", async () => {
      const page = await openChat(MAIN, true, true, "unsupported");
      await type(page, `/btw ${QUESTION}`);
      await page.locator(".acpmux-btw-note").getByText("Opened a side session for this question.").waitFor();
      expect(btws).toEqual([{ sessionId: MAIN, question: QUESTION }]);
      expect(await sideChats(page)).toEqual([{ sessionId: SIDE }]);
      await page.close();
    });

    for (const reason of ["trust.pending", "trust.untrusted"] as const) {
      test(`inline ${reason} shows Trust and retries the same aside`, async () => {
        const page = await openChat(MAIN, true, true, reason, true);
        await type(page, `/btw ${QUESTION}`);
        const aside = page.locator(".acpmux-btw-note");
        await aside.getByRole("alert").waitFor();
        expect(await aside.innerText()).toContain("Answer the folder trust question first");
        const trust = page.locator(".acpmux-trust-ask");
        if (reason === "trust.untrusted") {
          await trust.getByRole("button", { name: "Undo" }).click();
        }
        await trust.getByRole("button", { name: "Trust folder" }).click();
        await trust.waitFor({ state: "hidden" });
        await aside.getByRole("button", { name: "Retry" }).click();
        await aside.getByText("The retry timer raced the mocked clock.").waitFor();
        expect(btws).toEqual([
          { sessionId: MAIN, question: QUESTION, inline: true },
          { sessionId: MAIN, question: QUESTION, inline: true },
        ]);
        expect(await sideChats(page)).toEqual([]);
        await page.close();
      });
    }

    test("/btw in a chat with no turn yet leaves the empty state and shows its aside", async () => {
      const page = await openChat(EMPTY);
      // A chat with no turn shows its empty state until something is in it.
      await page.locator("[data-new-chat]").waitFor();
      await type(page, `/btw ${QUESTION}`);
      const aside = page.locator(".acpmux-btw-note");
      await aside.getByText("The retry timer raced the mocked clock.").waitFor({ timeout: 15_000 });
      expect(btws).toEqual([{ sessionId: EMPTY, question: QUESTION, inline: true }]);
      expect(prompts).toEqual([]);
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
      await page.locator(".acpmux-attachment-note").filter({ hasText: "Side questions are disabled" }).waitFor();
      await settled();
      expect(btws).toEqual([]);
      expect(prompts).toEqual([]);
      expect(await composerText(page)).toBe(`/btw ${QUESTION}`);
      await page.close();
    });

    test("the palette's sideQuestion focuses the composer with /btw", async () => {
      const page = await openChat(MAIN, true);
      await page.evaluate(
        (session) =>
          (
            window as unknown as { cmuxAcpmuxBridge: { command(name: string, sessionId?: string): void } }
          ).cmuxAcpmuxBridge.command("sideQuestion", session),
        MAIN,
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
      await page.evaluate(
        (session) =>
          (
            window as unknown as { cmuxAcpmuxBridge: { command(name: string, sessionId?: string): void } }
          ).cmuxAcpmuxBridge.command("sideQuestion", session),
        MAIN,
      );
      await settled();
      expect(await composerText(page)).toBe("");
      await page.close();
    });

    test("the palette drops a stale or side-session command instead of prefilling the wrong chat", async () => {
      const page = await openChat(MAIN, true);
      await page.evaluate(() =>
        (
          window as unknown as { cmuxAcpmuxBridge: { command(name: string, sessionId?: string): void } }
        ).cmuxAcpmuxBridge.command("sideQuestion", "a-session-that-is-no-longer-selected"),
      );
      expect(await composerText(page)).toBe("");
      await page.close();

      const sidePage = await openChat(SIDE, true);
      await sidePage.evaluate(
        (session) =>
          (
            window as unknown as { cmuxAcpmuxBridge: { command(name: string, sessionId?: string): void } }
          ).cmuxAcpmuxBridge.command("sideQuestion", session),
        SIDE,
      );
      expect(await composerText(sidePage)).toBe("");
      await sidePage.close();
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
