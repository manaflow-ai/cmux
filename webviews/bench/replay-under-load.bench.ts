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
//   split                   the same window's renderer main thread by CDP metric, % of wall: task (TaskDuration, the
//                           busy number), cpu (ThreadTime: the CPU the thread really ran; under load task - cpu is
//                           time the thread was runnable but descheduled), script, layout, style (Script/Layout/
//                           RecalcStyleDuration)
// With --work, frame_work_p50/p95/p99_ms: each frame's work from its animation frame callback until the page rendered
// it (a message posted in the callback), orchestrator-16.bench.ts's measure, so the two benches read the same thing.
//   bun bench/replay-under-load.bench.ts [--log FILE] [--rate 40] [--seconds 60] [--warm 5] [--out FILE] [--profile]
//     [--work]
// Exit 0 with a reading (even a null frame p95, which says why), 1 when the page never attached or the run failed.
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium } from "./browsers";
import type { CDPSession } from "playwright";
import type { EventRecord } from "../src/agent-session/acpmux/direct";
import { parseLog, type ReplayLog } from "./replayLogs";
import { printProfile, type CpuProfile } from "./support/profile";

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
const PROFILE = argv.includes("--profile");
const WORK = argv.includes("--work");
/// `--experiment ID=ARM` (repeatable): the arm the pane runs, as the gallery's override sets it
/// (experiments/experiment.ts `globalThis.cmuxExperiments`), for a before/after on one harness.
const EXPERIMENTS: Record<string, string> = Object.fromEntries(
  argv.flatMap((arg, at) =>
    arg === "--experiment" && argv[at + 1]?.includes("=") ? [argv[at + 1]!.split("=", 2)] : [],
  ),
);
/// Fewer gaps than this in the window is no frame p95 (the goal's sensor holds the same floor, perf_sensor.py).
const MIN_FRAMES = 60;
/// frameTally.ts BUCKET_MS and BUCKETS: bucket i holds gaps in [i * 0.1, (i + 1) * 0.1) ms; BUCKETS holds 100 ms+.
const BUCKET_MS = 0.1;
const BUCKETS = 1000;
/// frameTally.ts FLUSH_MS, plus margin: the window's last gaps arrive at most this long after it closes.
const FLUSH_WAIT_MS = 6_000;
if (![RATE, SECONDS, WARM].every((n) => Number.isFinite(n) && n > 0)) {
  console.error(
    "usage: bun bench/replay-under-load.bench.ts [--log FILE] [--rate 40] [--seconds 60] [--warm 5] [--out FILE] [--profile]",
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
  split: Split;
  frame_work_p50_ms?: number | null;
  frame_work_p95_ms?: number | null;
  frame_work_p99_ms?: number | null;
  chromium: string;
  at: string;
};

const SPLIT = {
  task: "TaskDuration",
  cpu: "ThreadTime",
  script: "ScriptDuration",
  layout: "LayoutDuration",
  style: "RecalcStyleDuration",
} as const;
export type Split = Record<keyof typeof SPLIT, number | null>;

async function mainMetrics(cdp: CDPSession): Promise<Record<string, number>> {
  const { metrics } = (await cdp.send("Performance.getMetrics")) as { metrics: { name: string; value: number }[] };
  return Object.fromEntries(metrics.map((m) => [m.name, m.value]));
}

/** Each split metric's seconds between two reads as % of wallMs, one decimal (pure). */
export function splitOf(before: Record<string, number>, after: Record<string, number>, wallMs: number): Split {
  const out = {} as Split;
  for (const [key, name] of Object.entries(SPLIT) as [keyof typeof SPLIT, string][]) {
    const a = after[name];
    const b = before[name];
    out[key] = wallMs > 0 && a !== undefined && b !== undefined ? Math.round(((a - b) * 1e6) / wallMs) / 10 : null;
  }
  return out;
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
      build: { outDir: out, emptyOutDir: true, ...(PROFILE ? { minify: false } : {}) },
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
    await page.addInitScript((arms) => {
      if (Object.keys(arms).length > 0)
        (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = arms;
      const w = window as unknown as { __long: { at: number; ms: number }[] };
      w.__long = [];
      new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) w.__long.push({ at: entry.startTime, ms: entry.duration });
      }).observe({ type: "longtask", buffered: true });
    }, EXPERIMENTS);
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Performance.enable");
    if (PROFILE) {
      await cdp.send("Profiler.enable");
      await cdp.send("Profiler.setSamplingInterval", { interval: 200 });
      await cdp.send("Profiler.start");
    }
    const url =
      `http://127.0.0.1:${statics.port}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}` +
      `&token=t&session=${encodeURIComponent(log.sessionId)}` +
      // A shipped build's scheme, as Leo's NIGHTLY names: the dev host's default `cmux-dev` turns on the dev-only
      // layout-motion audit (devMotionAudit.ts), which sampled every box each frame and was ~8% of this reading.
      `&scheme=cmux`;
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
    const pageStart = await page.evaluate(() => performance.now());
    if (WORK)
      await page.evaluate(() => {
        const w = window as unknown as { __work: number[]; __workOn: boolean };
        w.__work = [];
        w.__workOn = true;
        const step = () => {
          if (!w.__workOn) return;
          const start = performance.now();
          const channel = new MessageChannel();
          channel.port1.onmessage = () => {
            channel.port1.close();
            w.__work.push(performance.now() - start);
          };
          channel.port2.postMessage(0);
          requestAnimationFrame(step);
        };
        requestAnimationFrame(step);
      });
    const metricsBefore = await mainMetrics(cdp);
    const taskBefore = metricsBefore.TaskDuration ?? 0;
    const wallBefore = performance.now();
    await page.waitForTimeout(SECONDS * 1000);
    const metricsAfter = await mainMetrics(cdp);
    const taskAfter = metricsAfter.TaskDuration ?? 0;
    const wallMs = performance.now() - wallBefore;
    const work = WORK
      ? ((await page.evaluate(() => {
          const w = window as unknown as { __work: number[]; __workOn: boolean };
          w.__workOn = false;
          return w.__work;
        })) as number[])
      : [];
    const workQ = (p: number) => {
      if (work.length === 0) return null;
      const sorted = [...work].sort((a, b) => a - b);
      return Math.round(sorted[Math.max(0, Math.ceil(p * sorted.length) - 1)]! * 10) / 10;
    };
    if (PROFILE) printProfile(((await cdp.send("Profiler.stop")) as { profile: CpuProfile }).profile, "replay", wallMs);
    const pageEnd = await page.evaluate(() => performance.now());
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
      split: splitOf(metricsBefore, metricsAfter, wallMs),
      ...(WORK
        ? { frame_work_p50_ms: workQ(0.5), frame_work_p95_ms: workQ(0.95), frame_work_p99_ms: workQ(0.99) }
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
  } catch (error) {
    console.error(`replay-under-load: FAILED: ${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 1;
  }
}
