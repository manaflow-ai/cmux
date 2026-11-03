// l10n-allow-file: bench fixture prompts and replies, not shipped UI.
// What a turn's end moves while the reader is scrolled up (Leo, 2026-11-03: "im still getting these weird layout
// shift things when im already scrolled up"). The production pane (a vite build of the pane's dev entry) joins a
// stand-in acpmux holding eight finished turns and a running one taller than the view (notes and tool calls). The
// reader scrolls with the wheel into the running turn's work, so a mid-transcript row is anchored in view; then,
// with nothing touched, the turn runs on and ends: more calls start and finish, notes and the final answer stream,
// the turn ends (its work folds under one "Worked for", its footer and final row chrome appear). The window runs from
// the first of those updates to 1 s after the view settles past the turn's end. (A message from another agent
// arriving mid-turn splits the turn's fold, which hid #33286's bug: the scenario has none.)
// Rows (bench/perfRow.ts), per engine (WebKit's carry .webkit), p50 the median round and p95 the worst:
//   ui.transcript.turn_end.cls              Chromium: the Layout Instability API's layout-shift entries over the
//                                           window, without those after input (hadRecentInput; the wheel ends 600 ms
//                                           before). WebKit has no such entries: the visible rows' frame-by-frame
//                                           box diff (src/gallery/shift.ts).
//   ui.transcript.turn_end.anchor_drift_px  how far the first row in sight at the window's start moved in the view
//                                           at most; a row that left the view (folded away) counts the view height.
//   ui.transcript.turn_end.rows_lost        rows in sight at the window's start that the view no longer draws at its
//                                           end (a fold closed over them).
// The Layout Instability API does not count a fold closing over the view (0.0001 before #33286 and after, with ten
// rows folded away before): removed rows are not shifts. That is why drift and rows lost come from the rows' boxes.
// (ui.transcript.cls is ui-stability.bench.ts's: the transcript's gallery stage on open.) Each row's target is its
// budget: CLS 0.01, drift 1 px, rows lost 0. The perf cron (perf-cron.py, part "web-ui") lists a row newly over its
// target in its advisory regression issue; it never fails a check.
// Samplers stop when the round ends (stopSampling) or its page closes; finally closes every resource.
//   bun bench/transcript-turn-end-shift.bench.ts [rounds=3] [--engines chromium,webkit]
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { scoreBoxFrames, type BoxFrame } from "../src/gallery/shift";
import { installPaintedFrames } from "../test/support/paintedFrames";
import { perfRow } from "./perfRow";

const argv = process.argv.slice(2);
const enginesAt = argv.indexOf("--engines");
const ENGINES = (enginesAt >= 0 ? (argv[enginesAt + 1] ?? "") : "chromium,webkit").split(",");
const ROUNDS = Number(argv.find((arg, index) => /^\d+$/.test(arg) && argv[index - 1] !== "--engines") ?? 3);
if (!Number.isInteger(ROUNDS) || ROUNDS < 1 || ENGINES.some((name) => name !== "chromium" && name !== "webkit")) {
  console.error("usage: bun bench/transcript-turn-end-shift.bench.ts [rounds=3] [--engines chromium,webkit]");
  process.exit(2);
}
/// The budgets: a reader scrolled up sees nothing move.
const TARGET = { cls: 0.01, drift: 1, lost: 0 } as const;

const webviews = path.resolve(import.meta.dir, "..");
const SESSION = "0190a000-0000-7000-8000-0000000000e8";
const LIVE = "[data-row-id='thinking-live']";

// ---------- the stand-in acpmux ----------
let status = "running";
const summary = () => ({
  sessionId: SESSION,
  cwd: "/home/dev/sun",
  title: "Retry policy",
  harness: "claude",
  // A finished turn folds its work under one Worked for: the Codex family's fold (turns.ts).
  family: "codex",
  status,
  steering: true,
  queuePaused: false,
  queued: 0,
  queue: [],
  turnCount: 9,
  updatedAt: Date.now(),
});
const update = (body: Record<string, unknown>) => ({
  method: "session/update",
  params: { sessionId: "agent-1", update: body },
});
const chunk = (text: string) => update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
const ran = (id: string, state = "completed") =>
  update({
    sessionUpdate: "tool_call",
    toolCallId: id,
    title: `rg retry ${id}`,
    kind: "execute",
    status: state,
    rawInput: { command: `rg retry ${id}` },
  });
