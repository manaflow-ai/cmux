// l10n-allow-file: benchmark output, not shipped UI.
// The perf goals' always-available reading: a recorded transcript replayed live into the real pane while the machine
// is loaded, read through the same always-on frame tally Leo's NIGHTLY reports (#50373: frameTally.ts, the page's
// `_acpmux/perf {op:"tally"}` sends) and the renderer main thread's task time.
//
// Leo, 2026-11-23 (relayed): "Run the #50373 frame tally against a replayed transcript in a headless nightly on a GCP
// VM with stress-ng at 4x cores, and get frame_p95_ms and renderer_main_busy_pct publishing from there on every sensor
// pass, with the [his Mac's] reading as a second series. Done when the board has a number for both goals while my
// nightly is closed."
//
// cmuxterm-hq goals/visible-frame-p95-under-load.md and goals/renderer-main-busy.md read
// `perf_sensor.leo_nightly.*`, a sample of Leo's running NIGHTLY on his Mac; when it is closed they have no
// number. This bench is their proxy: scripts/measure/replay-under-load.sh runs it under `stress-ng --cpu 4*nproc` on a
// fleet VM and NOW publishes the reading as `perf_sensor.vm_replay`.
//
// The pane is a vite build of its dev entry (vite.config.acpmux-pane.mjs, production React), in headless Chromium,
// joined to a stand-in acpmux that serves one recorded session (default the chat simulator's replay fixture,
// test/fixtures/chat-sim/replay-lane-session.ndjson, a real lane chat sanitized). The page attaches to the session
// empty and running; the stand-in then sends the log's records as `_acpmux/event`s at RATE records a second, on its
// own clock as a daemon does, never waiting on a frame. After WARM seconds the measured window opens for SECONDS:
//   frame_p95_ms            the p95 of the frame gaps the page's frame tally sent in the window (its 0.1 ms buckets;
//                           a gap of 100 ms or more is its overflow bucket and reads 100). Null with frame_p95_reason
//                           when fewer than MIN_FRAMES gaps came: the chat drew nothing to count.
//   frame_p50_ms, frame_p99_ms, frames, frames_over_50ms   the same tally's other reads
//   renderer_main_busy_pct  the renderer main thread's task time over the window's wall time (CDP TaskDuration), %
//   long_tasks              tasks of 50 ms or more in the window, and longest_task_ms
//   records                 the records sent in the window
// With --rows (off by default: it turns the page's acpmuxPerf counters on, which costs main-thread time, so its
// busy and frame numbers are not the sensor's), a `rows` block: per display frame, the transcript rows React drew
// (perf.ts `row:`/`content:`/`mount:` counts, read each frame through window.cmuxAcpmuxDebug.renders()) against
// the rows inside the scroller's viewport plus ROWS_MARGIN_PX (an IntersectionObserver), and the rows drawn while
// outside it by row kind and trigger (mount, content: its row data changed, frame: only its frame's props did).
// Leo: "Why should non visible thing even affect the renderer thread anyways?"
//   bun bench/replay-under-load.bench.ts [--log FILE] [--rate 40] [--seconds 60] [--warm 5] [--out FILE] [--rows]
// Exit 0 with a reading (even a null frame p95, which says why), 1 when the page never attached or the run failed.
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium } from "./browsers";
import type { CDPSession } from "playwright";
import type { EventRecord } from "../src/agent-session/acpmux/direct";
import { parseLog, type ReplayLog } from "./replayLogs";

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : undefined;
};
const webviews = path.resolve(import.meta.dir, "..");
const LOG_FILE = flag("--log") ?? path.join(webviews, "test/fixtures/chat-sim/replay-lane-session.ndjson");
/// Records a second the stand-in sends: a streaming agent's token and tool updates come about this fast.
const RATE = Number(flag("--rate") ?? 40);
const SECONDS = Number(flag("--seconds") ?? 60);
const WARM = Number(flag("--warm") ?? 5);
const OUT = flag("--out");
const ROWS = argv.includes("--rows");
/// Rows this far above or below the scroller's viewport still count as visible (an overscan's worth).
const ROWS_MARGIN_PX = 200;
/// Fewer gaps than this in the window is no frame p95 (the goal's sensor holds the same floor, perf_sensor.py).
const MIN_FRAMES = 60;
/// frameTally.ts BUCKET_MS and BUCKETS: bucket i holds gaps in [i * 0.1, (i + 1) * 0.1) ms; BUCKETS holds 100 ms+.
const BUCKET_MS = 0.1;
const BUCKETS = 1000;
/// frameTally.ts FLUSH_MS, plus margin: the window's last gaps arrive at most this long after it closes.
const FLUSH_WAIT_MS = 6_000;
if (![RATE, SECONDS, WARM].every((n) => Number.isFinite(n) && n > 0)) {
  console.error(
    "usage: bun bench/replay-under-load.bench.ts [--log FILE] [--rate 40] [--seconds 60] [--warm 5] [--out FILE]",
  );
  process.exit(2);
}

