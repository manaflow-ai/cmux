// Transcript shifts bench: the step 0 harness of cmuxterm-hq docs/design/agent-transcript-clean-slate.md
// (Leo, 2026-11-11: "the jostling is just insane"). bench/transcript-replay.bench.ts plays logs in at top
// speed and gates open and live layout shift and per-token cost; this one plays a reader's journey at
// a reader's pace and says which rows moved without the reader asking. It opens a chat of ROWS log records
// (default 50,000) over a synthetic daemon, then plays one fixed script against the real pane:
//
//   stream    a reply at 60 tokens/s while following the latest
//   page-up   scroll to the top of what is loaded and take an older page, 3 times
//   scrolled  stream again while scrolled up (nothing on screen may move)
//   fold      open and close a tool row 10 times
//   composer  grow the composer by 6 lines, at the latest and scrolled up
//
// After every painted frame it records every visible row's top. A shift is a visible row that
// moved in a frame where no user act (a wheel, a scroll, a click, a key) came within INPUT_MS:
//
// - the rows did not move as one: a row's move differs from the top row's move by more than the
//   height change of the rows between them (a row growing in view pushes the rows under it), or
// - the view drifted: scrolled up, the rows moved at all; following, the last row's bottom left
//   the viewport's bottom.
//
// It also times first paint (navigation to the first painted frame with a row in view) at ROWS and
// at 500 records. Prints one `BENCH {...}` line; asserts only that the run completed, so the
// numbers are a baseline each step lowers, never a gate that goes red on today's list.
//
// Run from webviews: CMUX_BROWSER_TESTS=1 bun scripts/agent-pane/transcript-shifts.bench.ts
// Env: ROWS (default 50000), CMUX_REPLAY_CAPTURE_DIR (a video and the per-frame shift log),
// REPLAY_HASH (added to the pane URL's hash: `anchoredList=1` draws the anchored list, step 4).
// l10n-allow-file: synthetic transcript and measurement diagnostics.
import assert from "node:assert/strict";
import path from "node:path";
import { mkdir, writeFile } from "node:fs/promises";
import { chromium, type Page } from "playwright";
import { createServer } from "vite";
import { installPaintedFrames } from "../../test/support/paintedFrames";
import { warmViteServer } from "../../test/support/warmDevServer";
import { loadTurn, streamedReply, type LoadStep } from "../../src/agent-session/acpmux/loadFixture";

assert.equal(process.env.CMUX_BROWSER_TESTS, "1", "Run on a browser worker: CMUX_BROWSER_TESTS=1");
const ROWS = Number(process.env.ROWS ?? 50_000);
const SMALL_ROWS = 500;
const TOKENS_PER_SECOND = 60;
const INPUT_MS = 500;
const capture = process.env.CMUX_REPLAY_CAPTURE_DIR;
if (capture) await mkdir(capture, { recursive: true });

type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: unknown };
type Params = { beforeSeq?: number; afterSeq?: number; limit?: number };