type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
const events: Event[] = [];
const record = (dir: string, kind: string, msg: Record<string, unknown>): Event => {
  const event = { sessionId: SESSION, seq: events.length + 1, at: Date.now(), dir, kind, msg };
  events.push(event);
  return event;
};
for (let turn = 0; turn < 8; turn++) {
  record("mux", "user_message", { text: `Check step ${turn + 1} of the retry plan`, promptId: `p-${turn}` });
  record("mux", "turn_started", {});
  record(
    "in",
    "agent_message_chunk",
    chunk(
      `Step ${turn + 1}: the client waits longer before each retry, capped at eight seconds, and stops ` +
        "after five attempts. The fetch tests cover a server that fails twice and then answers.",
    ),
  );
  record("mux", "turn_result", { status: "completed" });
}
record("mux", "user_message", { text: "Find every retry loop and fix the cap", promptId: "p-live" });
record("mux", "turn_started", {});
for (let step = 0; step < 14; step++) {
  record(
    "in",
    "agent_message_chunk",
    chunk(
      `Checking call site ${step + 1}: it retries on every error, so the cap has to apply here as well. ` +
        "The loop sleeps a fixed second between attempts and never gives up, which is what made the upload " +
        "queue hammer the server during the outage last week.\n\n",
    ),
  );
  record("in", "tool_call", ran(`t${step}`));
}
const opened = events.length;
const REPLY = [
  "Every retry loop now shares one capped backoff. The fetch client, the socket reconnect and the upload ",
  "queue each called their own sleep; they now call `backoff(attempt)`, which stops at eight seconds.\n\n",
  "- fetch client\n- socket reconnect\n- upload queue\n\n",
  "```ts\nexport const backoff = (attempt: number) => Math.min(8000, 250 * 2 ** attempt);\n```\n\n",
  "Final reply marker.",
];

function answer(method: string): unknown {
  switch (method) {
    case "initialize":
      return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    case "_acpmux/watch":
      return { sessions: [summary()] };
    case "_acpmux/attach":
      return { session: summary(), lastSeq: opened, events: events.slice(0, opened) };
    case "_acpmux/events":
      return { events: [], hasMore: false, lastSeq: events.length };
    default:
      return null;
  }
}
let socket: { send(data: string): void } | undefined;
const emit = (dir: string, kind: string, msg: Record<string, unknown>) =>
  socket?.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: record(dir, kind, msg) }));
const changed = () =>
  socket?.send(
    JSON.stringify({
      jsonrpc: "2.0",
      method: "_acpmux/session_changed",
      params: { sessionId: SESSION, session: summary(), kind: "status", seq: events.length },
    }),
  );
// ---------- the page side ----------
/** Init script: buffers every layout-shift entry with what moved. Self-contained (Playwright serializes it). */
function observeLayoutShifts() {
  type Shift = { at: number; value: number; input: boolean; sources: string[] };
  const w = window as unknown as { __shifts?: Shift[] };
  // WebKit has no layout-shift entries (and observe() does not throw for them): no __shifts, so the box diff scores it.
  if (w.__shifts || !PerformanceObserver.supportedEntryTypes?.includes("layout-shift")) return;
  const shifts: Shift[] = [];
  w.__shifts = shifts;
  const describe = (node: Node | null | undefined) => {
    if (!(node instanceof Element)) return node ? node.nodeName.toLowerCase() : "?";
    const row = node.closest<HTMLElement>("[data-row-id]")?.dataset.rowId;
    const cls = typeof node.className === "string" ? node.className.split(" ").filter(Boolean)[0] : undefined;
    return `${node.tagName.toLowerCase()}${cls ? `.${cls}` : ""}${row ? ` (row ${row})` : ""}`;
  };
  try {
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries() as unknown as {
        startTime: number;
        value: number;
        hadRecentInput: boolean;
        sources?: { node?: Node | null }[];
      }[])
        shifts.push({
          at: entry.startTime,
          value: entry.value,
          input: entry.hadRecentInput,
          sources: (entry.sources ?? []).map((source) => describe(source.node)),
        });
    }).observe({ type: "layout-shift", buffered: true });
  } catch {
    // Observation refused after all: no entries, so the box diff scores it.
    delete w.__shifts;
  }
}