/** p-th quantile (0..1) of a bucketed tally, in ms (pure). The overflow bucket reads as its floor, 100 ms. */
export function quantile(counts: Map<number, number>, p: number): number | null {
  const total = [...counts.values()].reduce((sum, n) => sum + n, 0);
  if (total === 0) return null;
  const rank = Math.ceil(p * total);
  let seen = 0;
  for (const index of [...counts.keys()].sort((a, b) => a - b)) {
    seen += counts.get(index)!;
    if (seen >= rank) return Math.round(Math.min(index, BUCKETS) * BUCKET_MS * 10) / 10;
  }
  return null;
}

/** Adds one `_acpmux/perf {op:"tally"}` request's gaps into counts (pure on its input; ignores anything else). */
type RowFrameSample = { touched: number; visible: number; offscreen: number };
export type RowsReading = {
  margin_px: number;
  frames: number;
  frames_touching: number;
  rows_touched_p50: number | null;
  rows_touched_p95: number | null;
  rows_visible_p50: number | null;
  rows_visible_p95: number | null;
  rows_mounted_p95: number | null;
  /// Over the frames that drew any row: per-frame touched/visible.
  touched_over_visible_p50: number | null;
  touched_over_visible_p95: number | null;
  rows_touched_total: number;
  rows_touched_offscreen_total: number;
  /// "kind:trigger" -> offscreen row draws, most first.
  offscreen_by_kind_trigger: Record<string, number>;
  /// The window's other render counters (perf.ts `renders` past the rows), most first.
  other_renders_top: Record<string, number>;
  reason: string | null;
};

/** Nearest-rank p-th quantile (0..1) of plain numbers (pure); null when empty. */
export function plainQuantile(values: number[], p: number): number | null {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.max(0, Math.ceil(p * sorted.length) - 1)]!;
}

/** The --rows block from the page's per-frame samples (pure). */
export function rowsReading(
  samples: (RowFrameSample & { mounted: number })[],
  offscreen: Record<string, number>,
  other: Record<string, number>,
  reason: string | null,
): RowsReading {
  const touching = samples.filter((s) => s.touched > 0);
  const ratios = touching.filter((s) => s.visible > 0).map((s) => s.touched / s.visible);
  const round = (n: number | null) => (n === null ? null : Math.round(n * 100) / 100);
  const top = (m: Record<string, number>, n: number) =>
    Object.fromEntries(
      Object.entries(m)
        .sort((a, b) => b[1] - a[1])
        .slice(0, n),
    );
  return {
    margin_px: ROWS_MARGIN_PX,
    frames: samples.length,
    frames_touching: touching.length,
    rows_touched_p50: plainQuantile(
      touching.map((s) => s.touched),
      0.5,
    ),
    rows_touched_p95: plainQuantile(
      touching.map((s) => s.touched),
      0.95,
    ),
    rows_visible_p50: plainQuantile(
      samples.map((s) => s.visible),
      0.5,
    ),
    rows_visible_p95: plainQuantile(
      samples.map((s) => s.visible),
      0.95,
    ),
    rows_mounted_p95: plainQuantile(
      samples.map((s) => s.mounted),
      0.95,
    ),
    touched_over_visible_p50: round(plainQuantile(ratios, 0.5)),
    touched_over_visible_p95: round(plainQuantile(ratios, 0.95)),
    rows_touched_total: samples.reduce((sum, s) => sum + s.touched, 0),
    rows_touched_offscreen_total: samples.reduce((sum, s) => sum + s.offscreen, 0),
    offscreen_by_kind_trigger: top(offscreen, 12),
    other_renders_top: top(other, 12),
    reason,
  };
}

