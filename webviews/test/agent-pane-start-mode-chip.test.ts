// l10n-allow-file: test fixture prompts, replies and mode names, not shipped UI.
// A new chat's mode chip names the mode acpmux will start it in (cx-wx93i), as acpmux answers it
// (`_acpmux/start_mode`), never the pane's own guess. A mode picked in a chat holds for that chat
// only (hub/start_mode.rs; Leo 2026-10-21), so after Manual is picked in one pane, a new chat in
// another pane that has not started yet still shows the default, Bypass permissions; a change to
// the default (Settings) reaches it. When acpmux would set no mode (a profile that pins it, a
// preset's chat) the chip names none. Two pages of one browser are two panes sharing the viewer's storage, each talking
// JSON-RPC to a stand-in acpmux daemon.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type BrowserContext, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-start-mode-chip.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-start-mode-chip: skipping (run `bunx playwright install chromium`)");
    describe.skip("start mode chip", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const START = Date.UTC(2026, 9, 14, 9, 0, 0);
  const modes = (current: string) => ({
    currentModeId: current,
    availableModes: [
      { id: "default", name: "Manual", description: "Always ask before making changes" },
      { id: "acceptEdits", name: "Accept edits", description: "Edit files without asking" },
      { id: "plan", name: "Plan", description: "Create a plan before making changes" },
      { id: "bypassPermissions", name: "Bypass permissions", description: "Accepts all permissions" },
    ],
  });
  // Two chats acpmux started in full access, one in each pane.
  const chat = (sessionId: string, title: string, reply: string) => {
    const session = {
      sessionId,
      cwd: "/home/dev/uploader",
      title,
      harness: "claude",
      family: "claude",
      model: "claude-sonnet",
      status: "idle",
      turnCount: 1,
      updatedAt: START,
      modes: modes("bypassPermissions"),
    };
    const steps: [string, string, Record<string, unknown>][] = [
      ["mux", "user_message", { text: title }],
      ["mux", "turn_started", {}],
      [
        "in",
        "agent_message_chunk",
        {
          method: "session/update",
          params: {
            sessionId,
            update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: reply } },
          },
        },
      ],
      ["mux", "turn_result", { status: "completed" }],
    ];
    const events = steps.map(([dir, kind, msg], index) => ({
      sessionId,
      seq: index + 1,
      at: START + index * 1000,
      dir,
      kind,
      msg,
    }));
    return { session, events };
  };
  const chats = new Map(
    [
      chat("0190a000-0000-7000-8000-0000000000e1", "Uploader retry", "Retry added."),
      chat("0190a000-0000-7000-8000-0000000000e2", "Docs pass", "Docs updated."),
    ].map((entry) => [entry.session.sessionId, entry]),
  );
  const [PICKED, OTHER] = [...chats.keys()];
  const calls: { method: string; params: Record<string, any> }[] = [];
  /// Who waits for the first call of a method.
  const waiting = new Map<string, (() => void)[]>();
  /// Settles once the daemon has had a call of `method` since the last reset.
  const called = (method: string) =>
    calls.some((call) => call.method === method)
      ? Promise.resolve()
      : new Promise<void>((resolve) => waiting.set(method, [...(waiting.get(method) ?? []), resolve]));
  const sockets = new Set<Bun.ServerWebSocket<unknown>>();
  // What the stand-in acpmux starts a new chat in: the default, full access unless a test changes it.
  // `pinned`: a harness whose profile pins its mode, so acpmux sets none.
  const daemonState = { startMode: "bypassPermissions", pinned: false };
  const reset = (pinned: boolean) => {
    calls.length = 0;
    daemonState.startMode = "bypassPermissions";
    daemonState.pinned = pinned;
    for (const entry of chats.values()) entry.session = { ...entry.session, modes: modes("bypassPermissions") };
  };

  /// The answer to one request; `undefined` holds it (a new chat acpmux has not started yet).
  function answer(method: string, params: Record<string, any>): unknown {
    calls.push({ method, params });
    for (const resolve of waiting.get(method) ?? []) resolve();
    waiting.delete(method);
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [...chats.values()].map((entry) => entry.session) };
      case "_acpmux/attach": {
        const entry = chats.get(String(params.sessionId))!;
        return { session: entry.session, lastSeq: entry.events.length, events: entry.events };
      }
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: chats.get(String(params.sessionId))?.events.length ?? 0 };
      case "session/set_mode": {
        // acpmux switches that chat only, then tells every watcher the chat's new mode. New chats'
        // start mode does not change, so it sends no `_acpmux/start_mode_changed`.
        const entry = chats.get(String(params.sessionId))!;
        entry.session = { ...entry.session, modes: modes(String(params.modeId)) };
        const changed = JSON.stringify({
          jsonrpc: "2.0",
          method: "_acpmux/session_changed",
          params: { sessionId: entry.session.sessionId, session: entry.session, kind: "mode", recordKind: "mode" },
        });
        queueMicrotask(() => {
          for (const socket of sockets) socket.send(changed);
        });
        return null;
      }
      case "_acpmux/start_mode": {
        const modeId = daemonState.pinned ? null : daemonState.startMode;
        const level = modeId === "bypassPermissions" ? "fullAccess" : modeId ? "ask" : null;
        return { harness: params.harness, modeId, level, source: modeId ? "settings" : null };
      }
      case "session/new":
        return undefined;
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
        open(ws) {
          sockets.add(ws);
        },
        close(ws) {
          sockets.delete(ws);
        },
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          if (message.id === undefined) return;
          const result = answer(message.method, message.params ?? {});
          if (result !== undefined) ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
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
    // again if it stalls, so the test times only the panes.
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url(OTHER));
        await warm.getByText("Docs updated.").waitFor({ timeout: 25_000 });
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

  /// A pane's page, whose socket notes each `_acpmux/start_mode` it asks and whether its answer came.
  async function pane(context: BrowserContext): Promise<Page> {
    const page = await context.newPage();
    await installPaintedFrames(page);
    await page.addInitScript(() => {
      const asks: { id: unknown; answered: boolean }[] = [];
      const noted = new WeakSet<WebSocket>();
      (window as unknown as { __startModeAsks: typeof asks }).__startModeAsks = asks;
      const send = WebSocket.prototype.send;
      WebSocket.prototype.send = function (this: WebSocket, data) {
        const message = typeof data === "string" ? (JSON.parse(data) as { id?: unknown; method?: string }) : {};
        if (message.method === "_acpmux/start_mode") {
          asks.push({ id: message.id, answered: false });
          if (!noted.has(this)) {
            noted.add(this);
            this.addEventListener("message", (event) => {
              const reply = JSON.parse(String(event.data)) as { id?: unknown; method?: string };
              if (reply.method !== undefined) return;
              for (const ask of asks) if (ask.id === reply.id) ask.answered = true;
            });
          }
        }
        return send.call(this, data);
      };
    });
    return page;
  }
  /// How many `_acpmux/start_mode` asks `page` has sent.
  const asked = (page: Page) =>
    page.evaluate(() => (window as unknown as { __startModeAsks: unknown[] }).__startModeAsks.length);
  /// Starts a new chat in `page`; returns how many start mode asks it had sent before.
  async function startNewChat(page: Page): Promise<number> {
    const before = await asked(page);
    await page.evaluate(() => {
      const actions = (window as { cmuxAcpmuxActions?: Record<string, (params: object) => Promise<unknown>> })
        .cmuxAcpmuxActions;
      void actions?.["chat.new"]?.({ harness: "claude" });
    });
    return before;
  }

  /// Picks Manual in a pane on PICKED, then starts a new chat in a pane on OTHER that acpmux has not
  /// started yet (session/new is held), and returns that pane on the new chat.
  async function newChatAfterPick() {
    const context = await browser!.newContext({ viewport: { width: 900, height: 760 } });
    // The pane that will start the new chat shows its own chat, in full access.
    const other = await pane(context);
    await other.goto(url(OTHER));
    await other.getByText("Docs updated.").waitFor();
    await other.waitForFunction(
      (selector) => document.querySelector(selector)?.textContent === "Bypass permissions",
      CHIP,
    );
    // In another pane the person picks Manual.
    const picked = await pane(context);
    await picked.goto(url(PICKED));
    await picked.getByText("Retry added.").waitFor();
    await picked.locator(".acpmux-access-trigger").click();
    await picked.locator(".acpmux-access-menu .acpmux-access-item", { hasText: "Manual" }).click();
    expect(calls.filter((call) => call.method === "session/set_mode").map((call) => call.params.modeId)).toEqual([
      "default",
    ]);
    await picked.waitForFunction((selector) => document.querySelector(selector)?.textContent === "Manual", CHIP);
    // A new chat in the first pane.
    const asks = await startNewChat(other);
    await called("session/new");
    // The new chat draws in place of the old one.
    await other.getByText("Docs updated.").waitFor({ state: "detached" });
    return { context, other, asks };
  }
  const CHIP = ".acpmux-access-trigger .acpmux-mode-text";
  /// The chip's text once it settles: the new chat has asked acpmux its start mode (after the
  /// page's first `after` asks), every answer has come, and two frames have painted since with no
  /// new ask (an answer may make the chat ask again).
  async function settledChip(page: Page, after: number): Promise<string | null> {
    for (let sent = -1, tries = 0; tries < 20; tries++) {
      await page.waitForFunction(
        (after) => {
          const asks = (window as unknown as { __startModeAsks: { answered: boolean }[] }).__startModeAsks.slice(after);
          return asks.length > 0 && asks.every((ask) => ask.answered);
        },
        after,
        { timeout: 10_000 },
      );
      await page.evaluate(() => window.cmuxPaintFrame().then(() => window.cmuxPaintFrame()));
      const now = await asked(page);
      if (now === sent) break;
      sent = now;
    }
    return page.locator(CHIP).first().textContent();
  }

  test("a new chat shows the default, not a mode picked in another chat", async () => {
    reset(false);
    const { context, other, asks } = await newChatAfterPick();
    // acpmux answers the start mode: the default, Bypass permissions.
    expect(await settledChip(other, asks)).toBe("Bypass permissions");
    expect(calls.some((call) => call.method === "_acpmux/start_mode" && call.params.harness === "claude")).toBe(true);
    await context.close();
  });

  test("a new chat names no mode when acpmux sets none", async () => {
    // The profile pins its mode: acpmux starts the chat in none of its own.
    reset(true);
    const { context, other, asks } = await newChatAfterPick();
    expect(await settledChip(other, asks)).toBe("Mode");
    await context.close();
  });
  test("a pending chat keeps the default when a mode is picked in another chat", async () => {
    reset(false);
    const context = await browser!.newContext({ viewport: { width: 900, height: 760 } });
    // The new chat opens first, in full access, and acpmux has not started it (session/new held).
    const other = await pane(context);
    await other.goto(url(OTHER));
    await other.getByText("Docs updated.").waitFor();
    const asks = await startNewChat(other);
    await other.getByText("Docs updated.").waitFor({ state: "detached" });
    expect(await settledChip(other, asks)).toBe("Bypass permissions");
    // A sessionless pending chat still exposes the harness-specific full-access mode as a real
    // menu, rather than a disabled placeholder. The same path works for Claude and Codex mode ids.
    const pendingAccess = other.locator(".acpmux-access-trigger");
    expect(await pendingAccess.isEnabled()).toBe(true);
    await pendingAccess.click();
    await other.locator(".acpmux-access-menu .acpmux-access-item", { hasText: "Bypass permissions" }).waitFor();
    expect(
      await other
        .locator(".acpmux-access-menu .acpmux-access-item", { hasText: "Bypass permissions" })
        .getAttribute("aria-checked"),
    ).toBe("true");
    await other.keyboard.press("Escape");
    // Then the person picks Manual in another pane: that chat says Manual, the pending chat still
    // names the default.
    const picked = await pane(context);
    await picked.goto(url(PICKED));
    await picked.getByText("Retry added.").waitFor();
    await picked.locator(".acpmux-access-trigger").click();
    await picked.locator(".acpmux-access-menu .acpmux-access-item", { hasText: "Manual" }).click();
    await picked.waitForFunction((selector) => document.querySelector(selector)?.textContent === "Manual", CHIP);
    expect(await settledChip(other, asks)).toBe("Bypass permissions");
    expect(calls.some((call) => call.method === "session/prompt")).toBe(false);
    await context.close();
  });

  test("returning to the pane asks acpmux nothing; a pushed change still reaches the chip", async () => {
    reset(false);
    const context = await browser!.newContext({ viewport: { width: 900, height: 760 } });
    const other = await pane(context);
    await other.goto(url(OTHER));
    await other.getByText("Docs updated.").waitFor();
    const opened = await startNewChat(other);
    await other.getByText("Docs updated.").waitFor({ state: "detached" });
    expect(await settledChip(other, opened)).toBe("Bypass permissions");
    const asks = () => calls.filter((call) => call.method === "_acpmux/start_mode").length;
    const before = asks();
    const sent = await asked(other);
    // The person switches away and back: the pane is shown and focused again, twice.
    for (let round = 0; round < 2; round++) {
      await other.evaluate(() => {
        document.dispatchEvent(new Event("visibilitychange"));
        window.dispatchEvent(new Event("focus"));
      });
    }
    // The page has handled both rounds and painted since: it sent no ask.
    await other.evaluate(() => window.cmuxPaintFrame().then(() => window.cmuxPaintFrame()));
    expect(await asked(other)).toBe(sent);
    expect(asks()).toBe(before);
    // Settings changes the default meanwhile: acpmux pushes `_acpmux/start_mode_changed` (it watches
    // the settings file), and the pending chat asks once and names the new mode.
    daemonState.startMode = "default";
    const notice = JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/start_mode_changed", params: {} });
    for (const socket of sockets) socket.send(notice);
    await other.waitForFunction((selector) => document.querySelector(selector)?.textContent === "Manual", CHIP, {
      timeout: 10_000,
    });
    // Once every answer is in, the push is the only ask since the rounds: a re-ask the rounds set
    // off later would have landed by now.
    expect(await settledChip(other, sent)).toBe("Manual");
    expect(await asked(other)).toBe(sent + 1);
    expect(asks()).toBe(before + 1);
    await context.close();
  });
});