/// Resolves once the transcript's offset and height have held, with nothing in it animating, for 12 painted frames.
const rest = (page: Page) =>
  page.evaluate(async () => {
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    const moving = () =>
      document
        .getAnimations()
        .some(
          (animation) =>
            animation.playState === "running" && Number.isFinite(animation.effect?.getComputedTiming().endTime),
        );
    let last = "";
    for (let held = 0, frames = 0; held < 12 && frames < 600; frames += 1) {
      await window.cmuxPaintFrame();
      const now = `${scroller.scrollTop}:${scroller.scrollHeight}`;
      held = now === last && !moving() ? held + 1 : 0;
      last = now;
    }
  });
const paint = (page: Page, frames: number) =>
  page.evaluate(async (count) => {
    for (let frame = 0; frame < count; frame++) await window.cmuxPaintFrame();
  }, frames);

type Sample = { id: string; x: number; y: number; width: number; height: number };
/// Samples every row box in the transcript's view once per painted frame, in the view's coordinates; returns the
/// window's start (performance.now()).
const startSampling = (page: Page) =>
  page.evaluate(() => {
    const w = window as unknown as { __rowFrames: Sample[][]; __stopRows: () => void };
    w.__rowFrames = [];
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    const read = () => {
      const view = scroller.getBoundingClientRect();
      const frame: Sample[] = [];
      for (const row of scroller.querySelectorAll<HTMLElement>("[data-row-id]")) {
        const box = row.getBoundingClientRect();
        if (box.height <= 0 || box.bottom <= view.top || box.top >= view.bottom) continue;
        frame.push({
          id: row.dataset.rowId!,
          x: box.x - view.x,
          y: box.y - view.y,
          width: box.width,
          height: box.height,
        });
      }
      w.__rowFrames.push(frame);
    };
    read();
    w.__stopRows = window.cmuxAfterPaint(() => {
      read();
    });
    return performance.now();
  });
const stopSampling = (page: Page, since: number) =>
  page.evaluate((since) => {
    const w = window as unknown as {
      __rowFrames: Sample[][];
      __stopRows: () => void;
      __shifts?: { at: number; value: number; input: boolean; sources: string[] }[];
    };
    w.__stopRows();
    const box = document.querySelector<HTMLElement>(".acpmux-scroll")!.getBoundingClientRect();
    return {
      frames: w.__rowFrames,
      view: { width: box.width, height: box.height },
      shifts: w.__shifts ? w.__shifts.filter((shift) => shift.at >= since) : null,
    };
  }, since);

type Round = { cls: number; boxCls: number; drift: number; lost: string[]; anchor: string; notes: string[] };