export function addTally(counts: Map<number, number>, params: unknown): number {
  const p = params as { op?: unknown; bucketMs?: unknown; gaps?: unknown } | null;
  if (!p || p.op !== "tally" || p.bucketMs !== BUCKET_MS || !Array.isArray(p.gaps)) return 0;
  let added = 0;
  for (const pair of p.gaps) {
    if (!Array.isArray(pair) || pair.length !== 2) continue;
    const [index, count] = pair as [unknown, unknown];
    if (!Number.isInteger(index) || !Number.isInteger(count) || (index as number) < 0 || (count as number) <= 0)
      continue;
    const at = Math.min(BUCKETS, index as number);
    counts.set(at, (counts.get(at) ?? 0) + (count as number));
    added += count as number;
  }
  return added;
}

type Reading = {
  schema: "replay-under-load/v1";
  scenario: string;
  log: string;
  log_records: number;
  rate: number;
  seconds: number;
  records: number;
  frames: number;
  frame_p50_ms: number | null;
  frame_p95_ms: number | null;
  frame_p99_ms: number | null;
  frames_over_50ms: number;
  frame_p95_reason: string | null;
  frame_p95_source: "frame_tally";
  renderer_main_busy_pct: number | null;
  long_tasks: number;
  longest_task_ms: number;
  rows?: RowsReading;
  chromium: string;
  at: string;
};

async function taskSeconds(cdp: CDPSession): Promise<number> {
  const { metrics } = (await cdp.send("Performance.getMetrics")) as { metrics: { name: string; value: number }[] };
  return metrics.find((m) => m.name === "TaskDuration")?.value ?? 0;
}

