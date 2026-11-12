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
  /// A shell the agent left running in the background (Claude's `run_in_background` Bash), as a
  /// long-lived chat holds a few dozen of (Leo's, 2026-11-11: "glaeda-gh wait +24 more").
  const backgroundShell = (id: string, command: string, at: number) => {
    record(
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: id,
        title: command,
        kind: "execute",
        status: "in_progress",
        rawInput: { command, run_in_background: true },
        _meta: { claude: { tool: "Bash" } },
      }),
      at,
    );
    record(
      "in",
      "tool_call_update",
      update({
        sessionUpdate: "tool_call_update",
        toolCallId: id,
        status: "completed",
        content: [{ type: "content", content: { type: "text", text: `Command running in background with ID: ${id}` } }],
      }),
      at,
    );
    record(
      "in",
      "background_task_update",
      update({
        sessionUpdate: "background_task_update",
        taskId: `task-${id}`,
        toolCallId: id,
        command,
        state: "running",
      }),
      at,
    );
  };
  const BACKGROUND = 25;
  for (let turn = 0; turn < TURNS; turn++) {
    const at = base + turn * 60_000;
    const steps = loadTurn(turn, { diffLines: 60, logLines: 80 });
    steps.forEach((step, index) => {
      // Every few turns, after the turn's read, a shell goes on in the background: the last ones
      // fall in the newest page, the rest in the history before it.
      if (
        index === 4 &&
        turn % Math.floor(TURNS / BACKGROUND) === 0 &&
        turn / Math.floor(TURNS / BACKGROUND) < BACKGROUND
      )
        backgroundShell(`bg-${turn}`, `glaeda-gh wait run ${turn} --timeout 3600`, at);
      recordStep(step, turn, at, `m-${turn}-${(step as { update?: unknown }).update ? "a" : "x"}`);
    });
  }
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
  /// The settled cold open (cmuxterm-hq#9655 stage 1): whether this daemon serves `settled-attach-v1`,
  /// whether it serves forks, and whether it is still reading the chat's log after its restart. While
  /// it reads, an attach answers the newest page from disk with the summary it had before the log was
  /// read: no queue (requests.rs MUX_ATTACH, `waitLogs: false`); the queue comes later as a
  /// session change. A settled view, written at the last turn end, carries the queue with the frame.
  let settledServed = false;
  let forkServed = false;
  let restoring = false;
  const RESTORED_QUEUE = [
    { promptId: "q-1", prompt: "After this, run the retry suite again" },
    { promptId: "q-2", prompt: "Then write up what changed" },
    { promptId: "q-3", prompt: "And open the pull request" },
  ];
  /// The attach requests the pane made, as asked (their `settled` flag and page bounds).
  const attachesAsked: Record<string, any>[] = [];
  /// Initialize requests: one per connection the pane made.
  let connections = 0;
  /// Older pages the pane asked for (`_acpmux/events` with `beforeSeq`).
  let pagesAsked = 0;
  let prompted: ((sent: { id: number; promptId: string }) => void) | undefined;
  function answer(method: string, params: Record<string, any>): unknown {
    switch (method) {
      case "initialize":
        return {
          protocolVersion: 1,
          _meta: {
            acpmux: {
              origin: "local",
              extensions: [],
              operations: forkServed ? ["acp.session.fork"] : [],
              capabilities: settledServed ? ["settled-attach-v1"] : [],
            },
          },
        };
      case "_acpmux/watch":
        return { sessions: [summary(status)] };
      case "_acpmux/attach": {
        attachesAsked.push(params);
        const p = page(params, true);
        const session = restoring ? summary(status) : { ...summary(status), queue: RESTORED_QUEUE, queued: 3 };
        // The view written at the chat's last turn end: its records are the page's, up to that end.
        const viewEnd = [...events].reverse().find((event) => event.kind === "turn_result")?.seq ?? events.length;
        const settled =
          settledServed && params.settled === true
            ? {
                schema: 1,
                lastSeq: viewEnd,
                writtenAt: Date.now(),
                hasMore: p.hasMore,
                pageThrough: events.length,
                queue: RESTORED_QUEUE,
                queued: RESTORED_QUEUE.length,
                pending: [],
                forkSeqs: p.events.filter((event) => event.kind === "turn_result").map((event) => event.seq),
                status: "idle",
                logLoaded: !restoring,
              }
            : null;
        return {
          session:
            settled && restoring
              ? { ...session, queue: RESTORED_QUEUE, queued: RESTORED_QUEUE.length, queueFrom: "settled" }
              : session,
          ...p,
          lastSeq: events.length,
          pageThrough: events.length,
          turnOpener: turnOpener(p.events[0], p.hasMore),
          ...(settledServed ? { settled } : {}),
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

  /// The turn fold's own reflow is not a load flip: under the shipped "answer" arm (#41213) a turn
  /// that ends folds its earlier replies under "Worked for", the transcript gets shorter and the
  /// prompt above scrolls back into view by design. This harness measures loading (open, reconnects,
  /// paging, a cold restart), so every page it records pins the arm that keeps every reply, as #41213
  /// pinned old arms in other suites; turn-fold-keeps-replies.test.ts covers the fold itself.
  const pinFoldArm = (page: Page) =>
    page.addInitScript(() => {
      (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = {
        "turn-fold-replies": "replies",
      };
    });

  /// Installs the fold pin and the per-frame row recorder before any pane script runs.
  const installRecorder = async (page: Page) => {
    await pinFoldArm(page);
    await recordRows(page);
  };
  const recordRows = (page: Page) =>
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
        // The restart detectors: the visible row set by frame (changes once rows show), frames that
        // show the New Tab page, each row's fold state by frame, and the pending (background) count.
        visibleSet: "",
        setChanges: [] as number[],
        newTab: [] as number[],
        folds: new Map<string, [number, string][]>(),
        pending: [] as [number, string][],
        overlaps: [] as string[],
        atBottom: false,
        leftBottom: [] as string[],
        // The settled cold open's detectors, from the first frame on (armed or not): each distinct
        // state the pane showed in order (blank, newtab, rows), the queued prompts the composer
        // shows by frame, and the fork controls on screen in the first frame that showed rows.
        states: [] as string[],
        queued: [] as [number, number][],
        forkFirstRows: undefined as number | undefined,
        // By painted frame, not by time: the queued count in the first frame that showed rows, and
        // the queued count changes in the frames after it.
        queuedFirstRows: undefined as number | undefined,
        queuedChangesAfterRows: 0,
        forks: [] as [number, number][],
        settledPainted: [] as number[],
      };
      if ((window as unknown as { __settledArmed?: boolean }).__settledArmed) state.on = true;
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
        // The rows a reader sees, in order: a change once rows showed is the view reshaping.
        const visibleIds = [...state.rows].filter(([, row]) => row.visible).map(([id]) => id);
        const set = visibleIds.join(",");
        if (set !== state.visibleSet) {
          if (state.on && state.visibleSet !== "") state.setChanges.push(Math.round(now));
          state.visibleSet = set;
        }
        // A pane with a chat that shows the New Tab page, for any frame.
        if (state.on && state.firstRow !== undefined && document.querySelector(".nt-screen")) {
          state.newTab.push(Math.round(now));
          changed = true;
        }
        // Each visible row's folds (their open state), recorded when it changes.
        for (const id of visibleIds) {
          const el = scroller!.querySelector(`.acpmux-row[data-row-id="${CSS.escape(id)}"]`);
          if (!el) continue;
          const sig = [...el.querySelectorAll("[aria-expanded]")].map((b) => b.getAttribute("aria-expanded")).join("");
          const seen = state.folds.get(id) ?? [];
          if (seen.at(-1)?.[1] !== sig) {
            seen.push([Math.round(now), sig]);
            state.folds.set(id, seen);
            if (seen.length > 1) changed = true;
          }
        }
        // The background tasks the composer counts (its tray's head, or its pull tab).
        const tray = document.querySelector(".acpmux-running-tray__title, .acpmux-tray-pull__tab");
        const count = tray?.textContent?.match(/\d+/)?.[0] ?? "";
        if (count && state.pending.at(-1)?.[1] !== count) {
          state.pending.push([Math.round(now), count]);
          changed = true;
        }
        // No two drawn rows overlap (a stale measured height or place draws one over another).
        if (state.on && !paneHidden) {
          const boxes = [...scroller!.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")]
            .filter((el) => !LIVE_LINES.has(el.getAttribute("data-row-id")!))
            .map((el) => [el.getAttribute("data-row-id")!, el.getBoundingClientRect()] as const)
            .filter(([, r]) => r.height > 0 && r.bottom > box!.top && r.top < box!.bottom)
            .sort((x, y) => x[1].top - y[1].top);
          for (let i = 1; i < boxes.length; i++)
            if (boxes[i]![1].top < boxes[i - 1]![1].bottom - 2) {
              state.overlaps.push(`${boxes[i - 1]![0]}/${boxes[i]![0]}@${Math.round(now)}`);
              break;
            }
        }
        // While the reader stays at the bottom, the newest row stays in view: the view never leaves it.
        if (state.on && state.atBottom && scroller && !paneHidden) {
          const gap = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight;
          if (gap > 48) state.leftBottom.push(`${Math.round(gap)}px@${Math.round(now)}`);
        }
        {
          const frameState = document.querySelector(".nt-screen") ? "newtab" : visibleIds.length > 0 ? "rows" : "blank";
          if (state.states.at(-1) !== frameState) state.states.push(frameState);
          const fold = document.querySelector(".acpmux-queue-fold")?.textContent?.match(/\d+/)?.[0];
          const queued = fold ? Number(fold) : document.querySelectorAll(".acpmux-queued").length;
          if (state.queued.at(-1)?.[1] !== queued) {
            if (state.queuedFirstRows !== undefined) state.queuedChangesAfterRows += 1;
            state.queued.push([Math.round(now), queued]);
            if (state.queued.length > 1) changed = true;
          }
          if (frameState === "rows" && state.queuedFirstRows === undefined) state.queuedFirstRows = queued;
          const forks = scroller?.querySelectorAll(".cv-fork-button").length ?? 0;
          if (frameState === "rows" && state.forkFirstRows === undefined) state.forkFirstRows = forks;
          if (state.forks.at(-1)?.[1] !== forks) state.forks.push([Math.round(now), forks]);
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
    overlaps: string[];
    leftBottom: string[];
    pending: [number, string][];
  };
  /// Whether the reader is at the bottom, for the stay-at-bottom detector.
  const atBottom = (page: Page, on: boolean) =>
    page.evaluate((value) => {
      (window as unknown as { __settled: { atBottom: boolean } }).__settled.atBottom = value;
    }, on);
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
        overlaps: s.overlaps,
        leftBottom: s.leftBottom,
        pending: s.pending,
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
        // The reader is at the newest message from here until they scroll up: it must stay in view
        // through the prompt, the stream and the reconnect, as every new row comes in.
        await atBottom(page, true);

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
        await atBottom(page, false);
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
          overlap_frames: all.overlaps.length,
          left_bottom_frames: all.leftBottom.length,
          examples: {
            flips: [...all.flips.text.slice(0, 6), ...all.flips.tool.slice(0, 3)],
            remounts: [...all.remounts.text.slice(0, 6), ...all.remounts.tool.slice(0, 3)],
            lost: [...all.lost.text.slice(0, 6), ...all.lost.tool.slice(0, 3)],
            overlaps: all.overlaps.slice(0, 4),
            left_bottom: all.leftBottom.slice(0, 4),
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
        // overlap_frames is reported, not yet gated: base draws the same few frames (a reply's last
        // growth placing the turn footer under it a frame late), a separate root fix.
        expect(report.left_bottom_frames).toBe(0);
      } finally {
        prompted = undefined;
        await page.close();
      }
    },
  );

  // Leo, 2026-11-11 (a recording of his chat right after an app restart): "this is so wack idk wtf
  // happened after restarting the loading is so wack". The first page reads the chat and leaves
  // what the app host keeps of it (its tail, its reading place), as the app does on quit; a second
  // page then opens it cold, as after the restart, from that and the daemon. From its first frame
  // the rows a reader sees, their folds and the background count must be the settled ones, and no
  // frame may show the New Tab page: later data only adds.
  // `settled`: acpmux serves its settled view (cmuxterm-hq#9655), which the page lays on the kept tail
  // it drew as live records, with no replay.
  for (const mode of ["old", "settled"] as const)
    test.each(engines.map(([name]) => name))(
      `%s: a long chat opened cold after a restart draws its settled rows, folds and count from the first frame (${mode})`,
      async (name) => {
        events.length = fixtureEnd;
        liveAt = fixtureLiveAt;
        record("mux", "turn_result", { status: "completed" });
        status = "idle";
        settledServed = mode === "settled";
        const kept = { tails: {}, anchors: {} };
        const before = await browsers.get(name)!.newPage({ viewport: { width: 1200, height: 860 } });
        try {
          await before.addInitScript((value) => {
            (globalThis as { cmuxDevHostKept?: unknown }).cmuxDevHostKept = value;
          }, kept);
          await installPaintedFrames(before);
          await installRecorder(before);
          await before.goto(url());
          await before.locator(".acpmux-row").first().waitFor({ timeout: 60_000 });
          await settle(before);
          // Quit: the page hands the host what it keeps (pagehide), as the app's quit does.
          await before.evaluate(() => dispatchEvent(new PageTransitionEvent("pagehide", { persisted: false })));
          Object.assign(
            kept,
            await before.evaluate(() =>
              JSON.parse(JSON.stringify((globalThis as { cmuxDevHostKept?: unknown }).cmuxDevHostKept)),
            ),
          );
        } finally {
          await before.close();
        }
        // SETTLED_LOAD_VIDEO=DIR records the cold open (the PR's before/after video).
        const videoDir = process.env.SETTLED_LOAD_VIDEO;
        const page = await browsers.get(name)!.newPage({
          viewport: { width: 1200, height: 860 },
          ...(videoDir ? { recordVideo: { dir: path.join(videoDir, name), size: { width: 1200, height: 860 } } } : {}),
        });
        try {
          await page.addInitScript((value) => {
            (globalThis as { cmuxDevHostKept?: unknown }).cmuxDevHostKept = value;
            (window as unknown as { __settledArmed?: boolean }).__settledArmed = true;
          }, kept);
          await installPaintedFrames(page);
          await installRecorder(page);
          const navigated = Date.now();
          await page.goto(url());
          await page.locator(".acpmux-row").first().waitFor({ timeout: 60_000 });
          // The daemon restarted with the app and is still restoring its chats: the pane's connection
          // drops and comes back a few times while the chat opens, and the background tasks restore.
          for (let round = 0; round < 3; round++) {
            const before = connections;
            drop();
            const deadline = Date.now() + 30_000;
            while ((connections === before || attached.size === 0) && Date.now() < deadline)
              await page.evaluate(() => window.cmuxPaintFrame());
          }
          const settledAt = await settle(page);
          const result = await page.evaluate(() => {
            const s = (window as unknown as { __settled: any }).__settled;
            const folds: string[] = [];
            for (const [id, seen] of s.folds as Map<string, [number, string][]>)
              if (seen.length > 1)
                folds.push(`${id}:${seen.map(([at, sig]: [number, string]) => `${sig || "-"}@${at}`).join(">")}`);
            return {
              frames: s.frames,
              firstRow: s.firstRow,
              setChanges: s.setChanges,
              newTab: s.newTab,
              folds,
              pending: s.pending,
              overlaps: s.overlaps,
              flips: s.flips,
              remounts: s.remounts,
              rowsSeen: { text: s.rowsSeen.text.size, tool: s.rowsSeen.tool.size },
            };
          });
          const report = {
            engine: name,
            case: `cold-restart-${mode}`,
            kept_tail_records:
              Object.values(kept.tails as Record<string, { events?: unknown[] }>)[0]?.events?.length ?? 0,
            frames: result.frames,
            first_row_ms: Math.round(result.firstRow ?? Number.NaN),
            settled_ms: Math.round(settledAt),
            wall_ms: Date.now() - navigated,
            rows_seen: result.rowsSeen,
            row_set_changes: result.setChanges.length,
            fold_changes: result.folds.length,
            new_tab_frames: result.newTab.length,
            pending_changes: Math.max(0, result.pending.length - 1),
            overlap_frames: result.overlaps.length,
            flips: { text: result.flips.text.length, tool: result.flips.tool.length },
            remounts: { text: result.remounts.text.length, tool: result.remounts.tool.length },
            examples: {
              row_set_changes: result.setChanges.slice(0, 8),
              folds: result.folds.slice(0, 4),
              pending: result.pending.slice(0, 8),
              flips: [...result.flips.text.slice(0, 4), ...result.flips.tool.slice(0, 2)],
              remounts: [...result.remounts.text.slice(0, 4), ...result.remounts.tool.slice(0, 2)],
            },
          };
          console.log(`settled-load: ${JSON.stringify(report)}`);
          expect(report.kept_tail_records).toBeGreaterThan(0);
          expect(Number.isFinite(settledAt)).toBe(true);
          expect(report.rows_seen.text).toBeGreaterThan(2);
          expect({
            row_set_changes: report.row_set_changes,
            new_tab_frames: report.new_tab_frames,
            pending_changes: report.pending_changes,
            flips: report.flips,
            remounts: report.remounts,
          }).toEqual({
            // fold_changes and overlap_frames are reported, not yet gated: base shows the same (the last
            // turn footer's Timeline toggle goes while the connection is down), a separate root fix.
            row_set_changes: 0,
            new_tab_frames: 0,
            pending_changes: 0,
            flips: { text: 0, tool: 0 },
            remounts: { text: 0, tool: 0 },
          });
        } finally {
          settledServed = false;
          await page.close();
        }
      },
    );

  // cmuxterm-hq#9655 stage 1 (Leo, 2026-11-12: "where is the better architecture the chat ...
  // only works 1% of the time now if you consider the appearance"): a chat opened cold after a
  // restart, with nothing kept on the Mac (the host's tail is in memory only), while acpmux is still
  // reading the chat's log. `old`: this acpmux serves no settled view, so its attach answers the newest
  // page with no queue and the queue comes later; `settled`: it serves `settled-attach-v1`, and the
  // attach answers the view written at the last turn end, queue and fork points with it. Reported per
  // mode; gated in `settled` only: the pane shows blank, then the settled chat, and nothing else
  // (no New Tab, no row set change, no queue change, the fork control in its first frame).
  for (const mode of ["old", "settled"] as const)
    test.each(engines.map(([name]) => name))(
      `%s: a chat opened cold while acpmux restores draws blank then its settled frame only (${mode})`,
      async (name) => {
        events.length = fixtureEnd;
        liveAt = fixtureLiveAt;
        record("mux", "turn_result", { status: "completed" });
        status = "idle";
        settledServed = mode === "settled";
        forkServed = true;
        restoring = true;
        attachesAsked.length = 0;
        const page = await browsers.get(name)!.newPage({ viewport: { width: 1200, height: 860 } });
        try {
          await page.addInitScript(() => {
            (window as unknown as { __settledArmed?: boolean }).__settledArmed = true;
          });
          await installPaintedFrames(page);
          await installRecorder(page);
          await page.goto(url());
          await page.locator(".acpmux-row").first().waitFor({ timeout: 60_000 });
          // acpmux finishes reading the log: the real queue arrives as a session change.
          await frames(page, 20);
          restoring = false;
          const restored = { ...summary(status), queue: RESTORED_QUEUE, queued: RESTORED_QUEUE.length };
          for (const ws of attached)
            ws.send(
              JSON.stringify({
                jsonrpc: "2.0",
                method: "_acpmux/session_changed",
                params: { sessionId: SESSION, session: restored, kind: "queue", seq: events.length },
              }),
            );
          const settledAt = await settle(page);
          const result = await page.evaluate(() => {
            const s = (window as unknown as { __settled: any }).__settled;
            return {
              states: s.states as string[],
              setChanges: s.setChanges as number[],
              newTab: s.newTab as number[],
              queued: s.queued as [number, number][],
              forkFirstRows: s.forkFirstRows as number | undefined,
              queuedFirstRows: s.queuedFirstRows as number | undefined,
              queuedChangesAfterRows: s.queuedChangesAfterRows as number,
              forks: s.forks as [number, number][],
              flips: s.flips,
              remounts: s.remounts,
              firstRow: s.firstRow as number | undefined,
              settledDrawn: document.documentElement.dataset.acpmuxSettledDrawn ?? "",
            };
          });
          const queuedSeq = result.queued.map(([, n]) => n);
          const report = {
            engine: name,
            case: `cold-restoring-${mode}`,
            settled_asked: attachesAsked.filter((p) => p.settled === true).length,
            attaches: attachesAsked.length,
            first_row_ms: Math.round(result.firstRow ?? Number.NaN),
            settled_ms: Math.round(settledAt),
            states: result.states.join(">"),
            state_flips: Math.max(0, result.states.length - 2) + (result.states[0] === "blank" ? 0 : 1),
            row_set_changes: result.setChanges.length,
            new_tab_frames: result.newTab.length,
            queued: queuedSeq.join(">"),
            queued_monotonic: queuedSeq.every((n, i) => i === 0 || n >= queuedSeq[i - 1]!),
            queued_in_first_rows_frame: result.queuedFirstRows ?? 0,
            queue_changes_after_rows: result.queuedChangesAfterRows,
            fork_in_first_rows_frame: result.forkFirstRows ?? 0,
            fork_changes: Math.max(0, result.forks.length - 1),
            flips: { text: result.flips.text.length, tool: result.flips.tool.length },
            remounts: { text: result.remounts.text.length, tool: result.remounts.tool.length },
            settled_drawn_marker: result.settledDrawn,
          };
          console.log(`settled-load: ${JSON.stringify(report)}`);
          expect(Number.isFinite(settledAt)).toBe(true);
          if (mode === "settled") {
            // The page asked for the view, with the page bounds the view is keyed on, every time.
            expect(report.settled_asked).toBe(report.attaches);
            for (const asked of attachesAsked)
              expect({ limit: asked.limit, maxBytes: asked.maxBytes, kinds: asked.kinds }).toEqual({
                limit: attachesAsked[0]!.limit,
                maxBytes: attachesAsked[0]!.maxBytes,
                kinds: attachesAsked[0]!.kinds,
              });
            expect({
              states: report.states,
              row_set_changes: report.row_set_changes,
              new_tab_frames: report.new_tab_frames,
              queued_monotonic: report.queued_monotonic,
              queued_in_first_rows_frame: report.queued_in_first_rows_frame,
              queue_changes_after_rows: report.queue_changes_after_rows,
              fork_in_first_rows_frame: report.fork_in_first_rows_frame > 0,
              flips: report.flips,
              remounts: report.remounts,
              settled_drawn_marker: report.settled_drawn_marker,
            }).toEqual({
              states: "blank>rows",
              row_set_changes: 0,
              new_tab_frames: 0,
              queued_monotonic: true,
              queued_in_first_rows_frame: RESTORED_QUEUE.length,
              queue_changes_after_rows: 0,
              fork_in_first_rows_frame: true,
              flips: { text: 0, tool: 0 },
              remounts: { text: 0, tool: 0 },
              settled_drawn_marker: "true",
            });
          } else expect(report.settled_asked).toBe(0);
        } finally {
          settledServed = false;
          forkServed = false;
          restoring = false;
          await page.close();
        }
      },
    );
});