/// The window's numbers (pure).
export function measure(
  frames: Sample[][],
  view: { width: number; height: number },
  shifts: { at: number; value: number; input: boolean; sources: string[] }[] | null,
): Round {
  const ids = new Map<string, number>();
  const boxFrames: BoxFrame[] = frames.map(
    (frame) =>
      new Map(
        frame.map((row) => {
          if (!ids.has(row.id)) ids.set(row.id, ids.size + 1);
          return [ids.get(row.id)!, { box: row, label: `row ${row.id}` }] as const;
        }),
      ),
  );
  // No row in sight at the start is a broken setup, never a still view.
  if (!frames[0]?.length) throw new Error("no transcript row was in view when the window started");
  const box = scoreBoxFrames(boxFrames, view, { restedAtStart: true });
  const anchor = [...frames[0]!].sort((a, b) => a.y - b.y).find((row) => row.y + row.height > 0);
  let drift = 0;
  if (anchor)
    for (const frame of frames) {
      const now = frame.find((row) => row.id === anchor.id);
      drift = Math.max(drift, now ? Math.abs(now.y - anchor.y) : view.height);
    }
  const last = new Set(frames.at(-1)!.map((row) => row.id));
  const lost = frames[0]!.filter((row) => !last.has(row.id)).map((row) => row.id);
  const counted = (shifts ?? []).filter((shift) => !shift.input);
  const notes = [
    ...counted.map((shift) => `layout-shift ${shift.value.toFixed(4)} ${shift.sources.join(", ")}`),
    ...box.moves.slice(0, 8).map((move) => `box move ${move.label} frame ${move.frame} dx ${move.dx} dy ${move.dy}`),
  ];
  return {
    cls: shifts ? counted.reduce((sum, shift) => sum + shift.value, 0) : box.score,
    boxCls: box.score,
    drift: Math.round(drift * 10) / 10,
    lost,
    anchor: anchor?.id ?? "none",
    notes,
  };
}

async function round(browser: Browser, url: string): Promise<Round> {
  events.length = opened;
  status = "running";
  const page = await browser.newPage({ viewport: { width: 900, height: 640 } });
  try {
    await page.addInitScript(observeLayoutShifts);
    await installPaintedFrames(page);
    await page.goto(url);
    await page.locator(LIVE).waitFor({ timeout: 60_000 });
    await page.mouse.move(0, 0);
    await rest(page);
    // The reader scrolls with the wheel into the running turn's work, well off the end.
    await page.mouse.move(450, 300);
    const target = await page.locator(".acpmux-scroll").evaluate((node) => {
      const row = [...node.querySelectorAll<HTMLElement>("[data-row-id]")].find((each) =>
        each.textContent?.includes("Checking call site 6:"),
      );
      const view = node.getBoundingClientRect();
      return row ? node.scrollTop + row.getBoundingClientRect().top - view.top - 40 : node.scrollHeight / 2;
    });
    for (let step = 0; step < 30; step++) {
      const now = await page.locator(".acpmux-scroll").evaluate((node) => node.scrollTop);
      if (Math.abs(now - target) < 2) break;
      await page.mouse.wheel(0, Math.max(-400, Math.min(400, target - now)));
      await rest(page);
    }
    await rest(page);
    const fromEnd = await page
      .locator(".acpmux-scroll")
      .evaluate((node) => node.scrollHeight - node.clientHeight - node.scrollTop);
    if (fromEnd <= 200) throw new Error(`the reader is not scrolled up (${fromEnd} px from the end)`);
    // A beat with nothing happening, so the wheel's own moves end before the window starts.
    await page.waitForTimeout(600);

    const since = await startSampling(page);
    for (let step = 20; step < 24; step++) {
      emit("in", "tool_call", ran(`t${step}`, "in_progress"));
      await paint(page, 3);
      emit("in", "agent_message_chunk", chunk(`Call site ${step} also retries; `));
      await paint(page, 2);
      emit(
        "in",
        "tool_call_update",
        update({ sessionUpdate: "tool_call_update", toolCallId: `t${step}`, status: "completed" }),
      );
      await paint(page, 3);
    }
    await paint(page, 8);
    for (const part of REPLY) {
      emit("in", "agent_message_chunk", chunk(part));
      await paint(page, 3);
    }
    status = "idle";
    emit("mux", "turn_result", { status: "completed" });
    changed();
    // The footer, the fold and the rows' final heights land over the next frames; then 1 s more.
    await rest(page);
    await paint(page, 30);
    await rest(page);
    await page.waitForTimeout(1000);
    await paint(page, 2);
    const { frames, view, shifts } = await stopSampling(page, since);
    return measure(frames, view, shifts);
  } finally {
    await page.close();
  }
}