async function run(): Promise<Reading> {
  const log: ReplayLog = parseLog(path.basename(LOG_FILE), fs.readFileSync(LOG_FILE, "utf8"));
  const releases: (() => unknown)[] = [];
  try {
    // ---------- the stand-in acpmux: serves the session, keeps the frame tally the page sends ----------
    let served = 0;
    let status = "running";
    let socket: { send(data: string): void } | undefined;
    let measuring = false;
    const counts = new Map<number, number>();
    const summary = () => ({
      ...log.summary,
      status,
      steering: true,
      queuePaused: false,
      queued: 0,
      queue: [],
      turnCount: log.events.filter((event) => event.kind === "user_message").length,
      updatedAt: log.events[Math.max(0, served - 1)]?.at ?? Date.now(),
    });
    const answer = (method: string): unknown => {
      switch (method) {
        case "initialize":
          return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
        case "_acpmux/watch":
          return { sessions: [summary()] };
        case "_acpmux/attach":
          return { session: summary(), lastSeq: log.events[served - 1]?.seq ?? 0, events: log.events.slice(0, served) };
        case "_acpmux/events":
          return { events: [], hasMore: false, lastSeq: log.events[served - 1]?.seq ?? 0 };
        default:
          return null;
      }
    };
    const daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: unknown };
          if (message.method === "_acpmux/attach") socket = ws;
          if (message.method === "_acpmux/perf" && measuring) addTally(counts, message.params);
          if (message.id !== undefined)
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method) }));
        },
      },
    });
    releases.push(() => daemon.stop(true));
    const emit = (event: EventRecord) =>
      socket?.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }));

    // ---------- the pane, built as production React ----------
    const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "replay-under-load-"));
    releases.push(() => fs.rmSync(out, { recursive: true, force: true }));
    const { build } = await import("vite");
    await build({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      build: { outDir: out, emptyOutDir: true },
      logLevel: "error",
    });
    const statics = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      async fetch(request) {
        const pathname = new URL(request.url).pathname;
        const file = Bun.file(path.join(out, pathname === "/" ? "index.html" : pathname));
        return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
      },
    });
    releases.push(() => statics.stop(true));
    const browser = await chromium.launch({ headless: true });
    releases.push(() => browser.close());
    const page = await browser.newPage({ viewport: { width: 900, height: 700 } });
    await page.addInitScript(() => {
      const w = window as unknown as { __long: { at: number; ms: number }[] };
      w.__long = [];
      new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) w.__long.push({ at: entry.startTime, ms: entry.duration });
      }).observe({ type: "longtask", buffered: true });
    });
    if (ROWS)
      await page.addInitScript((margin: number) => {
        type Probe = {
          on: boolean;
          samples: { touched: number; visible: number; offscreen: number; mounted: number }[];
          offscreen: Record<string, number>;
          other: Record<string, number>;
          reason: string | null;
        };
        const w = window as unknown as {
          __rows: Probe;
          cmuxAcpmuxDebug?: { renders(): Record<string, number> };
        };
        const probe: Probe = { on: false, samples: [], offscreen: {}, other: {}, reason: null };
        w.__rows = probe;
        const visible = new Set<string>();
        let io: IntersectionObserver | undefined;
        let root: Element | null = null;
        const watch = (node: Node) => {
          if (!(node instanceof Element) || !io) return;
          if (node.matches(".acpmux-row")) io.observe(node);
          for (const row of node.querySelectorAll(".acpmux-row")) io.observe(row);
        };
        new MutationObserver((list) => {
          const scroller = document.querySelector(".acpmux-scroll");
          if (scroller && scroller !== root) {
            root = scroller;
            io?.disconnect();
            visible.clear();
            io = new IntersectionObserver(
              (entries) => {
                for (const entry of entries) {
                  const id = (entry.target as HTMLElement).dataset.rowId;
                  if (!id) continue;
                  if (entry.isIntersecting) visible.add(id);
                  else visible.delete(id);
                }
              },
              { root: scroller, rootMargin: `${margin}px 0px` },
            );
            watch(scroller);
            return;
          }
          for (const record of list) for (const node of record.addedNodes) watch(node);
        }).observe(document, { childList: true, subtree: true });
        const kindOf = (id: string) => {
          const node = document.querySelector(`.acpmux-row[data-row-id="${CSS.escape(id)}"]`);
          const kind = node
            ? [...node.classList].find((c) => c.startsWith("acpmux-") && !c.startsWith("acpmux-row"))
            : undefined;
          return kind ? kind.slice("acpmux-".length) : node ? "row" : "unmounted";
        };
        const frame = () => {
          requestAnimationFrame(frame);
          if (!probe.on) return;
          const debug = w.cmuxAcpmuxDebug;
          if (!debug?.renders) {
            probe.reason = "the page has no cmuxAcpmuxDebug.renders()";
            return;
          }
          const counts = debug.renders();
          const touched = new Map<string, Set<string>>();
          for (const [key, n] of Object.entries(counts)) {
            const at = key.indexOf(":");
            const what = at > 0 ? key.slice(0, at) : "";
            if (what === "row" || what === "content" || what === "mount" || what === "frame") {
              const id = key.slice(at + 1);
              if (!touched.has(id)) touched.set(id, new Set());
              touched.get(id)!.add(what);
            } else if (!key.startsWith("remount:")) probe.other[key] = (probe.other[key] ?? 0) + n;
          }
          let offscreen = 0;
          for (const [id, whats] of touched) {
            if (visible.has(id)) continue;
            offscreen += 1;
            const trigger = whats.has("mount") ? "mount" : whats.has("content") ? "content" : "frame";
            const key = `${kindOf(id)}:${trigger}`;
            probe.offscreen[key] = (probe.offscreen[key] ?? 0) + 1;
          }
          probe.samples.push({
            touched: touched.size,
            visible: visible.size,
            offscreen,
            mounted: document.querySelectorAll(".acpmux-row").length,
          });
        };
        requestAnimationFrame(frame);
      }, ROWS_MARGIN_PX);
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Performance.enable");
    const url =
      `http://127.0.0.1:${statics.port}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}` +
      `&token=t&session=${encodeURIComponent(log.sessionId)}`;
    const consoleTail: string[] = [];
    page.on("console", (m) => consoleTail.push(`${m.type()}: ${m.text()}`.slice(0, 300)));
    page.on("pageerror", (e) => consoleTail.push(`pageerror: ${e.message}`.slice(0, 300)));
    await page.goto(url);
    try {
      await page.locator(".acpmux-scroll").waitFor({ timeout: 120_000 });
    } catch (error) {
      const body = (await page.evaluate(() => document.body?.innerText ?? "")).slice(0, 400);
      throw new Error(
        `the pane never drew its transcript: ${String(error).split("\n")[0]}; page: ${JSON.stringify(body)}; console: ${consoleTail.slice(-8).join(" | ")}`,
      );
    }
    for (let tries = 0; !socket && tries < 600; tries++) await page.waitForTimeout(50);
    if (!socket) throw new Error(`${log.name}: the pane never attached`);

    // ---------- the replay: RATE records a second on the stand-in's clock, never waiting on a frame ----------
    let sent = 0;
    const tickMs = 25;
    const perTick = RATE * (tickMs / 1000);
    let owed = 0;
    const timer = setInterval(() => {
      owed += perTick;
      while (owed >= 1 && served < log.events.length) {
        owed -= 1;
        emit(log.events[served++]!);
        if (measuring) sent += 1;
      }
    }, tickMs);
    releases.push(() => clearInterval(timer));
    await page.waitForTimeout(WARM * 1000);
    if (served >= log.events.length) throw new Error(`${log.name}: the log ran out in the warm-up; lower --rate`);
    measuring = true;
    if (ROWS)
      await page.evaluate(() => {
        const w = window as unknown as {
          __rows: { on: boolean };
          cmuxAcpmuxDebug?: { renders(): Record<string, number> };
        };
        w.cmuxAcpmuxDebug?.renders(); // from zero, and measurement on
        w.__rows.on = true;
      });
    const pageStart = await page.evaluate(() => performance.now());
    const taskBefore = await taskSeconds(cdp);
    const wallBefore = performance.now();
    await page.waitForTimeout(SECONDS * 1000);
    const taskAfter = await taskSeconds(cdp);
    const wallMs = performance.now() - wallBefore;
    const pageEnd = await page.evaluate(() => performance.now());
    const rowsProbe = ROWS
      ? ((await page.evaluate(() => {
          const probe = (window as unknown as { __rows: { on: boolean } }).__rows;
          probe.on = false;
          return probe;
        })) as {
          samples: (RowFrameSample & { mounted: number })[];
          offscreen: Record<string, number>;
          other: Record<string, number>;
          reason: string | null;
        })
      : undefined;
    clearInterval(timer);
    // The tally's last flush (at most FLUSH_MS after the window's last frames) still counts.
    await page.waitForTimeout(FLUSH_WAIT_MS);
    measuring = false;
    const long = (await page.evaluate(
      ([from, to]) =>
        (window as unknown as { __long: { at: number; ms: number }[] }).__long.filter(
          (t) => t.at >= from && t.at <= to,
        ),
      [pageStart, pageEnd] as const,
    )) as { at: number; ms: number }[];
    const frames = [...counts.values()].reduce((sum, n) => sum + n, 0);
    const over50 = [...counts.entries()].reduce((sum, [index, n]) => sum + (index * BUCKET_MS >= 50 ? n : 0), 0);
    const enough = frames >= MIN_FRAMES;
    return {
      schema: "replay-under-load/v1",
      scenario: `replay ${log.name} at ${RATE} records/s, ${SECONDS} s window`,
      log: log.name,
      log_records: log.events.length,
      rate: RATE,
      seconds: SECONDS,
      records: sent,
      frames,
      frame_p50_ms: quantile(counts, 0.5),
      frame_p95_ms: enough ? quantile(counts, 0.95) : null,
      frame_p99_ms: quantile(counts, 0.99),
      frames_over_50ms: over50,
      frame_p95_reason: enough
        ? null
        : `${frames} frames in the window, under ${MIN_FRAMES}: the chat drew too little to count`,
      frame_p95_source: "frame_tally",
      renderer_main_busy_pct: wallMs > 0 ? Math.round(((taskAfter - taskBefore) * 1000 * 1000) / wallMs) / 10 : null,
      long_tasks: long.length,
      longest_task_ms: Math.round(Math.max(0, ...long.map((t) => t.ms))),
      ...(rowsProbe
        ? { rows: rowsReading(rowsProbe.samples, rowsProbe.offscreen, rowsProbe.other, rowsProbe.reason) }
        : {}),
      chromium: browser.version(),
      at: new Date().toISOString().replace(/\.\d+Z$/, "Z"),
    };
  } finally {
    for (const stop of releases.reverse()) {
      try {
        await stop();
      } catch {
        // Release the rest.
      }
    }
  }
}

if (import.meta.main) {
  try {
    const reading = await run();
    const text = JSON.stringify(reading, null, 1);
    if (OUT) fs.writeFileSync(OUT, `${text}\n`);
    console.log(text);
    console.log(
      `replay-under-load: frame p95 ${reading.frame_p95_ms ?? "null"} ms over ${reading.frames} frames, renderer main ` +
        `${reading.renderer_main_busy_pct ?? "null"}% busy, ${reading.records} records in ${reading.seconds} s`,
    );
    if (reading.rows)
      console.log(
        `replay-under-load: rows touched p95 ${reading.rows.rows_touched_p95} vs visible p95 ` +
          `${reading.rows.rows_visible_p95} (touched/visible p95 ${reading.rows.touched_over_visible_p95}), ` +
          `${reading.rows.rows_touched_offscreen_total} of ${reading.rows.rows_touched_total} row draws offscreen`,
      );
  } catch (error) {
    console.error(`replay-under-load: FAILED: ${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 1;
  }
}
