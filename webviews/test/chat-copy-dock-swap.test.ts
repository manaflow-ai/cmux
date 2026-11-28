// cmux-web-test-timeout: 420
// l10n-allow-file: test fixture prompts, queued prompts and harness names, not shipped UI.
// Rows in view and the composer stay put when a chat's saved copy gives way to the live page after
// a restart, whatever the copy drew in the dock (the bottom stack: notices, queue, composer).
//
// The saved copy (chatSnapshot/capture.ts) clones all of <main id="root">, the dock `.acpmux-dock`
// and any notice in it included; at the swap (chatSnapshot/live.ts `removeChatSnapshot`) the whole
// copy goes. A dock the live page's first frame draws otherwise (a notice or queue that comes only
// with the daemon's state) could move rows at the swap and again when that state arrives. Lead from
// launch-settle-no-shift ("nothing moves after the first frame"). Cases:
// - autoResume: the daemon waits to retry the chat's turn (AutoResumeNotice.tsx, the session's
//   `retry`, durable across an acpmux restart: acpmux/tests/durable_agents/retry_restore.rs). The
//   copy draws "Retrying…"; the relaunch serves the kept tail, then acpmux reports the same retry.
// - plain: no notice, no queue.
// - queued: one queued prompt (ComposerQueue.tsx), in the kept tail and in acpmux. The live page
//   draws no queue until acpmux's list comes (direct.ts `drawTailWhileConnecting`): before the
//   transcript held the copy's stack (VirtualTranscript `copyHold`), every row moved 34 px down at
//   the swap and 34 px back up about 1 s later.
// - queue sent meanwhile: the copy draws the queue, acpmux has none at the relaunch. Nothing moves
//   at the swap; the rows settle once, as acpmux's list comes.
//
// Production pane, served as the app serves it, in Chromium, as bench/first-load-after-restart.bench.ts
// runs it in its `down` mode (test/chat-copy-composer-draft-swap.test.ts's harness): the warm load
// settles and writes the copy; the relaunch, in a cold context, is served that copy and the kept
// tail with acpmux refusing the socket for DOWN_MS. Every painted frame is read
// (test/support/paintedFrames.ts) from the layer on top. Per case, RUNS relaunches; each reports
// the rows in view and the composer moved at the swap and after it, the settle (swap -> the last
// frame with a >1 px move), and the number of separate moves; any move > 1 px fails.
// Locally (Linux): CMUX_BROWSER_TESTS=1 bun test test/chat-copy-dock-swap.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium, type Browser, type BrowserContext, type Page } from "playwright";
import { TRANSCRIPT_ROW } from "../src/agent-session/acpmux/transcriptSelectors";
import { newestPage } from "../bench/daemonPage";
import { snapshotCss } from "../scripts/agent-pane/snapshotCss.mjs";
import {
  PAGE_STYLE_ID,
  SNAPSHOT_BOOT_GLOBAL,
  SNAPSHOT_GLOBAL,
  SNAPSHOT_HOST_TAG,
  SNAPSHOT_THEME_GLOBAL,
  type ChatSnapshot,
} from "../src/agent-session/acpmux/chatSnapshot/shared";
import { installPaintedFrames } from "./support/paintedFrames";
import { PAPERCUT_CHAT, papercutEvents } from "./support/papercutChat";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("chat-copy-dock-swap.test.ts", async () => {
  setDefaultTimeout(600_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("chat-copy-dock-swap: skipping (run `bunx playwright install chromium`)");
    describe.skip("chat copy dock swap", () => test("chromium", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const chatSnapshotSource = path.join(webviews, "src/agent-session/acpmux/chatSnapshot");
  const TURNS = 40;
  const LATEST = `Answer ${TURNS}:`;
  /// acpmux refuses the socket this long from navigation, as while it restarts after an update.
  const DOWN_MS = 3000;
  const RECORD_MS = DOWN_MS + 4000;
  const RUNS = Number(process.env.CHAT_COPY_DOCK_RUNS ?? 5);
  const THEME = "test-theme";
  const VIEWPORT = { width: 1200, height: 800 };
  const SETTLE_QUIET_MS = 600;

  /// A chat state the copy may draw in the dock. `warmDock` is a dock marker (see `recordFrames`)
  /// the warm load waits for before it writes the copy. `relaunch` is the state at the relaunch when it
  /// changed meanwhile; there the rows may settle in one move, once acpmux's state comes, never at
  /// the swap.
  type State = { session: Record<string, unknown>; queue: unknown[] };
  type Scenario = State & { name: string; warmDock?: string; relaunch?: State & { dock: string } };
  const QUEUED = [{ promptId: "q1", prompt: "Then check the release notes." }];
  const SCENARIOS: Scenario[] = [
    {
      name: "autoResume",
      // acpmux's RetrySummary on the session row: attempt 2 of 4, due well after the run.
      session: { retry: { attempt: 2, of: 4, reason: "capacity", nextAt: Date.now() + 3_600_000 } },
      queue: [],
      warmDock: "retry",
    },
    { name: "plain", session: {}, queue: [] },
    { name: "queued", session: { queue: QUEUED }, queue: QUEUED, warmDock: "queue" },
    // The queued prompt was sent while the app was closed: the copy draws it, acpmux no longer has it.
    {
      name: "queue sent meanwhile",
      session: { queue: QUEUED },
      queue: QUEUED,
      warmDock: "queue",
      relaunch: { session: {}, queue: [], dock: "" },
    },
  ];
  let scenario = SCENARIOS[0]!;
  let chat = papercutEvents({ turns: TURNS, running: false, session: scenario.session });
  let queue: unknown[] = [];
  const use = (next: State) => {
    queue = next.queue;
    chat = papercutEvents({ turns: TURNS, running: false, session: next.session });
  };
  const newest = (limit: number, beforeSeq = Infinity, maxBytes?: unknown) =>
    newestPage(chat.events, { limit, beforeSeq, maxBytes });
  const keptTail = () => ({
    events: newest(400).page,
    summary: chat.session,
    historyExhausted: chat.events.length <= 400,
    queue,
    configSeq: 0,
    usageFromSeq: 0,
  });
  const answer = (method: string, params: Record<string, unknown> = {}): unknown => {
    const { events, session } = chat;
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach": {
        const { page, hasMore } = newest(Number(params.limit ?? 400), Infinity, params.maxBytes);
        return { session, lastSeq: events.at(-1)?.seq ?? 0, events: page, hasMore };
      }
      case "_acpmux/events": {
        if (params.promptIndex === true) {
          const prompts = events
            .filter((event) => event.kind === "user_message")
            .map((event) => ({ ...event, msg: { text: String((event.msg as { text?: string }).text ?? "") } }));
          return { events: prompts, hasMore: false, lastSeq: events.at(-1)?.seq ?? 0 };
        }
        if (params.beforeSeq !== undefined) {
          const { page, hasMore } = newest(Number(params.limit ?? 400), Number(params.beforeSeq), params.maxBytes);
          return { events: page, hasMore, lastSeq: events.at(-1)?.seq ?? 0 };
        }
        return { events: [], hasMore: false, lastSeq: events.at(-1)?.seq ?? 0 };
      }
      case "_acpmux/draft_get":
        return { draft: "" };
      case "_acpmux/draft_set":
        return {};
      default:
        return null;
    }
  };

  type Box = { top: number; height: number };
  type Frame = {
    t: number;
    copyShown: boolean;
    rootHidden: boolean;
    rows: { id: string; top: number }[];
    composer: Box | null;
    dockBox: Box | null;
    /// What the dock draws: "retry" (the auto-resume line), "queue" (a queued prompt), joined by ",".
    dock: string;
  };
  type TestWindow = {
    __frames: { frames: Frame[]; latestAt: number; changedAt: number; done: boolean; stop: () => void };
    __cmuxChatSnapshotMiss?: string;
    captureSnapshot: (doc: Document, theme: string) => ChatSnapshot | undefined;
    captureMiss: () => string;
  };

  /// The host actions the page asks (the kept tail, no reading place), and the app's bridge transport
  /// (the page asks the host for a socket; this process opens it). Runs in the page.
  function installHost({ tail }: { tail: unknown }) {
    type Own = { ok: true; value: unknown } | { ok: false; code: string; message: string };
    let webkit: unknown;
    Object.defineProperty(window, "webkit", {
      configurable: true,
      get: () => webkit,
      set: (next) => {
        for (const name of ["agentSession", "cmuxPage"]) {
          const handler = next?.messageHandlers?.[name];
          if (!handler) continue;
          const post = handler.postMessage.bind(handler);
          const envelope = name === "cmuxPage";
          handler.postMessage = async (request: {
            t?: string;
            id?: unknown;
            method?: string;
            op?: string;
            params?: Record<string, unknown>;
          }) => {
            if (envelope && request.t !== "call") return post(request);
            const method = (request.method ?? request.op ?? "").replace(/^cmux\.agent\./, "");
            if (["transport.open", "transport.send", "transport.close"].includes(method)) {
              const call = (window as unknown as { __testTransport: (m: string, p: unknown) => Promise<Own> })
                .__testTransport;
              const reply = await call(method, request.params ?? {});
              if (envelope)
                return reply.ok
                  ? { t: "ok", id: request.id, value: reply.value }
                  : {
                      t: "err",
                      id: request.id,
                      code: reply.code,
                      message: reply.message,
                      details: { origin: "native" },
                    };
              return reply.ok
                ? reply
                : { ok: false, error: { code: reply.code, message: reply.message, origin: "native" } };
            }
            if (!["ready", "handshake"].includes(method)) return post(request);
            const reply = (await post(request)) as { ok?: boolean; t?: string; value?: Record<string, unknown> };
            if ((reply?.ok || reply?.t === "ok") && reply.value) {
              const { endpoint: _endpoint, token: _token, ...value } = reply.value;
              return { ...reply, value: { ...value, transport: "acpmux-bridge" } };
            }
            return reply;
          };
        }
        webkit = next;
      },
    });
    const served: Record<string, (params: Record<string, unknown>) => Promise<unknown>> = {
      "chat.tail.get": async () => (tail === null ? null : structuredClone(tail)),
      "chat.scrollAnchor.get": async () => null,
    };
    let current: Record<string, unknown> = { ...served };
    Object.defineProperty(window, "cmuxAcpmuxActions", {
      configurable: true,
      get: () => current,
      set: (next: unknown) => {
        current = next && typeof next === "object" ? (next as Record<string, unknown>) : {};
        for (const [method, run] of Object.entries(served)) if (!(method in current)) current[method] = run;
      },
    });
  }

  /// Every painted frame until `windowMs` from navigation: the copy's shadow root while it shows,
  /// else the live page. Runs in the page.
  function recordFrames({
    windowMs,
    settledDock,
    quietMs,
    latest,
    hostTag,
    rowSelector,
  }: {
    windowMs: number;
    settledDock?: string;
    quietMs: number;
    latest: string;
    hostTag: string;
    rowSelector: string;
  }) {
    let stopped = false;
    const recording = {
      frames: [] as unknown[],
      latestAt: 0,
      changedAt: 0,
      done: false,
      stop: () => {
        stopped = true;
        recording.done = true;
      },
    };
    (window as unknown as { __frames: typeof recording }).__frames = recording;
    let signature = "";
    const shownIn = (scope: ParentNode, selector: string) =>
      Array.from(scope.querySelectorAll<HTMLElement>(selector)).some(
        (element) => element.getBoundingClientRect().height > 0,
      );
    window.cmuxAfterPaint(() => {
      if (stopped) return false;
      const drawn = document.querySelector<HTMLElement>(hostTag);
      const host = drawn && drawn.style.visibility !== "hidden" ? drawn : null;
      const scope: ParentNode = host?.shadowRoot ?? document;
      const rootHidden = !host && document.getElementById("root")?.style.opacity === "0";
      const view = rootHidden ? undefined : scope.querySelector<HTMLElement>(".acpmux-scroll")?.getBoundingClientRect();
      const rows: { id: string; top: number; text: string }[] = [];
      if (view)
        for (const row of Array.from(scope.querySelectorAll<HTMLElement>(rowSelector))) {
          const box = row.getBoundingClientRect();
          if (box.height <= 0 || box.bottom <= view.top || box.top >= view.bottom) continue;
          if (Number(getComputedStyle(row).opacity) === 0) continue;
          rows.push({ id: row.dataset.rowId ?? "", top: box.top, text: row.textContent ?? "" });
        }
      rows.sort((a, b) => a.top - b.top);
      const composerElement = rootHidden
        ? undefined
        : Array.from(scope.querySelectorAll<HTMLElement>(".acpmux-composer-box")).find(
            (element) => element.getBoundingClientRect().height > 0,
          );
      const box = composerElement?.getBoundingClientRect();
      const dockRect = rootHidden
        ? undefined
        : scope.querySelector<HTMLElement>(".acpmux-dock")?.getBoundingClientRect();
      const dock = rootHidden
        ? ""
        : [shownIn(scope, '[data-auto-resume="waiting"]') && "retry", shownIn(scope, ".acpmux-queued-text") && "queue"]
            .filter(Boolean)
            .join(",");
      if (!recording.latestAt && rows.some((row) => row.text.includes(latest))) recording.latestAt = performance.now();
      const frame = {
        t: performance.now(),
        copyShown: !!host,
        rootHidden,
        rows: rows.map(({ id, top }) => ({ id, top })),
        composer: box ? { top: box.top, height: box.height } : null,
        dockBox: dockRect ? { top: dockRect.top, height: dockRect.height } : null,
        dock,
      };
      recording.frames.push(frame);
      const next = JSON.stringify([
        frame.rows.map((row) => [row.id, Math.round(row.top)]),
        box && [Math.round(box.top), Math.round(box.height)],
        dock,
      ]);
      if (next !== signature) {
        signature = next;
        recording.changedAt = frame.t;
      }
      // The retry notice can arrive after the minimum recording window. Keep measuring
      // through its arrival and the quiet frames that follow it.
      if (
        frame.t >= windowMs &&
        (settledDock === undefined ||
          (!frame.copyShown &&
            !frame.rootHidden &&
            !!box &&
            dock === settledDock &&
            frame.t - recording.changedAt >= quietMs))
      ) {
        recording.stop();
        return false;
      }
      return true;
    });
  }

  let browser: Browser | undefined;
  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let statics: ReturnType<typeof Bun.serve> | undefined;
  const scratch: string[] = [];
  let downUntil = 0;
  let servedCopy: ChatSnapshot | null = null;
  let url = "";
  let captureScript = "";

  beforeAll(async () => {
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        if (Date.now() < downUntil) return new Response("acpmux is restarting", { status: 503 });
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, unknown> };
          if (message.id === undefined) return;
          try {
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params) }));
          } catch {
            // Closed: the page asks again on its next socket.
          }
        },
      },
    });
    const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "composer-draft-swap-"));
    const work = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "composer-draft-swap-work-"));
    scratch.push(out, work);
    const { build } = await import("vite");
    await build({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      build: { outDir: out, emptyOutDir: true },
      logLevel: "error",
    });
    const bundle = async (entry: string): Promise<string> => {
      const built = await Bun.build({ entrypoints: [entry], format: "iife", target: "browser" });
      if (!built.success) throw new Error(built.logs.map(String).join("\n"));
      return await built.outputs[0]!.text();
    };
    const bootScript = await bundle(path.join(chatSnapshotSource, "boot.ts"));
    const captureEntry = path.join(work, "capture-entry.ts");
    fs.writeFileSync(
      captureEntry,
      `import { captureMiss, captureSnapshot } from ${JSON.stringify(path.join(chatSnapshotSource, "capture.ts"))};\n` +
        "Object.assign(globalThis, { captureMiss, captureSnapshot });\n",
    );
    captureScript = await bundle(captureEntry);
    // The page as the app serves it (build-agent-pane-web.sh), as bench/first-load-after-restart.bench.ts builds it.
    let index = fs.readFileSync(path.join(out, "index.html"), "utf8");
    const linked: string[] = [];
    index = index.replace(/<link\b[^>]*\brel="stylesheet"[^>]*>/g, (tag) => {
      const href = /\bhref="([^"]+)"/.exec(tag)?.[1];
      if (href) linked.push(href.replace(/^\.?\//, ""));
      return "";
    });
    const assets = fs.existsSync(path.join(out, "assets")) ? fs.readdirSync(path.join(out, "assets")) : [];
    const sheets = [
      ...linked,
      ...assets
        .filter((name) => name.endsWith(".css"))
        .map((name) => `assets/${name}`)
        .filter((name) => !linked.includes(name))
        .sort(),
    ];
    if (sheets.length === 0) throw new Error("the pane build has no stylesheet");
    const css = sheets
      .map((sheet) =>
        fs
          .readFileSync(path.join(out, sheet), "utf8")
          .replace(
            /url\((["']?)(?![a-z]+:|\/|#)([^"')]+)\1\)/gi,
            (_match, quote: string, file: string) =>
              `url(${quote}/${path.posix.join(path.posix.dirname(sheet), file)}${quote})`,
          ),
      )
      .join("\n");
    fs.writeFileSync(path.join(out, "pane.css"), css);
    fs.writeFileSync(path.join(out, "pane-copy.css"), snapshotCss(css));
    const placeholders = sheets.map((sheet) => `<link rel="stylesheet" media="not all" href="/${sheet}">`).join("\n");
    index = index.replace(
      "</head>",
      () =>
        `<link rel="stylesheet" id="${PAGE_STYLE_ID}" href="/pane.css" data-copy="pane-copy.css">\n${placeholders}\n</head>`,
    );
    const ROOT = /<main id="root"><\/main>/;
    if (!ROOT.test(index)) throw new Error('the pane build has no <main id="root"></main>');
    index = index.replace(
      ROOT,
      () =>
        '<main id="root"></main>\n<script async src="/__snapshot/chat.js"></script>\n<script src="/chat-snapshot.js"></script>',
    );
    const script = (body: string) =>
      new Response(body, { headers: { "Content-Type": "text/javascript", "Cache-Control": "no-store" } });
    statics = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      async fetch(request) {
        const pathname = new URL(request.url).pathname;
        if (pathname === "/" || pathname === "/index.html")
          return new Response(index, { headers: { "Content-Type": "text/html", "Cache-Control": "no-store" } });
        if (pathname === "/__snapshot/chat.js")
          return script(
            `self.${SNAPSHOT_GLOBAL}=${JSON.stringify(servedCopy)};self.${SNAPSHOT_THEME_GLOBAL}=${JSON.stringify(THEME)};self.__cmuxRestoredChat=${JSON.stringify(PAPERCUT_CHAT)};self.dispatchEvent(new Event('cmux-restored-chat'));self.${SNAPSHOT_BOOT_GLOBAL}?.();`,
          );
        if (pathname === "/chat-snapshot.js") return script(bootScript);
        const file = Bun.file(path.join(out, pathname));
        return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
      },
    });
    url = `http://127.0.0.1:${statics.port}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&session=${PAPERCUT_CHAT}`;
    browser = await chromium.launch({ headless: true });
  });

  afterAll(async () => {
    await browser?.close();
    await statics?.stop(true);
    await daemon?.stop(true);
    for (const dir of scratch) fs.rmSync(dir, { recursive: true, force: true });
  });

  /// The app host's side of the bridge (Swift AgentPaneTransport) for `page`.
  const serveBridge = async (page: Page) => {
    const sockets = new Map<number, WebSocket>();
    let next = 0;
    let delivery = Promise.resolve();
    const push = (event: { connection: number; frames?: string[]; closed?: { code: number; reason: string } }) => {
      delivery = delivery
        .then(() =>
          page.evaluate((pushed) => {
            (
              window as unknown as { cmuxAcpmuxTransport?: { receive(event: unknown): void } }
            ).cmuxAcpmuxTransport?.receive(pushed);
          }, event),
        )
        .catch(() => undefined);
    };
    page.on("close", () => {
      for (const socket of sockets.values()) socket.close();
      sockets.clear();
    });
    await page.exposeFunction("__testTransport", async (method: string, params: Record<string, unknown>) => {
      if (method === "transport.open") {
        const connection = (next += 1);
        const socket = new WebSocket(`ws://127.0.0.1:${daemon!.port}/`);
        const opened = await new Promise<boolean>((resolve) => {
          socket.addEventListener("open", () => resolve(true), { once: true });
          socket.addEventListener("error", () => resolve(false), { once: true });
          socket.addEventListener("close", () => resolve(false), { once: true });
        });
        if (!opened) return { ok: false, code: "transport.connect_failed", message: "acpmux refused the socket" };
        sockets.set(connection, socket);
        socket.addEventListener("message", (event) => push({ connection, frames: [String(event.data)] }));
        socket.addEventListener("close", (event) => {
          if (!sockets.delete(connection)) return;
          push({ connection, closed: { code: event.code, reason: event.reason } });
        });
        return { ok: true, value: { connection } };
      }
      const socket = sockets.get(Number(params.connection));
      if (method === "transport.send") {
        if (!socket) return { ok: false, code: "transport.closed", message: "closed" };
        for (const frame of (params.frames as string[] | undefined) ?? []) socket.send(frame);
        return { ok: true, value: null };
      }
      sockets.delete(Number(params.connection));
      socket?.close();
      return { ok: true, value: null };
    });
  };

  const prepare = async (page: Page, tail: unknown, windowMs: number, settledDock?: string) => {
    await installPaintedFrames(page);
    await serveBridge(page);
    await page.addInitScript(installHost, { tail });
    await page.addInitScript(recordFrames, {
      windowMs,
      settledDock,
      quietMs: SETTLE_QUIET_MS,
      latest: LATEST,
      hostTag: SNAPSHOT_HOST_TAG,
      rowSelector: TRANSCRIPT_ROW,
    });
  };

  /// The load before the restart: acpmux up, the chat open with its draft, settled, and its copy
  /// written as the page writes it. Returns the copy and the context's storage (its draft cache).
  const warm = async (): Promise<{
    copy: ChatSnapshot;
    storage: Awaited<ReturnType<BrowserContext["storageState"]>>;
  }> => {
    servedCopy = null;
    downUntil = 0;
    const context = await browser!.newContext({ viewport: VIEWPORT });
    try {
      const page = await context.newPage();
      await prepare(page, null, 120_000);
      await page.goto(url);
      await page.waitForFunction(
        ({ quietMs, want }) => {
          const recording = (window as unknown as TestWindow).__frames;
          const frame = recording.frames.at(-1);
          return (
            recording.latestAt > 0 &&
            !!frame &&
            (!want || frame.dock.includes(want)) &&
            performance.now() - Math.max(recording.latestAt, recording.changedAt) > quietMs
          );
        },
        { quietMs: SETTLE_QUIET_MS, want: scenario.warmDock },
        { timeout: 120_000, polling: 100 },
      );
      await page.addScriptTag({ content: captureScript });
      const written = await page.evaluate((theme) => {
        const w = window as unknown as TestWindow;
        w.__frames.stop();
        const snapshot = w.captureSnapshot(document, theme);
        return { snapshot: snapshot ?? null, miss: snapshot ? "" : w.captureMiss() };
      }, THEME);
      if (!written.snapshot) throw new Error(`the settled page wrote no copy: ${written.miss}`);
      return { copy: written.snapshot, storage: await context.storageState() };
    } finally {
      await context.close();
    }
  };

  /// The load after the restart: the copy and the kept tail served, acpmux refusing the socket for
  /// DOWN_MS from navigation. `storage` carries the warm page's cache over, else the page is cold.
  const relaunch = async (
    copy: ChatSnapshot,
    storage?: Awaited<ReturnType<BrowserContext["storageState"]>>,
  ): Promise<{ frames: Frame[]; miss: string | null }> => {
    servedCopy = copy;
    const context = await browser!.newContext({ viewport: VIEWPORT, ...(storage ? { storageState: storage } : {}) });
    try {
      const page = await context.newPage();
      await prepare(page, keptTail(), RECORD_MS, scenario.relaunch?.dock ?? scenario.warmDock ?? "");
      downUntil = Date.now() + DOWN_MS;
      await page.goto(url, { waitUntil: "commit" });
      await page.waitForFunction(() => (window as unknown as TestWindow).__frames.done, undefined, {
        timeout: RECORD_MS + 60_000,
        polling: 250,
      });
      return await page.evaluate(() => {
        const w = window as unknown as TestWindow;
        return { frames: w.__frames.frames, miss: w.__cmuxChatSnapshotMiss ?? null };
      });
    } finally {
      downUntil = 0;
      servedCopy = null;
      await context.close();
    }
  };

  /// What moved from the swap on: each frame's largest move of a row in view (against the frame
  /// before, by row id) and of the composer's top; moves in consecutive frames count as one.
  const analyse = (frames: Frame[], miss: string | null) => {
    const swapAt = frames.findIndex((frame, at) => at > 0 && frames[at - 1]!.copyShown && !frame.copyShown);
    if (swapAt < 0)
      throw new Error(
        `no swap from the copy to the live page was recorded (copy frames ${frames.filter((f) => f.copyShown).length}, miss ${miss ?? "none"})`,
      );
    const step = (at: number) => {
      const before = frames[at - 1]!;
      const after = frames[at]!;
      let rows = 0;
      for (const row of before.rows) {
        const next = after.rows.find((other) => other.id === row.id);
        if (next) rows = Math.max(rows, Math.abs(next.top - row.top));
      }
      const composer =
        before.composer && after.composer ? Math.abs(after.composer.top - before.composer.top) : Infinity;
      return { rows, composer };
    };
    const swapT = frames[swapAt]!.t;
    const atSwap = step(swapAt);
    let moves = 0;
    let movingBefore = false;
    let settleMs = 0;
    const after = { rows: 0, composer: 0 };
    for (let at = swapAt; at < frames.length; at++) {
      const moved = step(at);
      const moving = moved.rows > 1 || moved.composer > 1;
      if (moving && !movingBefore) moves += 1;
      if (moving) settleMs = frames[at]!.t - swapT;
      if (at > swapAt) {
        after.rows = Math.max(after.rows, moved.rows);
        after.composer = Math.max(after.composer, moved.composer);
      }
      movingBefore = moving;
    }
    const dockOf = (frame: Frame) => `${frame.dock || "-"} ${frame.dockBox?.height.toFixed(1) ?? "none"} px`;
    const live = frames[swapAt]!;
    const arrival = frames.findIndex((frame, at) => at > swapAt && frame.dock !== live.dock);
    return {
      swapMs: Math.round(swapT),
      atSwap,
      after,
      settleMs: Math.round(settleMs),
      moves,
      copyDock: dockOf(frames[swapAt - 1]!),
      liveDock: dockOf(live),
      dockLater: arrival < 0 ? "none" : `${dockOf(frames[arrival]!)} at ${Math.round(frames[arrival]!.t - swapT)} ms`,
      lastDock: frames.at(-1)!.dock,
    };
  };

  const stats = (values: number[]) => {
    const sorted = [...values].sort((a, b) => a - b);
    const half = sorted.length / 2;
    const median = sorted.length % 2 ? sorted[Math.floor(half)]! : (sorted[half - 1]! + sorted[half]!) / 2;
    return `median ${median.toFixed(1)} max ${sorted.at(-1)!.toFixed(1)}`;
  };

  for (const each of SCENARIOS)
    test(`${each.name}: no row in view and not the composer moves at or after the swap`, async () => {
      scenario = each;
      use(each);
      const { copy } = await warm();
      if (each.relaunch) use(each.relaunch);
      const results: ReturnType<typeof analyse>[] = [];
      for (let run = 0; run < RUNS; run++) {
        const { frames, miss } = await relaunch(copy);
        const result = analyse(frames, miss);
        console.log(`${each.name} run ${run + 1}: ${JSON.stringify(result)}`);
        results.push(result);
      }
      console.log(
        [
          `${each.name} (n=${RUNS}):`,
          `rows at swap ${stats(results.map((r) => r.atSwap.rows))}`,
          `composer at swap ${stats(results.map((r) => r.atSwap.composer))}`,
          `rows after swap ${stats(results.map((r) => r.after.rows))}`,
          `composer after swap ${stats(results.map((r) => r.after.composer))}`,
          `settle ms ${stats(results.map((r) => r.settleMs))}`,
          `moves ${stats(results.map((r) => r.moves))}`,
        ].join("\n  "),
      );
      for (const result of results) {
        expect(result.atSwap.rows).toBeLessThanOrEqual(1);
        expect(result.atSwap.composer).toBeLessThanOrEqual(1);
        if (each.relaunch) {
          expect(result.moves).toBeLessThanOrEqual(1);
          expect(result.lastDock).toBe(each.relaunch.dock);
          continue;
        }
        expect(result.after.rows).toBeLessThanOrEqual(1);
        expect(result.after.composer).toBeLessThanOrEqual(1);
        expect(result.moves).toBe(0);
        if (each.warmDock) expect(result.lastDock).toContain(each.warmDock);
      }
    });
});