if (import.meta.main) {
  const releases: [string, () => unknown][] = [];
  const release = async () => {
    for (const [, stop] of [...releases].reverse()) {
      try {
        await stop();
      } catch {
        // Release the rest.
      }
    }
  };
  process.once("SIGINT", () => void release().then(() => process.exit(130)));
  try {
    const daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string };
          if (message.method === "_acpmux/attach") socket = ws;
          if (message.id !== undefined)
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method) }));
        },
      },
    });
    releases.push(["stand-in acpmux", () => daemon.stop(true)]);
    const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "turn-end-shift-bench-"));
    releases.push(["pane build", () => fs.rmSync(out, { recursive: true, force: true })]);
    const builtAt = performance.now();
    const { build } = await import("vite");
    await build({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      build: { outDir: out, emptyOutDir: true },
      logLevel: "error",
    });
    console.log(`turn-end-shift: pane built in ${((performance.now() - builtAt) / 1000).toFixed(0)} s`);
    const statics = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      async fetch(request) {
        const pathname = new URL(request.url).pathname;
        const file = Bun.file(path.join(out, pathname === "/" ? "index.html" : pathname));
        return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
      },
    });
    releases.push(["static server", () => statics.stop(true)]);
    const url = `http://127.0.0.1:${statics.port}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&session=${SESSION}`;

    let failed = 0;
    for (const engine of ENGINES) {
      const isChromium = engine === "chromium";
      let browser: Browser;
      try {
        browser = isChromium
          ? await chromium.launch({
              ...(process.env.CMUX_CHROME_HEADLESS_SHELL
                ? { executablePath: process.env.CMUX_CHROME_HEADLESS_SHELL }
                : { channel: "chrome" }),
              headless: true,
            })
          : await webkit.launch({ headless: true });
      } catch (error) {
        failed += 1;
        console.log(
          `turn-end-shift: ${engine} FAILED to launch: ${error instanceof Error ? error.message : String(error)}`,
        );
        continue;
      }
      releases.push([engine, () => browser.close()]);
      const rounds: Round[] = [];
      try {
        for (let index = 0; index < ROUNDS; index++) rounds.push(await round(browser, url));
      } catch (error) {
        failed += 1;
        console.log(`turn-end-shift: ${engine} FAILED: ${error instanceof Error ? error.message : String(error)}`);
      }
      if (!rounds.length) continue;
      const median = (values: number[]) => [...values].sort((a, b) => a - b)[Math.floor((values.length - 1) / 2)]!;
      // p50 the median round, p95 the worst: a shift in any one round is a miss of the budget. Shifts under 0.0001
      // are layout rounding: the row reads 0 then.
      const stat = (values: number[], round4 = false) => {
        const fix = (value: number) => (round4 ? Math.round(value * 1e4) / 1e4 : value);
        return { p50: fix(median(values)), p95: fix(Math.max(...values)) };
      };
      const cls = stat(
        rounds.map((r) => r.cls),
        true,
      );
      const drift = stat(rounds.map((r) => r.drift));
      const lost = stat(rounds.map((r) => r.lost.length));
      console.log(`turn-end-shift: ${engine}, ${rounds.length} rounds (p50 median, p95 worst)`);
      console.log("round | cls | box cls | anchor | drift px | rows lost");
      for (const [index, r] of rounds.entries())
        console.log(
          `${index + 1} | ${r.cls.toFixed(4)} | ${r.boxCls.toFixed(4)} | ${r.anchor} | ${r.drift} | ${r.lost.length} ${JSON.stringify(r.lost)}`,
        );
      for (const note of rounds.at(-1)!.notes.slice(0, 12)) console.log(`  ${note}`);
      const name = `ui.transcript.turn_end${isChromium ? "" : ".webkit"}`;
      perfRow({ name: `${name}.cls`, ...cls, unit: "score", target: TARGET.cls, floor: 0.001 });
      perfRow({ name: `${name}.anchor_drift_px`, ...drift, unit: "px", target: TARGET.drift, floor: 1 });
      perfRow({ name: `${name}.rows_lost`, ...lost, unit: "count", target: TARGET.lost, floor: 0.5 });
    }
    if (failed) process.exitCode = 1;
  } finally {
    await release();
  }
}
