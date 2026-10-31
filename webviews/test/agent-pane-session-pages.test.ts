// l10n-allow-file: test fixture titles, not shipped UI.
// A daemon with a long session list opens a chat without first downloading the whole list
// (cx-2lv1k). The pane asks `_acpmux/watch` for the newest page, opens its chat, then reads the
// rest with `_acpmux/sessions` cursors behind it, so the list still ends up whole: the composer's
// projects, the picker and links to old chats need every session. A session purged or changed
// while a page is on its way keeps its newer state, and a link to a chat on a late page opens it.
// The stand-in daemon refuses what the cmux host's pane policy (policy.json) refuses, as the host
// would: #20644 sent params the policy lacked and local chats lost their list (cx-ibngi).
//
// Real Chromium from Playwright; skipped where it is not installed (the hosted webviews job).
import { afterAll, beforeAll, beforeEach, describe, expect, setDefaultTimeout, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-session-pages.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-session-pages: skipping (run `bunx playwright install chromium`)");
    describe.skip("session pages", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  // The cmux host's pane policy: the methods the page may send and each one's params.
  const policy = JSON.parse(
    readFileSync(path.resolve(webviews, "../cmux-tui/crates/cmux-agent-pane-policy/policy.json"), "utf8"),
  ) as { requests: string[]; known_params: Record<string, { params: string[] }> };
  const refused: string[] = [];
  function refusal(method: string, params: Record<string, any>): string | undefined {
    if (method === "initialize") return undefined;
    if (!policy.requests.includes(method)) return method;
    const known = policy.known_params[method]?.params ?? [];
    const unknown = Object.keys(params).filter((key) => key !== "_meta" && !known.includes(key));
    return unknown.length > 0 ? `${method} ${unknown.join(",")}` : undefined;
  }

  const COUNT = 1200;
  const START = Date.UTC(2026, 9, 1, 9, 0, 0);
  const id = (n: number) => `0190a000-0000-7000-8000-${n.toString(16).padStart(12, "0")}`;
  // Newest first, as acpmux sorts them. Each summary carries what a real one does, about 600 bytes.
  const sessions = Array.from({ length: COUNT }, (_, n) => ({
    sessionId: id(n + 1),
    title: `Chat ${n + 1}`,
    cwd: `/home/dev/project-${n % 40}`,
    branch: `feature/session-${n + 1}`,
    harness: "claude",
    family: "claude",
    status: "ready",
    indicator: "done",
    turnCount: 12,
    createdAt: START - (n + 1) * 60_000,
    updatedAt: START - n * 60_000,
    lastSeq: 3,
    lastPrompt: `Look at the build for change ${n + 1} and tell me which checks failed and why. `.repeat(5),
  }));
  const NEWEST = sessions[0]!.sessionId;
  const LATE = sessions[1100]!.sessionId;
  const GONE = sessions[700]!.sessionId;
  const MOVED = sessions[900]!.sessionId;

  /// acpmux's keyset pages, here by position: `limit` sessions after the cursor and the next cursor.
  function list(params: Record<string, any>, all = sessions) {
    if (params.limit === undefined) return { sessions: all };
    const start = typeof params.cursor === "string" ? Number(params.cursor.slice(1)) : 0;
    const page = all.slice(start, start + Number(params.limit));
    const more = start + page.length < all.length;
    return { sessions: page, nextCursor: more ? `o${start + page.length}` : null };
  }
  const events = (sessionId: string) => [
    { sessionId, seq: 1, at: START, dir: "mux", kind: "user_message", msg: { text: `Open ${sessionId}` } },
    { sessionId, seq: 2, at: START + 1, dir: "mux", kind: "turn_started", msg: {} },
    { sessionId, seq: 3, at: START + 2, dir: "mux", kind: "turn_result", msg: { status: "completed" } },
  ];

  type Socket = { send(data: string): unknown };
  let socket: Socket | undefined;
  let attached = false;
  let bytesBeforeAttach = 0;
  let release: () => void = () => {};
  let held = Promise.resolve();
  const holdPages = () => {
    held = new Promise((resolve) => (release = resolve));
  };
  let releaseAttach: () => void = () => {};
  let attachHeld = Promise.resolve();
  const holdAttach = () => {
    attachHeld = new Promise((resolve) => (releaseAttach = resolve));
  };
  /// A daemon that misbehaves: a cursor that never moves, later pages that fail, and whole-list
  /// reads (watch without `limit`) that fail this many more times. `boundedWhole`: a whole-list read
  /// answers this many rows and a cursor, as acpmux does past its largest reply.
  const faults = { repeatCursor: false, failPages: false, failWhole: 0, boundedWhole: 0 };
  /// The socket of the page this test opened: an earlier test's page still closing never meets the faults.
  let faultSocket: unknown;
  beforeEach(() => {
    Object.assign(faults, { repeatCursor: false, failPages: false, failWhole: 0, boundedWhole: 0 });
    faultSocket = undefined;
    attachHeld = Promise.resolve();
  });
  /// What the pane asked, in order; `answered` once the daemon sent the reply (an error too), and `ended` when
  /// that reply was the list's last page (a page with no cursor, or the whole list).
  const requests: { method: string; params: Record<string, any>; answered?: boolean; ended?: boolean }[] = [];
  /// Checks run as each request comes in and each answer goes out.
  const checks = new Set<() => void>();
  const recheck = () => {
    for (const check of checks) check();
  };
  /// Resolves once `done` holds, as the daemon sees requests and answers them.
  function until(what: string, done: () => boolean, timeout = 15_000): Promise<void> {
    if (done()) return Promise.resolve();
    return new Promise((resolve, reject) => {
      const check = () => {
        if (!done()) return;
        checks.delete(check);
        clearTimeout(timer);
        resolve();
      };
      const timer = setTimeout(() => {
        checks.delete(check);
        reject(new Error(`${what} within ${timeout / 1000}s`));
      }, timeout);
      checks.add(check);
    });
  }
  function answer(method: string, params: Record<string, any>): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "remote", extensions: [], operations: [] } } };
      case "_acpmux/watch":
      case "_acpmux/sessions":
        return list(params);
      case "_acpmux/attach": {
        const session = sessions.find((item) => item.sessionId === params.sessionId);
        return { session, events: events(String(params.sessionId)), hasMore: false, lastSeq: 3 };
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
          faultSocket = ws;
        },
        async message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          if (message.id === undefined) return;
          const params = message.params ?? {};
          const request: (typeof requests)[number] = { method: message.method, params };
          requests.push(request);
          recheck();
          const refusedAs = refusal(message.method, params);
          if (refusedAs) {
            refused.push(refusedAs);
            const error = { code: -32601, message: "Refused by the cmux host" };
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, error }));
            request.answered = true;
            recheck();
            return;
          }
          const failed =
            ws === faultSocket &&
            ((message.method === "_acpmux/sessions" && faults.failPages) ||
              (message.method === "_acpmux/watch" && params.limit === undefined && faults.failWhole-- > 0));
          if (failed) {
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, error: { code: -32603, message: "page lost" } }));
            request.answered = true;
            recheck();
            return;
          }
          // The page is read now; a later page waits until the test lets it go, as a slow link would.
          let result = answer(message.method, params);
          if (ws === faultSocket && message.method === "_acpmux/sessions" && faults.repeatCursor)
            result = { ...(result as object), nextCursor: params.cursor };
          if (ws === faultSocket && params.limit === undefined && faults.boundedWhole > 0) {
            const start = typeof params.cursor === "string" ? Number(params.cursor.slice(1)) : 0;
            const end = Math.min(start + faults.boundedWhole, COUNT);
            if (message.method === "_acpmux/watch" || message.method === "_acpmux/sessions")
              result = { sessions: sessions.slice(start, end), ...(end < COUNT ? { nextCursor: `o${end}` } : {}) };
          }
          if (message.method === "_acpmux/sessions") await held;
          if (message.method === "_acpmux/attach") await attachHeld;
          const text = JSON.stringify({ jsonrpc: "2.0", id: message.id, result });
          if (!attached) bytesBeforeAttach += text.length;
          if (message.method === "_acpmux/attach") attached = true;
          ws.send(text);
          request.answered = true;
          request.ended =
            (message.method === "_acpmux/sessions" && !(result as { nextCursor?: string | null }).nextCursor) ||
            (message.method === "_acpmux/watch" &&
              params.limit === undefined &&
              !(result as { nextCursor?: string | null }).nextCursor);
          recheck();
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

  const notify = (method: string, params: Record<string, unknown>) =>
    socket!.send(JSON.stringify({ jsonrpc: "2.0", method, params }));
  const laterPagesAsked = (count: number) =>
    until(
      `the pane asked for ${count} later pages`,
      () => requests.filter((r) => r.method === "_acpmux/sessions").length >= count,
    );
  /// The daemon sent a list's last page.
  const listEnded = () => until("the daemon sent the list's last page", () => requests.some((r) => r.ended));
  let probes = 0;
  /// Resolves once the page has handled every list the daemon answered: a rename sent after them
  /// lands behind them on the socket, so the page shows it only once it has read the rest. Any
  /// request those answers lead to has left the page by then.
  async function caughtUp(page: Page) {
    await until("the daemon answered every list request", () =>
      requests.every((r) => r.answered || r.method === "_acpmux/attach"),
    );
    const title = `Probe ${++probes}`;
    notify("_acpmux/session_changed", { kind: "updated", session: { ...sessions[COUNT - 1], title } });
    await page.waitForFunction(
      (title) =>
        (window as any).cmuxAcpmuxDebug
          .chatState()
          .sessions.some((session: { title: string }) => session.title === title),
      title,
      { timeout: 15_000 },
    );
  }

  async function open(chat: string): Promise<Page> {
    attached = false;
    bytesBeforeAttach = 0;
    requests.length = 0;
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${chat}`);
    return page;
  }
  const state = (page: Page) => page.evaluate(() => (window as any).cmuxAcpmuxDebug.chatState() as Record<string, any>);

  test("a chat opens after the newest page of a long session list, and the rest arrives behind it", async () => {
    holdPages();
    const page = await open(NEWEST);
    const errors: string[] = [];
    page.on("pageerror", (error) => errors.push(error.message));
    await page.getByText(`Open ${NEWEST}`, { exact: true }).waitFor({ timeout: 60_000 });

    // Everything the daemon sent before the chat's own events: the list's first page, not all of it.
    expect(bytesBeforeAttach).toBeLessThanOrEqual(160 * 1024);
    const watch = requests.find((request) => request.method === "_acpmux/watch")!;
    expect(watch.params.limit).toBeLessThanOrEqual(200);

    // While a later page is on its way, a session is purged and another one changes. The page was
    // read before both, so it carries the old state; the pane keeps the newer one.
    await laterPagesAsked(1);
    socket!.send(
      JSON.stringify({
        jsonrpc: "2.0",
        method: "_acpmux/session_changed",
        params: { kind: "purged", session: { sessionId: GONE } },
      }),
    );
    socket!.send(
      JSON.stringify({
        jsonrpc: "2.0",
        method: "_acpmux/session_changed",
        params: { kind: "updated", session: { ...sessions[900], title: "Moved to the top", updatedAt: START + 1 } },
      }),
    );
    release();

    await page.waitForFunction(
      (count) => (window as any).cmuxAcpmuxDebug.chatState().sessions.length >= count,
      COUNT - 1,
      {
        timeout: 60_000,
      },
    );
    await listEnded();
    await caughtUp(page);
    const final = await state(page);
    const ids: string[] = final.sessions.map((session: { sessionId: string }) => session.sessionId);
    expect(errors).toEqual([]);
    expect(ids.length).toBe(COUNT - 1);
    expect(new Set(ids).size).toBe(ids.length);
    expect(ids).not.toContain(GONE);
    expect(final.sessions.find((session: { sessionId: string }) => session.sessionId === MOVED)?.title).toBe(
      "Moved to the top",
    );
    // Every later page went by cursor, one after another.
    const later = requests.filter((request) => request.method === "_acpmux/sessions");
    expect(later.every((request) => typeof request.params.cursor === "string" && request.params.limit <= 200)).toBe(
      true,
    );
    await page.close();
  });

  test("a link to a chat on a late page opens that chat, not a missing one", async () => {
    holdPages();
    release();
    const page = await open(LATE);
    await page.getByText(`Open ${LATE}`, { exact: true }).waitFor({ timeout: 60_000 });
    const opened = await state(page);
    expect(opened.sessionId).toBe(LATE);
    expect(opened.missingSession).toBeNull();
    await page.close();
  });

  test("a lagged watch rereads the list in pages and keeps what changed while they came", async () => {
    holdPages();
    release();
    const page = await open(NEWEST);
    await page.getByText(`Open ${NEWEST}`, { exact: true }).waitFor({ timeout: 60_000 });
    await page.waitForFunction((count) => (window as any).cmuxAcpmuxDebug.chatState().sessions.length >= count, COUNT, {
      timeout: 60_000,
    });

    // The watch dropped notices: the pane rereads. While its later pages are on their way, a session
    // on its first page is purged, another one there is renamed, and a new chat starts.
    holdPages();
    requests.length = 0;
    notify("_acpmux/lagged", { watch: true, dropped: 3 });
    await laterPagesAsked(1);
    const created = { ...sessions[0]!, sessionId: id(COUNT + 1), title: "Started meanwhile", updatedAt: START + 5 };
    notify("_acpmux/session_changed", { kind: "purged", session: { sessionId: sessions[5]!.sessionId } });
    notify("_acpmux/session_changed", { kind: "updated", session: { ...sessions[10], title: "Renamed meanwhile" } });
    notify("_acpmux/session_changed", { kind: "created", session: created });
    release();

    await page.waitForFunction(
      (count) => (window as any).cmuxAcpmuxDebug.chatState().sessions.length === count,
      COUNT,
      { timeout: 60_000 },
    );
    await laterPagesAsked(Math.ceil(COUNT / 200) - 1);
    await listEnded();
    await caughtUp(page);
    const final = await state(page);
    const byId = new Map<string, { title: string }>(
      final.sessions.map((session: { sessionId: string; title: string }) => [session.sessionId, session]),
    );
    expect(byId.size).toBe(COUNT);
    expect(byId.has(sessions[5]!.sessionId)).toBe(false);
    expect(byId.get(sessions[10]!.sessionId)?.title).toBe("Renamed meanwhile");
    expect(byId.get(created.sessionId)?.title).toBe("Started meanwhile");
    await page.close();
  });

  test("two lagged notices in a row never leave a chat on a late page judged missing", async () => {
    holdPages();
    release();
    const page = await open(LATE);
    await page.getByText(`Open ${LATE}`, { exact: true }).waitFor({ timeout: 60_000 });

    holdPages();
    requests.length = 0;
    notify("_acpmux/lagged", { watch: true, dropped: 1 });
    notify("_acpmux/lagged", { watch: true, dropped: 1 });
    await laterPagesAsked(1);
    release();
    await page.waitForFunction((count) => (window as any).cmuxAcpmuxDebug.chatState().sessions.length >= count, COUNT, {
      timeout: 60_000,
    });
    await listEnded();
    await caughtUp(page);
    const after = await state(page);
    expect(after.sessionId).toBe(LATE);
    expect(after.missingSession).toBeNull();
    await page.close();
  });

  const laterPages = () => requests.filter((request) => request.method === "_acpmux/sessions").length;
  const listed = (page: Page, count: number, timeout = 15_000) =>
    page.waitForFunction((count) => (window as any).cmuxAcpmuxDebug.chatState().sessions.length >= count, count, {
      timeout,
    });

  test("a daemon whose cursor never moves ends the pages and still lists every session", async () => {
    faults.repeatCursor = true;
    const page = await open(NEWEST);
    await page.getByText(`Open ${NEWEST}`, { exact: true }).waitFor({ timeout: 60_000 });
    await listed(page, COUNT);
    // The pages stop at the cursor that came back, and the whole list is read instead.
    await listEnded();
    await caughtUp(page);
    expect(laterPages()).toBeLessThanOrEqual(3);
    const ids: string[] = (await state(page)).sessions.map((session: { sessionId: string }) => session.sessionId);
    expect(new Set(ids).size).toBe(COUNT);
    await page.close();
  });

  test("a later page and its whole-list fallback both failing are tried again, so the list ends whole", async () => {
    faults.failPages = true;
    faults.failWhole = 1;
    const page = await open(NEWEST);
    await page.getByText(`Open ${NEWEST}`, { exact: true }).waitFor({ timeout: 60_000 });
    await listed(page, COUNT);
    expect((await state(page)).sessions.length).toBe(COUNT);
    await page.close();
  });

  test("a lagged watch while the chat attaches ends the older list's pages", async () => {
    holdAttach();
    const page = await open(NEWEST);
    await until("the pane attached", () => requests.some((request) => request.method === "_acpmux/attach"), 30_000);
    notify("_acpmux/lagged", { watch: true, dropped: 1 });
    // The reread's own later pages: the list after its first page.
    await laterPagesAsked(COUNT / 200 - 1);
    await listEnded();
    await caughtUp(page);
    releaseAttach();
    await page.getByText(`Open ${NEWEST}`, { exact: true }).waitFor({ timeout: 60_000 });
    await listed(page, COUNT);
    await caughtUp(page);
    expect(laterPages()).toBe(COUNT / 200 - 1);
    await page.close();
  });

  test("after a lagged reread, a chat that changed meanwhile sorts by when it changed", async () => {
    const page = await open(NEWEST);
    await page.getByText(`Open ${NEWEST}`, { exact: true }).waitFor({ timeout: 60_000 });
    await listed(page, COUNT);
    requests.length = 0;
    holdPages();
    notify("_acpmux/lagged", { watch: true, dropped: 1 });
    await laterPagesAsked(1);
    notify("_acpmux/session_changed", {
      kind: "updated",
      session: { ...sessions[900], title: "Answered just now", updatedAt: START + 60_000 },
    });
    release();
    await laterPagesAsked(COUNT / 200 - 1);
    await listEnded();
    await caughtUp(page);
    const ids: string[] = (await state(page)).sessions.map((session: { sessionId: string }) => session.sessionId);
    expect(ids[0]).toBe(MOVED);
    expect(ids.length).toBe(COUNT);
    await page.close();
  });

  test("a whole list too large for one reply is read on from its cursor before a linked chat is judged", async () => {
    faults.boundedWhole = 500;
    const page = await open(LATE);
    await page.getByText(`Open ${LATE}`, { exact: true }).waitFor({ timeout: 60_000 });
    const opened = await state(page);
    expect(opened.sessionId).toBe(LATE);
    expect(opened.missingSession).toBeNull();
    await listed(page, COUNT);
    // The rest of the whole list came by `_acpmux/sessions` from its cursor, with no `limit`.
    const rest = requests.filter((r) => r.method === "_acpmux/sessions" && r.params.limit === undefined);
    expect(rest.map((r) => r.params.cursor)).toEqual(["o500", "o1000"]);
    await page.close();
  });

  test("everything the pane sent while paging passes the host's pane policy", () => {
    expect(refused).toEqual([]);
  });
});
