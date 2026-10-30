// l10n-allow-file: test fixture titles and machine names, not shipped UI.
// A tab's chat that the daemon does not list (`sessionMustExist`): the pane says which case it is
// (Leo 2026-10-21: "second pic is weird has "this chat isn't available""), centered where the chat
// would be and in the pane's own type. Deleted: "This chat was deleted" and Remove from Sidebar.
// Its machine is not connected: a neutral "Reconnecting…" (Leo, #26115), when it was last seen, and
// Reconnect. A chat that is only loading (its attach in flight, or its machine still connecting)
// never reads as unavailable,
// and a chat on another machine whose tab names it by another id than acpmux's opens.
//
// Real Chromium from Playwright, against a stand-in acpmux on a WebSocket and the pane's Vite dev
// server; skipped where it is not installed.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-chat-unavailable.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-chat-unavailable: skipping (run `bunx playwright install chromium`)");
    describe.skip("chat unavailable", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const START = Date.UTC(2026, 9, 21, 9, 0, 0);
  const summary = (sessionId: string, extra: Record<string, unknown> = {}) => ({
    sessionId,
    title: `Chat ${sessionId}`,
    cwd: "/home/dev/atlas",
    harness: "claude",
    family: "claude",
    status: "ready",
    indicator: "done",
    turnCount: 1,
    createdAt: START,
    updatedAt: START,
    lastSeq: 3,
    ...extra,
  });
  const events = (sessionId: string) => [
    { sessionId, seq: 1, at: START, dir: "mux", kind: "user_message", msg: { text: `Opened ${sessionId}` } },
    { sessionId, seq: 2, at: START + 1, dir: "mux", kind: "turn_started", msg: {} },
    { sessionId, seq: 3, at: START + 2, dir: "mux", kind: "turn_result", msg: { status: "completed" } },
  ];

  /// What the stand-in daemon answers; each test sets it before it opens its page.
  type Scenario = {
    sessions: ReturnType<typeof summary>[];
    peers: Record<string, unknown>[];
    /// Set on a chat on another machine's wire (RemoteAcpmuxWire `tabSessionId`).
    tabSessionId?: string;
    /// The attach waits for this, as a slow link would.
    attachHeld?: Promise<void>;
    /// Sessions whose attach fails, as one on a machine that dropped again would.
    attachFails?: Set<string>;
    /// Sessions whose next attach fails once, then attaches.
    attachFailsOnce?: Set<string>;
  };
  let scenario: Scenario = { sessions: [], peers: [] };
  const statusAsked: number[] = [];
  /// Resolved, then dropped, on each `_acpmux/status` request the daemon answers.
  let statusWaiters: (() => void)[] = [];
  const nextStatus = () => new Promise<void>((resolve) => statusWaiters.push(resolve));
  /// Resolves on the daemon's next `_acpmux/attach` request.
  let attachAsked: () => void = () => {};
  /// Resolves on the daemon's next `_acpmux/detach` request (an open of a chat, leaving the one before).
  let detachAsked: () => void = () => {};
  type Socket = { send(data: string): unknown };
  let socket: Socket | undefined;

  function answer(method: string, params: Record<string, any>): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/status":
        statusAsked.push(Date.now());
        for (const resolve of statusWaiters.splice(0)) queueMicrotask(resolve);
        return { peers: scenario.peers };
      case "_acpmux/watch":
      case "_acpmux/sessions":
        return {
          sessions: scenario.sessions,
          ...(scenario.tabSessionId ? { tabSessionId: scenario.tabSessionId } : {}),
        };
      case "_acpmux/attach": {
        const session = scenario.sessions.find((item) => item.sessionId === params.sessionId);
        if (!session) throw new Error("no such session");
        if (scenario.attachFails?.has(session.sessionId)) throw new Error("peer_unreachable");
        if (scenario.attachFailsOnce?.delete(session.sessionId)) throw new Error("peer_unreachable");
        return { session, events: events(session.sessionId), hasMore: false, lastSeq: 3 };
      }
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: 3 };
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
        open(ws) {
          socket = ws;
        },
        async message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          if (message.id === undefined) return;
          if (message.method === "_acpmux/detach") detachAsked();
          if (message.method === "_acpmux/attach") {
            attachAsked();
            await scenario.attachHeld;
          }
          try {
            const result = answer(message.method, message.params ?? {});
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
          } catch (error) {
            const failure = { code: -32602, message: String(error) };
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, error: failure }));
          }
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

  /// Opens the pane on the tab's chat `chat`, which must exist (`#must`, the app's `sessionMustExist`).
  async function open(chat: string, machine?: string): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    const hash = new URLSearchParams({ endpoint, token: "t", session: chat, must: "" });
    if (machine) hash.set("machine", machine);
    await page.goto(`http://127.0.0.1:${port}/#${hash.toString()}`);
    return page;
  }
  const state = (page: Page) => page.evaluate(() => (window as any).cmuxAcpmuxDebug.chatState() as Record<string, any>);
  const notify = (method: string, params: Record<string, unknown>) =>
    socket!.send(JSON.stringify({ jsonrpc: "2.0", method, params }));
  /// Every line the pane drew that says a chat is gone or cannot be reached, from the page's first frame.
  const UNAVAILABLE = /isn't available|was deleted|isn't connected|no longer on/i;
  async function watchForUnavailable(page: Page) {
    await page.addInitScript((pattern) => {
      const seen: string[] = [];
      (window as any).__unavailableSeen = seen;
      const check = () => {
        const text = document.body?.innerText ?? "";
        const match = new RegExp(pattern, "i").exec(text);
        if (match) seen.push(match[0]);
      };
      new MutationObserver(check).observe(document, { childList: true, subtree: true, characterData: true });
    }, UNAVAILABLE.source);
  }

  test("loading never shows the unavailable text: a slow attach, then a machine still connecting", async () => {
    // A listed chat whose attach is in flight.
    let releaseAttach = () => {};
    scenario = {
      sessions: [summary("chat-slow")],
      peers: [],
      attachHeld: new Promise((resolve) => (releaseAttach = resolve)),
    };
    const asked = new Promise<void>((resolve) => (attachAsked = resolve));
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await watchForUnavailable(page);
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(
      `http://127.0.0.1:${port}/#${new URLSearchParams({ endpoint, token: "t", session: "chat-slow", must: "" })}`,
    );
    // The pane has read the list and is waiting on the chat's attach: what it draws now is loading.
    await asked;
    await page.evaluate(
      () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve(null)))),
    );
    releaseAttach();
    await page.getByText("Opened chat-slow", { exact: true }).waitFor({ timeout: 60_000 });
    expect(await page.evaluate(() => (window as any).__unavailableSeen)).toEqual([]);
    await page.close();

    // A chat on a machine acpmux is still connecting to: the pane says it is connecting, never that
    // the chat is unavailable, and opens it once that machine lists it.
    scenario = {
      sessions: [summary("chat-other")],
      peers: [{ name: "build-box", transport: "ssh", connected: false, state: "connecting", attempts: 0 }],
    };
    const waiting = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await watchForUnavailable(waiting);
    await waiting.goto(
      `http://127.0.0.1:${port}/#${new URLSearchParams({ endpoint, token: "t", session: "chat-on-box", must: "" })}`,
    );
    const connecting = waiting.locator('[data-unavailable="connecting"]');
    await connecting.waitFor({ timeout: 60_000 });
    // A neutral "Reconnecting…" with a spinner, never an error (86ebb89edfcf, #26115).
    expect(await connecting.locator("h2").innerText()).toBe("Reconnecting…");
    expect(await connecting.getAttribute("role")).toBe("status");
    // Loading: nothing to reconnect or remove yet; the missing-chat line's Resume and Close Tab stay.
    expect(await connecting.getByRole("button", { name: /Reconnect|Remove from Sidebar/ }).count()).toBe(0);
    expect(await connecting.getByRole("button", { name: "Close Tab" }).count()).toBe(1);
    // The socket opens and acpmux is still in its handshake (it says `connected` before it has read
    // that machine's chats): still connecting, never "deleted". The pane reads the peers again every
    // 2 s while connecting; after two reads it has drawn the first.
    scenario.peers = [
      { name: "build-box", transport: "ssh", connected: true, state: "degraded", attempts: 0, lastSeen: Date.now() },
    ];
    await nextStatus();
    await nextStatus();
    await waiting.evaluate(
      () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve(null)))),
    );
    expect(await connecting.locator("h2").innerText()).toBe("Reconnecting…");
    // The machine connects and acpmux lists its chats.
    scenario.peers = [{ name: "build-box", transport: "ssh", connected: true, state: "connected" }];
    const listed = summary("chat-on-box", { peer: "build-box" });
    scenario.sessions = [...scenario.sessions, listed];
    notify("_acpmux/session_changed", { kind: "created", session: listed });
    await waiting.getByText("Opened chat-on-box", { exact: true }).waitFor({ timeout: 60_000 });
    expect((await state(waiting)).sessionId).toBe("chat-on-box");
    expect(await waiting.evaluate(() => (window as any).__unavailableSeen)).toEqual([]);
    await waiting.close();
  });

  test("a deleted chat says so, names its machine, and offers Remove from Sidebar", async () => {
    // The tab's chat was here and leaves the list while every machine is connected: it was deleted.
    scenario = { sessions: [summary("chat-kept"), summary("chat-gone")], peers: [] };
    const page = await open("chat-gone", "Studio");
    await page.getByText("Opened chat-gone", { exact: true }).waitFor({ timeout: 60_000 });
    scenario.sessions = [summary("chat-kept")];
    notify("_acpmux/lagged", { watch: true, dropped: 1 });
    const shown = page.locator('[data-unavailable="deleted"]');
    await shown.waitFor({ timeout: 60_000 });
    expect(await shown.locator("h2").innerText()).toBe("This chat was deleted");
    expect(await shown.innerText()).toContain("It's no longer on Studio.");
    expect(await shown.innerText()).not.toMatch(/isn't available/);
    // The way on the earlier missing-chat line offered stays: its saved transcript resumes from All Chats.
    expect(await shown.getByRole("button", { name: "Resume from Transcript…" }).count()).toBe(1);
    const remove = shown.getByRole("button", { name: "Remove from Sidebar" });
    await remove.click();
    await page.waitForFunction(() => ((globalThis as any).cmuxDevPaneActions ?? []).includes("closeTab"));
    // Never another chat in its place.
    expect((await state(page)).sessionId).toBeNull();
    expect((await state(page)).missingSession).toBe("chat-gone");
    await page.close();
  });

  test("a chat whose machine goes offline says it is reconnecting, when it was last seen, and Reconnect opens it", async () => {
    scenario = {
      sessions: [summary("chat-kept"), summary("chat-on-box", { peer: "build-box" })],
      peers: [{ name: "build-box", transport: "ssh", connected: true, state: "connected", lastSeen: Date.now() }],
    };
    const page = await open("chat-on-box");
    await page.getByText("Opened chat-on-box", { exact: true }).waitFor({ timeout: 60_000 });
    // The machine drops and acpmux no longer lists the chat (a restarted daemon with no saved list
    // of that machine's chats): the pane reads the list again after a lag.
    const lastSeen = Date.now() - 5 * 60_000;
    scenario.peers = [
      { name: "build-box", transport: "ssh", connected: false, state: "reconnecting", attempts: 4, lastSeen },
    ];
    scenario.sessions = [summary("chat-kept")];
    notify("_acpmux/lagged", { watch: true, dropped: 1 });
    const shown = page.locator('[data-unavailable="offline"]');
    await shown.waitFor({ timeout: 60_000 });
    // Neutral, as connecting (86ebb89edfcf, #26115): "Reconnecting…", when it was last seen, and Reconnect.
    expect(await shown.locator("h2").innerText()).toBe("Reconnecting…");
    expect(await shown.getAttribute("role")).toBe("status");
    await page.waitForFunction(() => document.body.innerText.includes("Last seen 5 minutes ago."));
    expect(await page.getByText(/isn't available|was deleted/).count()).toBe(0);
    const reconnect = shown.getByRole("button", { name: "Reconnect" });
    // Reconnect reads the machines and the list again; once the machine lists the chat it opens.
    scenario.peers = [
      { name: "build-box", transport: "ssh", connected: true, state: "connected", lastSeen: Date.now() },
    ];
    scenario.sessions = [...scenario.sessions, summary("chat-on-box", { peer: "build-box" })];
    const asked = statusAsked.length;
    await reconnect.click();
    await page.getByText("Opened chat-on-box", { exact: true }).waitFor({ timeout: 60_000 });
    expect(statusAsked.length).toBeGreaterThan(asked);
    expect((await state(page)).missingSession).toBeNull();
    await page.close();
  });

  test("the unavailable state is centered in the chat column and drawn in the pane's own type", async () => {
    scenario = { sessions: [], peers: [] };
    const page = await open("chat-gone");
    const shown = page.locator('[data-unavailable="notFound"]');
    await shown.waitFor({ timeout: 60_000 });
    const look = await page.evaluate(() => {
      const box = document.querySelector('[data-unavailable="notFound"]') as HTMLElement;
      const title = box.querySelector("h2") as HTMLElement;
      const button = box.querySelector("button") as HTMLElement;
      const column = box.parentElement!.getBoundingClientRect();
      const rect = title.getBoundingClientRect();
      const titleStyle = getComputedStyle(title);
      const buttonStyle = getComputedStyle(button);
      return {
        columnCenter: column.left + column.width / 2,
        titleCenter: rect.left + rect.width / 2,
        titleTop: rect.top,
        viewport: window.innerHeight,
        font: titleStyle.fontFamily,
        weight: titleStyle.fontWeight,
        size: titleStyle.fontSize,
        color: titleStyle.color,
        align: getComputedStyle(box).textAlign,
        buttonBorder: buttonStyle.borderTopStyle,
        buttonBackground: buttonStyle.backgroundColor,
      };
    });
    // Centered across the column, and well below the top (not the UA's top-left paragraph).
    expect(Math.abs(look.titleCenter - look.columnCenter)).toBeLessThan(4);
    expect(look.titleTop).toBeGreaterThan(look.viewport * 0.2);
    expect(look.align).toBe("center");
    // The pane's type, not the UA default (Times, bold 1.5em h2, black).
    expect(look.font).toContain("system-ui");
    expect(look.weight).toBe("400");
    expect(look.size).toBe("20px");
    expect(look.color).not.toBe("rgb(0, 0, 0)");
    expect(look.color).not.toBe("rgba(0, 0, 0, 0)");
    // The pane's quiet button, not the UA's outset one.
    expect(look.buttonBorder).toBe("none");
    expect(look.buttonBackground).not.toBe("rgb(239, 239, 239)");
    await page.close();
  });

  /// Sets the page's visibility as WebKit reports it for a hidden or shown web view.
  const setVisibility = (page: Page, next: "hidden" | "visible") =>
    page.evaluate((value) => {
      Object.defineProperty(document, "visibilityState", { configurable: true, get: () => value });
      Object.defineProperty(document, "hidden", { configurable: true, get: () => value === "hidden" });
      document.dispatchEvent(new Event("visibilitychange"));
    }, next);

  test("it keeps the missing-chat line's session id, and Close Tab on a chat whose machine is down", async () => {
    // What MissingChat.tsx (86dec887282) showed stays: which session it was, and Close Tab.
    const chat = "01a1201b-d3c3-7be1-8c40-1f1cbc87b8dc";
    scenario = {
      sessions: [summary("chat-kept")],
      peers: [{ name: "build-box", transport: "ssh", connected: false, state: "offline", attempts: 6 }],
    };
    const page = await open(chat);
    const offline = page.locator('[data-unavailable="offline"]');
    await offline.waitFor({ timeout: 60_000 });
    expect(await offline.innerText()).toContain("Session 01a1201b-d3c3");
    expect(await offline.innerText()).not.toContain(chat);
    const close = offline.getByRole("button", { name: "Close Tab" });
    expect(await close.count()).toBe(1);
    expect(await offline.getByRole("button", { name: "Reconnect" }).count()).toBe(1);
    expect(await offline.getByRole("button", { name: "Resume from Transcript…" }).count()).toBe(1);
    await close.click();
    await page.waitForFunction(() => ((globalThis as any).cmuxDevPaneActions ?? []).includes("closeTab"));
    await page.close();

    // A chat never listed here with every machine connected (a tab whose chat is in another acpmux,
    // such as a Chief home's own): it is not found, never called deleted, and keeps both.
    scenario = { sessions: [summary("chat-kept")], peers: [] };
    const gone = await open(chat, "Studio");
    const notFound = gone.locator('[data-unavailable="notFound"]');
    await notFound.waitFor({ timeout: 60_000 });
    expect(await notFound.locator("h2").innerText()).toBe("Can't find this chat");
    expect(await notFound.innerText()).toContain("Studio doesn't have it.");
    expect(await notFound.innerText()).toContain("Session 01a1201b-d3c3");
    expect(await gone.getByText(/was deleted|Remove from Sidebar/).count()).toBe(0);
    expect(await notFound.getByRole("button", { name: "Close Tab" }).count()).toBe(1);
    await gone.close();
  });

  test("a missing chat whose open fails says why again, and Reconnect opens it", async () => {
    scenario = {
      sessions: [summary("chat-kept")],
      peers: [{ name: "build-box", transport: "ssh", connected: false, state: "connecting", attempts: 0 }],
    };
    const page = await open("chat-on-box");
    await page.locator('[data-unavailable="connecting"]').waitFor({ timeout: 60_000 });
    // Its machine lists the chat, then drops again before the pane's attach is answered.
    scenario.attachFails = new Set(["chat-on-box"]);
    scenario.peers = [
      {
        name: "build-box",
        transport: "ssh",
        connected: false,
        state: "reconnecting",
        attempts: 3,
        lastSeen: Date.now(),
      },
    ];
    const listed = summary("chat-on-box", { peer: "build-box" });
    scenario.sessions = [...scenario.sessions, listed];
    notify("_acpmux/session_changed", { kind: "created", session: listed });
    const offline = page.locator('[data-unavailable="offline"]');
    await offline.waitFor({ timeout: 60_000 });
    expect((await state(page)).sessionId).toBeNull();
    expect((await state(page)).missingSession).toBe("chat-on-box");
    // The machine is back: Reconnect opens the chat.
    scenario.attachFails = undefined;
    scenario.peers = [{ name: "build-box", transport: "ssh", connected: true, state: "connected" }];
    await offline.getByRole("button", { name: "Reconnect" }).click();
    await page.getByText("Opened chat-on-box", { exact: true }).waitFor({ timeout: 60_000 });
    expect((await state(page)).sessionId).toBe("chat-on-box");
    await page.close();
  });

  test("a failed reopen never undoes a newer open of the same chat", async () => {
    scenario = {
      sessions: [summary("chat-kept")],
      peers: [{ name: "build-box", transport: "ssh", connected: false, state: "connecting", attempts: 0 }],
    };
    const page = await open("chat-on-box");
    await page.locator('[data-unavailable="connecting"]').waitFor({ timeout: 60_000 });
    // The chat is listed; the pane's own reopen waits on a slow attach that will fail.
    let releaseAttach = () => {};
    scenario.attachHeld = new Promise((resolve) => (releaseAttach = resolve));
    scenario.attachFailsOnce = new Set(["chat-on-box"]);
    scenario.peers = [{ name: "build-box", transport: "ssh", connected: true, state: "connected" }];
    const listed = summary("chat-on-box", { peer: "build-box" });
    scenario.sessions = [...scenario.sessions, listed];
    const firstAttach = new Promise<void>((resolve) => (attachAsked = resolve));
    notify("_acpmux/session_changed", { kind: "created", session: listed });
    await firstAttach;
    // The person opens the same chat again (the list, a link) while that attach is in flight. The
    // pane draws the list once its switch hold ends (the attach is still in flight); the newer open
    // leaves the chat before it first (its detach), so it has taken its selection by then.
    await page.waitForFunction(() =>
      (window as any).cmuxAcpmuxDebug
        .chatState()
        .sessions.some((session: { sessionId: string }) => session.sessionId === "chat-on-box"),
    );
    const reopened = new Promise<void>((resolve) => (detachAsked = resolve));
    expect(await page.evaluate(() => (window as any).cmuxAcpmuxDebug.selectSession("chat-on-box"))).toEqual({
      selected: "chat-on-box",
    });
    await reopened;
    // The first attach fails, the second opens the chat: the stale failure must not undo it.
    releaseAttach();
    // The failure is answered first, on the same socket: by the time the chat draws, the stale
    // handler has run. One painted frame more, for anything it drew.
    await page.getByText("Opened chat-on-box", { exact: true }).waitFor({ timeout: 60_000 });
    await page.evaluate(
      () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve(null)))),
    );
    const now = await state(page);
    expect(now.sessionId).toBe("chat-on-box");
    expect(now.missingSession).toBeNull();
    expect(await page.locator("[data-unavailable]").count()).toBe(0);
    scenario.attachHeld = undefined;
    await page.close();
  });

  test("a missing chat that comes back while the pane is hidden stays unread until it shows", async () => {
    scenario = {
      sessions: [summary("chat-kept")],
      peers: [{ name: "build-box", transport: "ssh", connected: false, state: "connecting", attempts: 0 }],
    };
    const page = await open("chat-on-box");
    await page.locator('[data-unavailable="connecting"]').waitFor({ timeout: 60_000 });
    // The tab's workspace goes to the background, then its machine connects with a turn the person
    // has not read: the pane opens the chat, but nobody has seen it.
    await setVisibility(page, "hidden");
    scenario.peers = [{ name: "build-box", transport: "ssh", connected: true, state: "connected" }];
    const listed = summary("chat-on-box", { peer: "build-box", unread: true });
    scenario.sessions = [...scenario.sessions, listed];
    notify("_acpmux/session_changed", { kind: "created", session: listed });
    await page.waitForFunction(() => (window as any).cmuxAcpmuxDebug.chatState().sessionId === "chat-on-box");
    const unread = async () =>
      ((await state(page)).sessions as { sessionId: string; unread: boolean }[]).find(
        (session) => session.sessionId === "chat-on-box",
      )?.unread;
    expect(await unread()).toBe(true);
    // Showing the page is seeing it.
    await setVisibility(page, "visible");
    await page.waitForFunction(
      () =>
        (window as any).cmuxAcpmuxDebug
          .chatState()
          .sessions.find((session: { sessionId: string }) => session.sessionId === "chat-on-box")?.unread === false,
    );
    await page.close();
  });

  test("a chat on another machine whose tab names it by another id than acpmux's opens", async () => {
    // The machine's daemon attached the session its store records for the tab (RemoteAcpmuxWire
    // `tabSessionId`); the tab named it "lane/review", acpmux's id is "acp-review-1".
    scenario = {
      sessions: [summary("acp-review-1", { name: "lane/review" })],
      peers: [],
      tabSessionId: "acp-review-1",
    };
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await watchForUnavailable(page);
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(
      `http://127.0.0.1:${port}/#${new URLSearchParams({ endpoint, token: "t", session: "lane/review", must: "", machine: "lawrence's MacBook Pro" })}`,
    );
    await page.getByText("Opened acp-review-1", { exact: true }).waitFor({ timeout: 60_000 });
    const opened = await state(page);
    expect(opened.sessionId).toBe("acp-review-1");
    expect(opened.missingSession).toBeNull();
    expect(await page.evaluate(() => (window as any).__unavailableSeen)).toEqual([]);
    await page.close();
  });
});
