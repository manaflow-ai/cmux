// l10n-allow-file: test fixture prompts, replies and mode names, not shipped UI.
// A new chat's mode chip names the mode acpmux will start it in (cx-wx93i), as acpmux answers it
// (`_acpmux/start_mode`), never the pane's own guess. acpmux starts a new chat in the level of the
// person's latest mode pick (hub/start_mode.rs), so after Normal is picked in one pane, a new chat
// in another pane that has not started yet shows Normal, not the Full access its own pane's chat
// last reported. When acpmux would set no mode (a profile that pins it, a preset's chat) the chip
// names none. Two pages of one browser are two panes sharing the viewer's storage, each talking
// JSON-RPC to a stand-in acpmux daemon.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
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
      { id: "default", name: "Normal", description: "Ask before edits and commands" },
      { id: "acceptEdits", name: "Accept edits", description: "Edit files without asking" },
      { id: "plan", name: "Plan mode", description: "Read and plan, no edits" },
      { id: "bypassPermissions", name: "Full access", description: "Never ask" },
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
  const sockets = new Set<Bun.ServerWebSocket<unknown>>();
  // What the stand-in acpmux starts a new chat in: the latest pick's mode, else full access.
  // `pinned`: a harness whose profile pins its mode, so acpmux sets none and takes no pick.
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
        // acpmux takes the pick, then tells every watcher the chat's new mode.
        const entry = chats.get(String(params.sessionId))!;
        entry.session = { ...entry.session, modes: modes(String(params.modeId)) };
        const takes = !daemonState.pinned && params.modeId !== "plan" && daemonState.startMode !== params.modeId;
        if (takes) daemonState.startMode = String(params.modeId);
        const changed = JSON.stringify({
          jsonrpc: "2.0",
          method: "_acpmux/session_changed",
          params: { sessionId: entry.session.sessionId, session: entry.session, kind: "mode", recordKind: "mode" },
        });
        // A pick it takes as the start mode: every local watcher asks `_acpmux/start_mode` again.
        const notice = JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/start_mode_changed", params: {} });
        queueMicrotask(() => {
          for (const socket of sockets) {
            socket.send(changed);
            if (takes) socket.send(notice);
          }
        });
        return null;
      }
      case "_acpmux/start_mode": {
        const modeId = daemonState.pinned ? null : daemonState.startMode;
        const level = modeId === "bypassPermissions" ? "fullAccess" : modeId ? "ask" : null;
        return { harness: params.harness, modeId, level, source: modeId ? "pick" : null };
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

  /// Picks Normal in a pane on PICKED, then starts a new chat in a pane on OTHER that acpmux has not
  /// started yet (session/new is held), and returns that pane on the new chat.
  async function newChatAfterPick() {
    const context = await browser!.newContext({ viewport: { width: 900, height: 760 } });
    // The pane that will start the new chat shows its own chat, in full access.
    const other = await context.newPage();
    await other.goto(url(OTHER));
    await other.getByText("Docs updated.").waitFor();
    await other.waitForFunction((selector) => document.querySelector(selector)?.textContent === "Full access", CHIP);
    // In another pane the person picks Normal.
    const picked = await context.newPage();
    await picked.goto(url(PICKED));
    await picked.getByText("Retry added.").waitFor();
    await picked.locator(".acpmux-access-trigger").click();
    await picked.locator(".acpmux-access-menu .acpmux-access-item", { hasText: "Normal" }).click();
    expect(calls.filter((call) => call.method === "session/set_mode").map((call) => call.params.modeId)).toEqual([
      "default",
    ]);
    await picked.waitForFunction((selector) => document.querySelector(selector)?.textContent === "Normal", CHIP);
    // A new chat in the first pane.
    await other.evaluate(() => {
      const actions = (window as { cmuxAcpmuxActions?: Record<string, (params: object) => Promise<unknown>> })
        .cmuxAcpmuxActions;
      void actions?.["chat.new"]?.({ harness: "claude" });
    });
    for (let waited = 0; !calls.some((call) => call.method === "session/new"); waited += 50) {
      if (waited > 10_000) throw new Error("no session/new");
      await Bun.sleep(50);
    }
    // The new chat draws in place of the old one.
    await other.getByText("Docs updated.").waitFor({ state: "detached" });
    return { context, other };
  }
  const CHIP = ".acpmux-access-trigger .acpmux-mode-text";
  /// The chip's text once it settles: what it shows for half a second running.
  async function settledChip(page: Page): Promise<string | null> {
    let last: string | null = null;
    let since = Date.now();
    for (const deadline = Date.now() + 10_000; Date.now() < deadline; await Bun.sleep(50)) {
      const text = await page.locator(CHIP).first().textContent();
      if (text !== last) [last, since] = [text, Date.now()];
      else if (Date.now() - since >= 500) break;
    }
    return last;
  }

  test("a new chat shows the mode its pick starts it in", async () => {
    reset(false);
    const { context, other } = await newChatAfterPick();
    // acpmux answers the start mode: the pick's, Normal.
    expect(await settledChip(other)).toBe("Normal");
    expect(calls.some((call) => call.method === "_acpmux/start_mode" && call.params.harness === "claude")).toBe(true);
    await context.close();
  });

  test("a new chat names no mode when acpmux sets none", async () => {
    // The profile pins its mode: acpmux takes no pick and starts the chat in none of its own.
    reset(true);
    const { context, other } = await newChatAfterPick();
    expect(await settledChip(other)).toBe("Mode");
    await context.close();
  });
  test("a pending chat follows a pick made after it opened", async () => {
    reset(false);
    const context = await browser!.newContext({ viewport: { width: 900, height: 760 } });
    // The new chat opens first, in full access, and acpmux has not started it (session/new held).
    const other = await context.newPage();
    await other.goto(url(OTHER));
    await other.getByText("Docs updated.").waitFor();
    await other.evaluate(() => {
      const actions = (window as { cmuxAcpmuxActions?: Record<string, (params: object) => Promise<unknown>> })
        .cmuxAcpmuxActions;
      void actions?.["chat.new"]?.({ harness: "claude" });
    });
    await other.getByText("Docs updated.").waitFor({ state: "detached" });
    expect(await settledChip(other)).toBe("Full access");
    // A sessionless pending chat still exposes the harness-specific full-access mode as a real
    // menu, rather than a disabled placeholder. The same path works for Claude and Codex mode ids.
    const pendingAccess = other.locator(".acpmux-access-trigger");
    expect(await pendingAccess.isEnabled()).toBe(true);
    await pendingAccess.click();
    await other.locator(".acpmux-access-menu .acpmux-access-item", { hasText: "Full access" }).waitFor();
    expect(
      await other
        .locator(".acpmux-access-menu .acpmux-access-item", { hasText: "Full access" })
        .getAttribute("aria-checked"),
    ).toBe("true");
    await other.keyboard.press("Escape");
    // Then the person picks Normal in another pane: the pending chat names Normal before any send.
    const picked = await context.newPage();
    await picked.goto(url(PICKED));
    await picked.getByText("Retry added.").waitFor();
    await picked.locator(".acpmux-access-trigger").click();
    await picked.locator(".acpmux-access-menu .acpmux-access-item", { hasText: "Normal" }).click();
    await other.waitForFunction((selector) => document.querySelector(selector)?.textContent === "Normal", CHIP, {
      timeout: 10_000,
    });
    expect(calls.some((call) => call.method === "session/prompt")).toBe(false);
    await context.close();
  });

  test("returning to the pane asks acpmux nothing; a pushed change still reaches the chip", async () => {
    reset(false);
    const context = await browser!.newContext({ viewport: { width: 900, height: 760 } });
    const other = await context.newPage();
    await other.goto(url(OTHER));
    await other.getByText("Docs updated.").waitFor();
    await other.evaluate(() => {
      const actions = (window as { cmuxAcpmuxActions?: Record<string, (params: object) => Promise<unknown>> })
        .cmuxAcpmuxActions;
      void actions?.["chat.new"]?.({ harness: "claude" });
    });
    await other.getByText("Docs updated.").waitFor({ state: "detached" });
    expect(await settledChip(other)).toBe("Full access");
    const asks = () => calls.filter((call) => call.method === "_acpmux/start_mode").length;
    const before = asks();
    // The person switches away and back: the pane is shown and focused again, twice.
    for (let round = 0; round < 2; round++) {
      await other.evaluate(() => {
        document.dispatchEvent(new Event("visibilitychange"));
        window.dispatchEvent(new Event("focus"));
      });
    }
    await Bun.sleep(500);
    expect(asks()).toBe(before);
    // Settings changes the default meanwhile: acpmux pushes `_acpmux/start_mode_changed` (it watches
    // the settings file), and the pending chat asks once and names the new mode.
    daemonState.startMode = "default";
    const notice = JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/start_mode_changed", params: {} });
    for (const socket of sockets) socket.send(notice);
    await other.waitForFunction((selector) => document.querySelector(selector)?.textContent === "Normal", CHIP, {
      timeout: 10_000,
    });
    expect(asks()).toBeGreaterThan(before);
    await context.close();
  });
});