/** A synthetic daemon holding one chat of `rows` log records, built from the load fixture's turns. */
function syntheticDaemon(rows: number, sessionId: string) {
  const events: Event[] = [];
  const base = 1_791_000_000_000;
  const record = (dir: string, kind: string, msg: unknown) => {
    const event = { sessionId, seq: events.length + 1, at: base + events.length * 1000, dir, kind, msg };
    events.push(event);
    return event;
  };
  const recordStep = (step: LoadStep, turn: number) => {
    if ("update" in step)
      return record("in", String(step.update.sessionUpdate), {
        method: "session/update",
        params: { sessionId: "agent-1", update: step.update },
      });
    const ids = { turnId: `t-${turn}`, promptId: `p-${turn}` };
    if (step.mux === "user_message") return record("mux", "user_message", { ...step.msg, promptId: ids.promptId });
    if (step.mux === "turn_result")
      return record("mux", "turn_result", { ...step.msg, stopReason: "end_turn", ...ids });
    return record("mux", step.mux, { ...step.msg, ...ids });
  };
  let turns = 0;
  while (events.length < rows) {
    for (const step of loadTurn(turns)) recordStep(step, turns);
    turns++;
  }
  const session = () => ({
    sessionId,
    cwd: "/mock/project",
    title: `Replay ${rows} records`,
    harness: "claude",
    family: "claude",
    status: "ready",
    turnCount: turns,
    updatedAt: base,
    lastSeq: events.length,
  });
  const olderReads: number[] = [];
  const pageOf = (params: Params) => {
    const before = params.beforeSeq ?? Infinity;
    const after = params.afterSeq ?? 0;
    // Records are seq-ordered and dense: slice by index, so a page costs the same at any length.
    const end = Math.min(events.length, Number.isFinite(before) ? before - 1 : events.length);
    const start = Math.max(after, 0);
    const limit = Math.min(params.limit ?? 80, 80);
    const from = Math.max(start, end - limit);
    return { events: events.slice(from, end), hasMore: from > start, lastSeq: events.length };
  };
  const sockets = new Set<{ send(data: string): void }>();
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(request, srv) {
      return srv.upgrade(request, { data: undefined }) ? undefined : new Response("synthetic", { status: 426 });
    },
    websocket: {
      open: (ws) => void sockets.add(ws),
      close: (ws) => void sockets.delete(ws),
      message(ws, raw) {
        const { id, method, params = {} } = JSON.parse(String(raw)) as { id?: number; method: string; params?: Params };
        if (id === undefined) return;
        if (method === "_acpmux/events" && params.beforeSeq) olderReads.push(params.beforeSeq);
        const result =
          method === "initialize"
            ? { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } }
            : method === "_acpmux/watch"
              ? { sessions: [session()] }
              : method === "_acpmux/attach"
                ? { session: session(), ...pageOf(params) }
                : method === "_acpmux/events"
                  ? pageOf(params)
                  : null;
        ws.send(JSON.stringify({ jsonrpc: "2.0", id, result }));
      },
    },
  });
  /** Appends a record and pushes it to every attached page, as the daemon does for a live turn. */
  const push = (dir: string, kind: string, msg: unknown) => {
    const event = record(dir, kind, msg);
    const frame = JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event });
    for (const socket of sockets) socket.send(frame);
  };
  return { server, push, olderReads, turns: () => turns, events };
}

/** The page side of the probe: records every visible row's top after each painted frame. */
function installProbe(inputMs: number) {
  type Row = { top: number; height: number };
  type Phase = {
    frames: number;
    inputFrames: number;
    shiftFrames: number;
    rowShifts: number;
    jostleRows: number;
    driftFrames: number;
    maxShiftPx: number;
    inputJostleRows: number;
    scrollWrites: number;
  };
  const w = window as unknown as Record<string, unknown> & Window;
  const scroller = () => document.querySelector<HTMLElement>(".acpmux-scroll");
  // Within this many px of the end, the pane is following (the panes' own pin slop).
  const FOLLOW_SLOP = 2;
  let lastAct = -Infinity;
  const act = () => (lastAct = performance.now());
  for (const kind of ["wheel", "pointerdown", "keydown", "touchmove"])
    addEventListener(kind, act, { capture: true, passive: true });
  const phases: Record<string, Phase> = {};
  const trace: { writer: string }[] = [];
  (globalThis as { __cmuxScrollTrace?: unknown }).__cmuxScrollTrace = trace;
  let traced = 0;
  const writers: Record<string, number> = {};
  let phase = "open";
  const log: unknown[] = [];
  let previous: { rows: Map<string, Row>; order: string[]; gap: number } | undefined;
  const sample = () => {
    const node = scroller();
    if (!node) return undefined;
    const box = node.getBoundingClientRect();
    const rows = new Map<string, Row>();
    const order: string[] = [];
    for (const row of node.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")) {
      const r = row.getBoundingClientRect();
      if (r.height <= 0 || r.bottom <= box.top || r.top >= box.bottom) continue;
      const id = row.dataset.rowId!;
      rows.set(id, { top: r.top - box.top, height: r.height });
      order.push(id);
    }
    order.sort((a, b) => rows.get(a)!.top - rows.get(b)!.top);
    return { rows, order, gap: node.scrollHeight - node.clientHeight - node.scrollTop };
  };
  const stop = w.cmuxAfterPaint((frame) => {
    const now = sample();
    if (!now) return;
    const p = (phases[phase] ??= {
      frames: 0,
      inputFrames: 0,
      shiftFrames: 0,
      rowShifts: 0,
      jostleRows: 0,
      driftFrames: 0,
      maxShiftPx: 0,
      inputJostleRows: 0,
      scrollWrites: 0,
    });
    p.frames++;
    // Writes to the offset since the last frame, by writer (ScrollController's trace, when it has one).
    for (; traced < trace.length; traced++) {
      p.scrollWrites++;
      writers[trace[traced]!.writer] = (writers[trace[traced]!.writer] ?? 0) + 1;
    }
    const before = previous;
    previous = now;
    if (!before) return;
    const input = frame - lastAct < inputMs;
    if (input) p.inputFrames++;
    const common = now.order.filter((id) => before.rows.has(id));
    if (!common.length) return;
    const following = before.gap <= FOLLOW_SLOP;
    const first = common[0]!;
    const base = now.rows.get(first)!.top - before.rows.get(first)!.top;
    let moved = 0;
    let jostle = 0;
    let worst = 0;
    const ids: string[] = [];
    // A row's expected move: the top row's, plus the growth of the rows between them.
    let growth = 0;
    for (const id of common) {
      const a = before.rows.get(id)!;
      const b = now.rows.get(id)!;
      const off = Math.abs(b.top - a.top - base - growth);
      if (off > 1) {
        jostle++;
        worst = Math.max(worst, off);
        if (ids.length < 3) ids.push(id);
      }
      growth += b.height - a.height;
    }
    // Inside an act's window the view may move as the act asks; rows still move as one.
    if (input) {
      p.inputJostleRows += jostle;
      return;
    }
    // Drift: scrolled up, nothing may move; following, the bottom edge holds.
    // Following, the gap may rest anywhere inside the slop; leaving it is drift.
    const drift = following ? now.gap > FOLLOW_SLOP || now.gap < -1 : Math.abs(base) > 1;
    if (drift) worst = Math.max(worst, following ? Math.abs(now.gap) : Math.abs(base));
    moved = drift ? common.length : jostle;
    if (moved) {
      p.shiftFrames++;
      p.rowShifts += moved;
      p.jostleRows += jostle;
      if (drift) p.driftFrames++;
      p.maxShiftPx = Math.max(p.maxShiftPx, worst);
      if (log.length < 5000)
        log.push({ phase, frame: Math.round(frame), moved, jostle, drift, base, gap: now.gap, worst, ids });
    }
  });
  w.replayProbe = {
    setPhase: (name: string) => {
      phase = name;
      previous = undefined;
    },
    act,
    result: () => ({ phases, log, writers }),
    stop,
  };
}

