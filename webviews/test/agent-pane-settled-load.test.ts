// cmux-web-test-timeout: 420
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Time to settled, not time to first load (Leo, 2026-11-11: "it's about the time to settled
// loading, and this keeps thrashing ... it keeps showing and then hiding, and then showing and then
// hiding your responses, or my responses. The tool calls always get shown for some reason").
//
// The real pane's dev entry opens a long chat, shaped as a real coding agent's (loadFixture.ts:
// prompts, replies streamed as many small chunks, reads, edits, long shell logs), from a stand-in
// acpmux that pages it as acpmux does (hub/paging.rs: the newest `limit`/`maxBytes` page on attach,
// older pages on `_acpmux/events beforeSeq`). While it opens, the connection drops and comes back
// (as a ~31 MB `_acpmux/watch` reply and a busy main thread made it, about once a minute), with a
// reply streaming over the drop; then the reader goes up into the history, which pages older
// records in, and the connection drops again there.
//
// After every painted frame (support/paintedFrames.ts) it records each transcript row on screen:
// its id, its element, its kind (text: a prompt or a reply; tool: everything else), and whether it
// is visible (inside the scroller's view, laid out, not hidden or transparent). The open is settled
// when no row's state changed for SETTLE_MS. Reported, text rows and tool rows apart:
//   settled_ms   from navigation to the last change before SETTLE_MS of none;
//   flips        a row that was visible went hidden or gone, then came back (show->hide->show);
//   remounts     a row drawn again by a new element under the same id or the same content;
//   lost         a row's content that was visible went and came back under another id.
// A row shown once never hides or remounts (no reader input in the windows counted), so flips,
// remounts and lost must all be 0. The report is one JSON line on stdout (`settled-load:`) so the
// same harness gives the PR's before/after numbers.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { loadTurn, streamedReply, type LoadStep } from "../src/agent-session/acpmux/loadFixture";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-settled-load.test.ts", async () => {
  setDefaultTimeout(400_000);
  const engines: [string, BrowserType][] = [];
  const only = process.env.SETTLED_LOAD_ENGINES?.split(",");
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    if (only && !only.includes(engine[0])) continue;
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch (error) {
      console.warn(`agent-pane-settled-load: skipping ${engine[0]}: ${String(error).slice(0, 400)}`);
    }
  }
  if (engines.length === 0) {
    describe.skip("a long chat settles with no row shown twice", () => test("no engine", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const SESSION = "0190a000-0000-7000-8000-0000000000e7";
  const TURNS = Number(process.env.SETTLED_LOAD_TURNS ?? 120);
  const SETTLE_MS = 2000;
  const CHUNK = 24; // characters per streamed delta, as a model streams its reply
  const summary = (status = "idle") => ({
    sessionId: SESSION,
    cwd: "/mock/project",
    title: "Long retry work",
    harness: "claude",
    status,
    steering: true,
    queuePaused: false,
    queued: 0,
    queue: [],
    turnCount: TURNS + 1,
    createdAt: 1_791_000_000_000,
    updatedAt: 1_791_000_000_000 + TURNS * 60_000,
  });
  type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
  const events: Event[] = [];
  // As acpmux stamps reply chunks (hub/stream.rs `reply_segment`): one segment id per run of reply
  // text in a turn, ended by anything but a quiet update between two chunks.
  const QUIET = new Set([
    "usage_update",
    "available_commands_update",
    "current_mode_update",
    "config_option_update",
    "session_info_update",
    "prompt_suggestion",
  ]);
  let segTurn = "-";
  let segCount = 0;
  let segOpen = false;
  let segMessage: unknown;
  const record = (dir: string, kind: string, msg: Record<string, unknown>, at = Date.now()): Event => {
    if (dir === "mux" && kind === "turn_started") {
      segTurn = String(msg.turnId ?? "-");
      segCount = 0;
    }
    if (dir === "mux" && (kind === "user_message" || kind === "turn_started")) segOpen = false;
    if (dir === "in" && kind === "agent_message_chunk") {
      const params = msg.params as Record<string, any>;
      const messageId = params.update?.messageId;
      if (!segOpen || messageId !== segMessage) {
        segCount += 1;
        segOpen = true;
      }
      segMessage = messageId;
      msg = { ...msg, params: { ...params, _meta: { acpmux: { segment: `${segTurn}.${segCount}` } } } };
    } else if (dir === "in" && !QUIET.has(kind)) segOpen = false;
    const event = { sessionId: SESSION, seq: events.length + 1, at, dir, kind, msg };
    events.push(event);
    return event;
  };
  const update = (body: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: `agent-${SESSION}`, update: body },
  });
  /// A step of the fixture as acpmux records it; a reply's text goes out in CHUNK-character deltas.
  const recordStep = (step: LoadStep, turn: number, at: number, messageId?: string) => {
    if ("update" in step) {
      const body = step.update as Record<string, any>;
      if (body.sessionUpdate === "agent_message_chunk" && typeof body.content?.text === "string") {
        const text = body.content.text as string;
        for (let i = 0; i < text.length; i += CHUNK)
          record(
            "in",
            "agent_message_chunk",
            update({
              ...body,
              ...(messageId && { messageId }),
              content: { type: "text", text: text.slice(i, i + CHUNK) },
            }),
            at,
          );
        return;
      }
      record("in", String(body.sessionUpdate), update(body), at);
    } else if (step.mux === "user_message") record("mux", "user_message", { ...step.msg, promptId: `p-${turn}` }, at);
    else if (step.mux === "turn_started")
      record("mux", "turn_started", { turnId: `t-${turn}`, promptId: `p-${turn}` }, at);
    else record("mux", step.mux, step.msg ?? {}, at);
  };
  const base = 1_791_000_000_000;
  for (let turn = 0; turn < TURNS; turn++)
    for (const step of loadTurn(turn, { diffLines: 60, logLines: 80 }))
      recordStep(step, turn, base + turn * 60_000, `m-${turn}-${(step as { update?: unknown }).update ? "a" : "x"}`);
  const LIVE_TURN = TURNS;
  record("mux", "user_message", { text: `Turn ${LIVE_TURN}: now fix the last retry loop`, promptId: `p-${LIVE_TURN}` });
  record("mux", "turn_started", { turnId: `t-${LIVE_TURN}`, promptId: `p-${LIVE_TURN}` });
  const liveReply = streamedReply(LIVE_TURN, 6);
  let liveAt = 0;
  // The first part of the live reply is recorded before the open.
  for (; liveAt < liveReply.length / 3; liveAt += CHUNK)
    record(
      "in",
      "agent_message_chunk",
      update({
        sessionUpdate: "agent_message_chunk",
        messageId: "m-live",
        content: { type: "text", text: liveReply.slice(liveAt, liveAt + CHUNK) },
      }),
    );
  const fixtureEnd = events.length;
  const fixtureLiveAt = liveAt;

  /// A page of the chat as acpmux's paging.rs answers (`_acpmux/attach` and `_acpmux/events`).
  const page = (params: Record<string, any>, attach: boolean) => {
    const kinds: string[] = Array.isArray(params.kinds) ? params.kinds : [];
    const transcript = (event: Event) =>
      kinds.length === 0 ||
      kinds.includes(event.kind) ||
      (kinds.includes("transcript") && event.kind !== "available_commands_update");
    const after = Number(params.afterSeq ?? 0);
    const before = params.beforeSeq === undefined ? Infinity : Number(params.beforeSeq);
    const newest = params.beforeSeq !== undefined || (attach && params.afterSeq === undefined);
    const limit = params.limit === undefined ? (attach ? 2000 : Infinity) : Math.max(1, Number(params.limit));
    const maxBytes = params.maxBytes === undefined ? Infinity : Number(params.maxBytes);
    const out: Event[] = [];
    let bytes = 0;
    let hasMore = false;
    const take = (event: Event) => {
      if (event.seq <= after || event.seq >= before || !transcript(event)) return true;
      if (out.length >= limit) return !(hasMore = true);
      bytes += JSON.stringify(event.msg).length + event.kind.length + 120;
      if (out.length > 0 && bytes > maxBytes) return !(hasMore = true);
      out.push(event);
      return true;
    };
    if (newest) {
      for (let i = events.length - 1; i >= 0 && take(events[i]!); i -= 1);
      out.reverse();
    } else for (let i = 0; i < events.length && take(events[i]!); i += 1);
    return { events: out, hasMore };
  };
  const turnOpener = (first: Event | undefined, hasMore: boolean) => {
    const opens = (event: Event) => event.dir === "mux" && event.kind === "user_message" && event.msg?.steer !== true;
    if (!hasMore || !first || first.seq <= 1 || opens(first)) return null;
    for (let i = first.seq - 2; i >= 0; i -= 1) if (opens(events[i]!)) return events[i]!;
    return null;
  };
  let status = "running";
  /// Initialize requests: one per connection the pane made.
  let connections = 0;
  /// Older pages the pane asked for (`_acpmux/events` with `beforeSeq`).
  let pagesAsked = 0;
  let prompted: ((sent: { id: number; promptId: string }) => void) | undefined;
  function answer(method: string, params: Record<string, any>): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [summary(status)] };
      case "_acpmux/attach": {
        const p = page(params, true);
        return {
          session: summary(status),
          ...p,
          lastSeq: events.length,
          pageThrough: events.length,
          turnOpener: turnOpener(p.events[0], p.hasMore),
        };
      }
      case "_acpmux/events": {
        const p = page(params, false);
        return { ...p, lastSeq: events.length };
      }
      default:
        return null;
    }
  }

  type Ws = { send(data: string): void; close(code?: number): void };
  const sockets = new Set<Ws>();
  const attached = new Set<Ws>();
  const emitLive = (event: Event) => {
    for (const ws of attached) ws.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }));
  };
  /// The connection resets, as the oversized watch reply made it: every socket closes at once.
  const drop = () => {
    for (const ws of sockets) ws.close(4000);
    sockets.clear();
    attached.clear();
  };

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  const url = () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`;
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
          attached.delete(ws);
        },
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          if (message.method === "initialize") connections += 1;
          if (message.method === "_acpmux/attach") attached.add(ws);
          if (message.method === "_acpmux/events" && message.params?.beforeSeq !== undefined) pagesAsked += 1;
          if (message.method === "session/prompt") {
            // The prompt the reader typed: acpmux records it and starts its turn; the reply
            // streams from the test (`replyTo`), and the request answers when the turn ends.
            const promptId = String(message.params?._meta?.acpmux?.promptId ?? `p-sent-${events.length}`);
            const text =
              (message.params?.prompt as { text?: string }[] | undefined)?.map((b) => b.text ?? "").join("") ?? "";
            emitLive(record("mux", "user_message", { text, promptId }));
            emitLive(record("mux", "turn_started", { turnId: `t-${promptId}`, promptId }));
            status = "running";
            prompted?.({ id: message.id!, promptId });
            return;
          }
          if (message.id !== undefined)
            ws.send(
              JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params ?? {}) }),
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
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    for (const browser of browsers.values()) {
      for (let attempt = 1; ; attempt++) {
        const warm = await browser.newPage();
        try {
          await warm.goto(url());
          await warm.locator(".acpmux-row").first().waitFor({ timeout: 40_000 });
          await warm.close();
          break;
        } catch (error) {
          await warm.close();
          if (attempt === 3) throw error;
        }
      }
    }
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  /// Installs the per-frame row recorder before any pane script runs.
  const installRecorder = (page: Page) =>
    page.addInitScript(() => {
      type Seen = { el: number; visible: boolean; kind: "text" | "tool" };
      const ids = new WeakMap<Element, number>();
      let next = 1;
      const idOf = (el: Element) => {
        if (!ids.has(el)) ids.set(el, next++);
        return ids.get(el)!;
      };
      const TEXT = /\bacpmux-(user|assistant)\b/;
      const LIVE_LINES = new Set(["thinking-live", "typing"]);
      const state = {
        on: false,
        frames: 0,
        lastChange: 0,
        firstRow: undefined as number | undefined,
        // Per row id, and per row content (its text's first 160 characters), what it was last frame.
        rows: new Map<string, Seen & { shown: boolean; hiddenAfterShown: boolean }>(),
        content: new Map<
          string,
          { el: number; id: string; visible: boolean; kind: Seen["kind"]; shown: boolean; hiddenAfterShown: boolean }
        >(),
        flips: { text: [] as string[], tool: [] as string[] },
        remounts: { text: [] as string[], tool: [] as string[] },
        lost: { text: [] as string[], tool: [] as string[] },
        rowsSeen: { text: new Set<string>(), tool: new Set<string>() },
        marks: [] as [string, number][],
      };
      (window as unknown as { __settled: typeof state }).__settled = state;
      const read = (now: number) => {
        state.frames += 1;
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
        const box = scroller?.getBoundingClientRect();
        const paneHidden =
          !scroller ||
          scroller.closest("[data-seeking]") !== null ||
          getComputedStyle(scroller).visibility === "hidden" ||
          scroller.clientHeight === 0;
        const seenIds = new Set<string>();
        const seenContent = new Set<string>();
        let changed = false;
        for (const el of scroller?.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]") ?? []) {
          const id = el.getAttribute("data-row-id")!;
          // The live turn's working line comes and goes with the turn by design: not a message.
          if (LIVE_LINES.has(id)) continue;
          const kind = TEXT.test(el.className) ? "text" : "tool";
          const r = el.getBoundingClientRect();
          const style = getComputedStyle(el);
          const visible =
            !paneHidden &&
            r.height > 0 &&
            r.bottom > box!.top + 1 &&
            r.top < box!.bottom - 1 &&
            style.visibility !== "hidden" &&
            Number(style.opacity) > 0.05;
          const elId = idOf(el);
          seenIds.add(id);
          if (visible && state.firstRow === undefined) state.firstRow = now;
          const before = state.rows.get(id);
          if (!before) {
            state.rows.set(id, { el: elId, visible, kind, shown: visible, hiddenAfterShown: false });
            if (visible) changed = true;
          } else {
            if (state.on && before.el !== elId && before.shown) {
              state.remounts[kind].push(`${id}@${Math.round(now)}`);
              changed = true;
            }
            if (state.on && visible && before.hiddenAfterShown) {
              state.flips[kind].push(`${id}@${Math.round(now)}`);
              before.hiddenAfterShown = false;
            }
            if (before.visible !== visible) changed = true;
            if (!visible && before.visible && state.on) before.hiddenAfterShown = true;
            before.el = elId;
            before.visible = visible;
            before.shown ||= visible;
          }
          if (visible) state.rowsSeen[kind].add(id);
          // The same content under another id, or a new element: what the reader sees went and came.
          const text = (el.textContent ?? "").replace(/\s+/g, " ").trim().slice(0, 160);
          if (text.length < 24 || !visible) continue;
          const key = `${kind}:${text}`;
          seenContent.add(key);
          const had = state.content.get(key);
          if (!had) state.content.set(key, { el: elId, id, visible, kind, shown: true, hiddenAfterShown: false });
          else {
            if (state.on && had.hiddenAfterShown) {
              if (had.id !== id) state.lost[kind].push(`${had.id}->${id}@${Math.round(now)}`);
              had.hiddenAfterShown = false;
            }
            had.el = elId;
            had.id = id;
            had.visible = true;
          }
        }
        for (const [id, row] of state.rows)
          if (!seenIds.has(id) && (row.visible || row.el !== 0)) {
            if (row.visible) {
              changed = true;
              if (state.on) row.hiddenAfterShown = true;
            }
            row.visible = false;
            row.el = 0;
          }
        for (const [key, entry] of state.content)
          if (!seenContent.has(key) && entry.visible) {
            entry.visible = false;
            if (state.on) entry.hiddenAfterShown = true;
          }
        if (changed) state.lastChange = now;
      };
      // installPaintedFrames' init script ran first, so its frame reader is here already.
      window.cmuxAfterPaint((frame) => {
        read(frame);
        return true;
      });
    });

  type Settled = {
    frames: number;
    firstRow?: number;
    lastChange: number;
    flips: { text: string[]; tool: string[] };
    remounts: { text: string[]; tool: string[] };
    lost: { text: string[]; tool: string[] };
    rowsSeen: { text: number; tool: number };
  };
  const snapshot = (page: Page) =>
    page.evaluate(() => {
      const s = (window as unknown as { __settled: any }).__settled;
      return {
        frames: s.frames,
        firstRow: s.firstRow,
        lastChange: s.lastChange,
        flips: s.flips,
        remounts: s.remounts,
        lost: s.lost,
        rowsSeen: { text: s.rowsSeen.text.size, tool: s.rowsSeen.tool.size },
      } as Settled;
    });
  /// Counting on from now: a row visible now that hides and comes back is a flip.
  const arm = (page: Page, on: boolean) =>
    page.evaluate((value) => {
      const s = (window as unknown as { __settled: any }).__settled;
      s.on = value;
      if (value) for (const row of s.rows.values()) row.hiddenAfterShown = false;
      if (value) for (const entry of s.content.values()) entry.hiddenAfterShown = false;
    }, on);
  /// Resolves once no row changed for SETTLE_MS (page clock), or after `capMs`; the settled time.
  const settle = async (page: Page, capMs = 60_000) => {
    const settled = await page
      .waitForFunction(
        (quiet) => {
          const s = (window as unknown as { __settled: { lastChange: number } }).__settled;
          return s.lastChange > 0 && performance.now() - s.lastChange >= quiet ? s.lastChange : false;
        },
        SETTLE_MS,
        { polling: 100, timeout: capMs },
      )
      .catch(() => undefined);
    return settled ? Number(await settled.jsonValue()) : Number.NaN;
  };
  /// Waits `count` painted frames: the page's own pace, never a fixed time.
  const frames = (page: Page, count: number) =>
    page.evaluate(async (n) => {
      for (let i = 0; i < n; i++) await window.cmuxPaintFrame();
    }, count);

  test.each(engines.map(([name]) => name))(
    "%s: a long chat opened through reconnects and paging settles with no row shown, hidden and shown again",
    async (name) => {
      events.length = fixtureEnd;
      liveAt = fixtureLiveAt;
      status = "running";
      const page = await browsers.get(name)!.newPage({ viewport: { width: 1200, height: 860 } });
      const chunk = (text: string, messageId: string) =>
        record(
          "in",
          "agent_message_chunk",
          update({ sessionUpdate: "agent_message_chunk", messageId, content: { type: "text", text } }),
        );
      /// Streams `text` live as one reply, a delta a painted frame.
      const streamLive = async (text: string, messageId: string) => {
        for (let at = 0; at < text.length; at += CHUNK) {
          emitLive(chunk(text.slice(at, at + CHUNK), messageId));
          await frames(page, 1);
        }
      };
      /// The connection resets (as the oversized watch reply made it); `meanwhile` is recorded while
      /// the pane is away. Resolves once the pane connected again and its attach answered.
      const dropAndReconnect = async (meanwhile: () => void) => {
        const before = connections;
        drop();
        meanwhile();
        const deadline = Date.now() + 60_000;
        while ((connections === before || attached.size === 0) && Date.now() < deadline) await frames(page, 2);
        expect(connections).toBeGreaterThan(before);
        expect(attached.size).toBeGreaterThan(0);
        return page.evaluate(() => performance.now());
      };
      /// The time from a drop to the last change after the pane connected again (none: connected).
      const afterDrop = (settled: number, droppedAt: number, connectedAt: number) =>
        Math.round(Math.max(settled, connectedAt) - droppedAt);
      try {
        await installPaintedFrames(page);
        await installRecorder(page);
        // The turn fold's own reflow is not a load flip: under the shipped "answer" arm (#41213) a turn
        // that ends folds its earlier replies under "Worked for", the transcript gets shorter and the
        // prompt above scrolls back into view by design. This harness measures loading (open,
        // reconnects, paging), so it pins the arm that keeps every reply, as #41213 pinned old arms in
        // other suites; turn-fold-keeps-replies.test.ts covers the fold itself.
        await page.addInitScript(() => {
          (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = {
            "turn-fold-replies": "replies",
          };
        });
        await page.goto(url());
        await page.mouse.move(0, 0);
        await arm(page, true);
        await page.locator(".acpmux-row").first().waitFor({ timeout: 60_000 });
        // The open: the reply that was streaming goes on, and ends.
        await streamLive(liveReply.slice(liveAt, (liveReply.length * 2) / 3), "m-live");
        emitLive(record("mux", "turn_result", { status: "completed" }));
        status = "idle";
        const openSettled = await settle(page);
        const open = await snapshot(page);

        // The reader asks something; the reply streams; the connection resets mid-reply, the reply
        // goes on while the pane is away, and on after it is back.
        const sent = new Promise<{ id: number; promptId: string }>((resolve) => (prompted = resolve));
        await page.locator(".acpmux-composer-prompt").click();
        await page.keyboard.type("Why does the last retry loop still spin past the cap?");
        await page.keyboard.press("Enter");
        const prompt = await sent;
        await page.mouse.move(0, 0);
        const answer = streamedReply(LIVE_TURN + 1, 4);
        const third = Math.floor(answer.length / 3);
        await streamLive(answer.slice(0, third), "m-asked");
        emitLive(
          record(
            "in",
            "tool_call",
            update({
              sessionUpdate: "tool_call",
              toolCallId: "asked-read",
              kind: "read",
              title: "Read src/retry.ts",
              status: "completed",
            }),
          ),
        );
        await streamLive(answer.slice(third, 2 * third), "m-asked-2");
        const firstDropAt = await page.evaluate(() => performance.now());
        const firstConnectedAt = await dropAndReconnect(() => {
          for (let at = 2 * third; at < 2 * third + CHUNK * 10; at += CHUNK)
            chunk(answer.slice(at, at + CHUNK), "m-asked-2");
        });
        await streamLive(answer.slice(2 * third + CHUNK * 10), "m-asked-2");
        record("mux", "turn_result", { status: "completed" });
        status = "idle";
        for (const ws of attached)
          ws.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: events.at(-1) }));
        for (const ws of sockets)
          ws.send(JSON.stringify({ jsonrpc: "2.0", id: prompt.id, result: { stopReason: "end_turn" } }));
        const reconnectSettled = await settle(page);

        // The reader goes up the chat (input: not counted) past what one attach page holds, which
        // pages older records in; reading there, the connection resets again.
        await arm(page, false);
        const olderAsked = () => pagesAsked;
        const pagesBefore = olderAsked();
        for (let step = 0; step < 40 && olderAsked() < pagesBefore + 2; step++) {
          await page.evaluate(() => {
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            scroller.scrollTop = Math.max(0, scroller.scrollTop - scroller.clientHeight * 4);
          });
          await frames(page, 6);
        }
        expect(olderAsked()).toBeGreaterThan(pagesBefore);
        await settle(page, 30_000);
        await arm(page, true);
        const secondDropAt = await page.evaluate(() => performance.now());
        const secondConnectedAt = await dropAndReconnect(() => {});
        const historySettled = await settle(page);
        const all = await snapshot(page);
        const report = {
          engine: name,
          turns: TURNS,
          records: events.length,
          frames: all.frames,
          first_row_ms: Math.round(open.firstRow ?? Number.NaN),
          settled_ms: Math.round(openSettled),
          reconnect_settled_ms: afterDrop(reconnectSettled, firstDropAt, firstConnectedAt),
          history_reconnect_settled_ms: afterDrop(historySettled, secondDropAt, secondConnectedAt),
          rows_seen: all.rowsSeen,
          flips: { text: all.flips.text.length, tool: all.flips.tool.length },
          remounts: { text: all.remounts.text.length, tool: all.remounts.tool.length },
          lost: { text: all.lost.text.length, tool: all.lost.tool.length },
          examples: {
            flips: [...all.flips.text.slice(0, 6), ...all.flips.tool.slice(0, 3)],
            remounts: [...all.remounts.text.slice(0, 6), ...all.remounts.tool.slice(0, 3)],
            lost: [...all.lost.text.slice(0, 6), ...all.lost.tool.slice(0, 3)],
          },
        };
        console.log(`settled-load: ${JSON.stringify(report)}`);
        expect(all.rowsSeen.text).toBeGreaterThan(4);
        expect(all.rowsSeen.tool).toBeGreaterThan(2);
        expect(Number.isFinite(openSettled)).toBe(true);
        expect(Number.isFinite(reconnectSettled)).toBe(true);
        expect(Number.isFinite(historySettled)).toBe(true);
        expect(report.flips).toEqual({ text: 0, tool: 0 });
        expect(report.remounts).toEqual({ text: 0, tool: 0 });
        expect(report.lost).toEqual({ text: 0, tool: 0 });
      } finally {
        prompted = undefined;
        await page.close();
      }
    },
  );
});