/** First paint: navigation start to the first painted frame with a transcript row in view. */
function installFirstPaint() {
  const w = window as unknown as Record<string, unknown>;
  const started = performance.now();
  // The dev server's module load dominates navigation-to-paint; the daemon socket's open is where
  // the chat's own work starts (not the dev server's own HMR socket, which opens first).
  const endpoint = new URLSearchParams(location.hash.slice(1)).get("endpoint") ?? "";
  const Socket = window.WebSocket;
  window.WebSocket = class extends Socket {
    constructor(...args: ConstructorParameters<typeof WebSocket>) {
      super(...args);
      if (endpoint && String(args[0]).startsWith(endpoint)) w.replaySocketAt ??= performance.now();
    }
  };
  const tick = (frame: number) => {
    const node = document.querySelector<HTMLElement>(".acpmux-scroll");
    const row = node?.querySelector<HTMLElement>(".acpmux-row[data-row-id]");
    if (node && row && row.getBoundingClientRect().height > 0) {
      // Read after the frame paints, as paintedFrames does.
      setTimeout(() => (w.replayFirstPaint = frame), 0);
      return;
    }
    // Stop condition: give up after 60 s.
    if (frame - started < 60_000) requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
}

const vite = await createServer({
  configFile: path.resolve(import.meta.dir, "../../vite.config.acpmux-pane.mjs"),
  server: { port: 0, host: "127.0.0.1", strictPort: false },
  logLevel: "error",
});
const browser = await chromium.launch({ channel: "chrome", headless: true });
const daemons: ReturnType<typeof syntheticDaemon>[] = [];
const VIEWPORT = { width: 900, height: 760 };

async function openChat(rows: number, record: boolean) {
  const sessionId = `0190a000-0000-7000-8000-${String(rows).padStart(12, "0")}`;
  const built = performance.now();
  const daemon = syntheticDaemon(rows, sessionId);
  daemons.push(daemon);
  const buildMs = performance.now() - built;
  const context = await browser.newContext({
    viewport: VIEWPORT,
    ...(record && capture ? { recordVideo: { dir: capture, size: VIEWPORT } } : {}),
  });
  const page = await context.newPage();
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.addInitScript(installFirstPaint);
  await installPaintedFrames(page);
  const { port } = vite.httpServer!.address() as { port: number };
  const extra = process.env.REPLAY_HASH ? `&${process.env.REPLAY_HASH}` : "";
  await page.goto(
    `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.server.port}/`)}&token=t&session=${sessionId}${extra}`,
  );
  await page.waitForFunction(
    () => typeof (window as unknown as Record<string, unknown>).replayFirstPaint === "number",
    {
      timeout: 60_000,
    },
  );
  const { firstPaintMs, socketToPaintMs } = await page.evaluate(() => {
    const w = window as unknown as { replayFirstPaint: number; replaySocketAt?: number };
    return { firstPaintMs: w.replayFirstPaint, socketToPaintMs: w.replayFirstPaint - (w.replaySocketAt ?? 0) };
  });
  // The records at open: streaming adds a timing-dependent number of them later.
  return { daemon, context, page, errors, firstPaintMs, socketToPaintMs, buildMs, openRows: daemon.events.length };
}

const frames = (page: Page, count: number) =>
  page.evaluate(async (n) => {
    for (let i = 0; i < n; i++) await window.cmuxPaintFrame();
  }, count);
const setPhase = (page: Page, name: string) =>
  page.evaluate(
    (n) => (window as unknown as { replayProbe: { setPhase(n: string): void } }).replayProbe.setPhase(n),
    name,
  );

/** Streams `seconds` of a reply at TOKENS_PER_SECOND, a token about 4 characters, one push per frame's worth. */
async function stream(daemon: ReturnType<typeof syntheticDaemon>, page: Page, turn: number, seconds: number) {
  const ids = { turnId: `t-${turn}`, promptId: `p-${turn}` };
  daemon.push("mux", "user_message", { text: `Turn ${turn}: stream a long answer`, promptId: ids.promptId });
  daemon.push("mux", "turn_started", ids);
  const text = streamedReply(turn, 40);
  const tokens = text.match(/.{1,4}/gs) ?? [];
  const total = Math.min(tokens.length, TOKENS_PER_SECOND * seconds);
  const started = performance.now();
  let sent = 0;
  while (sent < total) {
    const due = Math.min(total, Math.floor(((performance.now() - started) / 1000) * TOKENS_PER_SECOND) + 1);
    if (due > sent) {
      daemon.push("in", "agent_message_chunk", {
        method: "session/update",
        params: {
          sessionId: "agent-1",
          update: {
            sessionUpdate: "agent_message_chunk",
            content: { type: "text", text: tokens.slice(sent, due).join("") },
          },
        },
      });
      sent = due;
    }
    // The pacing is the behavior under test: one painted frame between pushes.
    await page.evaluate(() => window.cmuxPaintFrame());
  }
  daemon.push("mux", "turn_result", { status: "completed", stopReason: "end_turn", ...ids });
  await frames(page, 30);
}

/** Scrolls up a screen at a time, as a reader does, until the daemon is asked for an older page. */
async function pageUp(daemon: ReturnType<typeof syntheticDaemon>, page: Page) {
  const asked = daemon.olderReads.length;
  for (let step = 0; step < 400 && daemon.olderReads.length === asked; step++) {
    await page.evaluate(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      node.dispatchEvent(new WheelEvent("wheel", { deltaY: -node.clientHeight, bubbles: true }));
      node.scrollTop = Math.max(0, node.scrollTop - node.clientHeight);
    });
    await frames(page, 2);
  }
  assert.ok(daemon.olderReads.length > asked, "scrolling up asked for an older page");
  // The page lands and settles with no input: these are the frames that count.
  await frames(page, 90);
}

async function foldCycles(page: Page, count: number) {
  for (let cycle = 0; cycle < count; cycle++) {
    for (let click = 0; click < 2; click++) {
      const clicked = await page.evaluate(() => {
        const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const box = node.getBoundingClientRect();
        const middle = box.top + box.height / 2;
        const toggles = [...node.querySelectorAll<HTMLElement>("button[aria-expanded]")].filter((b) => {
          const r = b.getBoundingClientRect();
          return r.height > 0 && r.top > box.top && r.bottom < box.bottom;
        });
        toggles.sort(
          (a, b) => Math.abs(a.getBoundingClientRect().top - middle) - Math.abs(b.getBoundingClientRect().top - middle),
        );
        const target = toggles[0];
        if (!target) return false;
        target.dataset.replayFold = "1";
        return true;
      });
      if (!clicked) return cycle;
      await page.locator("[data-replay-fold]").first().click();
      await page.evaluate(() => document.querySelector("[data-replay-fold]")?.removeAttribute("data-replay-fold"));
      await frames(page, 45);
    }
  }
  return count;
}

async function growComposer(page: Page, lines: number) {
  const field = page.locator(".acpmux-md").first();
  await field.click();
  for (let line = 0; line < lines; line++) {
    await page.keyboard.type(`composer line ${line}`);
    await page.keyboard.press("Shift+Enter");
    await frames(page, 4);
  }
  await frames(page, 60);
  for (let i = 0; i < lines * 2; i++) await page.keyboard.press("Control+Backspace");
  await page.keyboard.press("Control+a");
  await page.keyboard.press("Backspace");
  await frames(page, 60);
}

const runs: Record<string, unknown> = {};
const opened: Awaited<ReturnType<typeof openChat>>[] = [];
try {
  await vite.listen();
  await warmViteServer(vite, "/");
  const small = await openChat(SMALL_ROWS, false);
  opened.push(small);
  runs.small = {
    rows: SMALL_ROWS,
    firstPaintMs: Math.round(small.firstPaintMs),
    socketToPaintMs: Math.round(small.socketToPaintMs),
  };
  await small.context.close();

  const big = await openChat(ROWS, true);
  opened.push(big);
  const { page, daemon } = big;
  await page.evaluate(installProbe, INPUT_MS);
  await frames(page, 60);
  let turn = daemon.turns();

  await setPhase(page, "stream");
  await stream(daemon, page, turn++, 6);

  await setPhase(page, "page-up");
  for (let i = 0; i < 3; i++) await pageUp(daemon, page);

  await setPhase(page, "scrolled");
  await stream(daemon, page, turn++, 4);

  await setPhase(page, "fold");
  const folds = await foldCycles(page, 10);

  await setPhase(page, "composer-scrolled");
  await growComposer(page, 6);

  await page.evaluate(() => {
    const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    node.dispatchEvent(new WheelEvent("wheel", { deltaY: node.scrollHeight, bubbles: true }));
    node.scrollTop = node.scrollHeight;
  });
  await frames(page, 60);
  await setPhase(page, "composer-latest");
  await growComposer(page, 6);

  const probe = await page.evaluate(() => {
    const p = (window as unknown as { replayProbe: { result(): unknown; stop(): void } }).replayProbe;
    p.stop();
    return p.result() as {
      phases: Record<string, Record<string, number>>;
      log: unknown[];
      writers: Record<string, number>;
    };
  });
  const totals = {
    frames: 0,
    inputFrames: 0,
    shiftFrames: 0,
    rowShifts: 0,
    jostleRows: 0,
    driftFrames: 0,
    maxShiftPx: 0,
    inputJostleRows: 0,
    scrollWrites: 0,
  };
  for (const p of Object.values(probe.phases))
    for (const key of Object.keys(totals) as (keyof typeof totals)[])
      totals[key] = key === "maxShiftPx" ? Math.max(totals[key], p[key] ?? 0) : totals[key] + (p[key] ?? 0);
  totals.maxShiftPx = Math.round(totals.maxShiftPx);
  runs.big = {
    rows: big.openRows,
    turns: daemon.turns(),
    buildMs: Math.round(big.buildMs),
    firstPaintMs: Math.round(big.firstPaintMs),
    socketToPaintMs: Math.round(big.socketToPaintMs),
    olderReads: daemon.olderReads.length,
    folds,
    totals,
    writers: probe.writers,
    phases: probe.phases,
    errors: big.errors.slice(0, 5),
  };
  if (capture) await writeFile(path.join(capture, "shifts.json"), JSON.stringify(probe.log, null, 1));
  console.log(`BENCH ${JSON.stringify({ bench: "transcript-shifts", inputMs: INPUT_MS, ...runs })}`);
  assert.ok(totals.frames > 0, "the probe saw painted frames");
} finally {
  for (const run of opened) await run.context.close().catch(() => undefined);
  await browser.close();
  await vite.close();
  for (const daemon of daemons) await daemon.server.stop(true);
}
