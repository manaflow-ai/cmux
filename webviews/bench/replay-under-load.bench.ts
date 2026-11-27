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
//   painter                 --painter ARM, who paints the viewport (bench-only A/B, support/viewportPainter.ts):
//                           react (the real pane, the default), dom-floor (a minimal main-thread page appending text
//                           nodes: the floor of any main-thread painter) or worker (the real pane plus an
//                           OffscreenCanvas painted from a dedicated Worker on its own socket and frame loop; frame_*
//                           are then the worker's frames and react_frame_p95_ms the pane's, in the same run)
//   bun bench/replay-under-load.bench.ts [--log FILE] [--rate 40] [--seconds 60] [--warm 5] [--out FILE] [--profile]
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
import { DOM_FLOOR_HTML, PAINTER_WORKER_JS, workerOverlay } from "./support/viewportPainter";

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
/// --trace FILE: a Chrome trace of the measured window (toplevel tasks, style, layout, paint, GC, compile) and the CPU
/// profile beside it, as {trace, profile} JSON, for scripts/measure/replay-attribution.py to attribute every main-thread
/// task over 8 ms to its owner. Tracing costs the page time of its own, so a traced run's busy % reads high.
const TRACE = flag("--trace");
const PAINTER = flag("--painter") ?? "react";
/// REPLAY_REACT_PROFILE=1 (or --react-profile): build the pane on React's profiling build and record, per commit, the
/// render time React reports and each component's self time, plus every long animation frame's scripts and the record
/// kinds sent in its window. The reading gains `react_profile`. Off by default: the profiling build costs time of its
/// own, so a profiled run's frame p95 is not the before/after number, only where the slow frames' time went.
const REACT_PROFILE = argv.includes("--react-profile") || process.env.REPLAY_REACT_PROFILE === "1";
/// A frame gap at least this long is a slow frame for the profile (two frames at 60 Hz read as 33.3 ms).
const SLOW_FRAME_MS = 25;
/// Fewer gaps than this in the window is no frame p95 (the goal's sensor holds the same floor, perf_sensor.py).
const MIN_FRAMES = 60;
/// frameTally.ts BUCKET_MS and BUCKETS: bucket i holds gaps in [i * 0.1, (i + 1) * 0.1) ms; BUCKETS holds 100 ms+.
const BUCKET_MS = 0.1;
const BUCKETS = 1000;
/// frameTally.ts FLUSH_MS, plus margin: the window's last gaps arrive at most this long after it closes.
const FLUSH_WAIT_MS = 6_000;
if (
  ![RATE, SECONDS, WARM].every((n) => Number.isFinite(n) && n > 0) ||
  !["react", "dom-floor", "worker"].includes(PAINTER)
) {
  console.error(
    "usage: bun bench/replay-under-load.bench.ts [--log FILE] [--rate 40] [--seconds 60] [--warm 5] [--out FILE] [--profile] [--trace FILE] [--painter react|dom-floor|worker] [--react-profile]",
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
  const p = params as {
    op?: unknown;
    bucketMs?: unknown;
    gaps?: unknown;
  } | null;
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
  painter: string;
  react_frame_p95_ms?: number | null;
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
  chromium: string;
  at: string;
  react_profile?: ReactProfile;
};

type Named = { name: string; ms: number; count: number };
type ReactProfile = {
  commits: number;
  commit_render_ms_p50: number | null;
  commit_render_ms_p95: number | null;
  commits_over_8ms: number;
  slow_frames: number;
  /** Self render time by component, over every commit in the window. */
  components_all: Named[];
  /** Self render time by component, in commits inside a slow frame (a gap of SLOW_FRAME_MS or more). */
  components_slow: Named[];
  /** Long animation frames' scripts, by invoker and source function, with their forced style and layout. */
  loaf_scripts: (Named & { forced_layout_ms: number })[];
  loaf: { count: number; ms: number; render_ms: number; style_layout_ms: number; script_ms: number };
  /** Record kinds the stand-in sent inside slow frames, against every frame. */
  kinds_slow: Named[];
  kinds_all: Named[];
  slowest: { at: number; gap_ms: number; render_ms: number; top: [string, number][]; kinds: string[] }[];
};

/// The page half of --react-profile: a DevTools hook React's profiling build reports each commit to, and observers for
/// frames and long animation frames. Runs before the pane's bundle (addInitScript), so React finds the hook.
function installReactProfiler() {
  type Fiber = {
    tag: number;
    type: unknown;
    child: Fiber | null;
    sibling: Fiber | null;
    alternate: Fiber | null;
    actualDuration?: number;
    actualStartTime?: number;
    memoizedProps: unknown;
  };
  const w = window as unknown as Record<string, unknown>;
  const commits: { at: number; render: number; top: [string, number][]; self: Record<string, number> }[] = [];
  const frames: number[] = [];
  const loaf: unknown[] = [];
  const nameOf = (f: Fiber): string | null => {
    const t = f.type as unknown;
    if (typeof t === "function") {
      const fn = t as { displayName?: string; name?: string };
      return fn.displayName || fn.name || "anonymous";
    }
    if (t && typeof t === "object") {
      const o = t as { displayName?: string; type?: unknown; render?: unknown };
      const inner = (o.type ?? o.render) as { displayName?: string; name?: string } | undefined;
      return o.displayName || inner?.displayName || inner?.name || null;
    }
    return null;
  };
  w.__REACT_DEVTOOLS_GLOBAL_HOOK__ = {
    supportsFiber: true,
    isDisabled: false,
    renderers: new Map(),
    inject() {
      return 1;
    },
    checkDCE() {},
    onScheduleFiberRoot() {},
    onPostCommitFiberRoot() {},
    onCommitFiberUnmount() {},
    onCommitFiberRoot(_id: number, root: { current: Fiber }) {
      const host = root.current;
      const start = host.actualStartTime ?? 0;
      const render = host.actualDuration ?? 0;
      const self: Record<string, number> = {};
      // A fiber rendered in this commit when its start time is this commit's; a bailed-out one keeps an older start.
      const stack: Fiber[] = host.child ? [host.child] : [];
      while (stack.length) {
        const f = stack.pop()!;
        if (f.sibling) stack.push(f.sibling);
        const rendered = (f.actualStartTime ?? -1) >= start;
        if (!rendered) continue;
        let kids = 0;
        for (let c = f.child; c; c = c.sibling) if ((c.actualStartTime ?? -1) >= start) kids += c.actualDuration ?? 0;
        const own = Math.max(0, (f.actualDuration ?? 0) - kids);
        const name = nameOf(f);
        if (name && own > 0) self[name] = (self[name] ?? 0) + own;
        else if (!name && own > 0) self["(host elements)"] = (self["(host elements)"] ?? 0) + own;
        if (f.child) stack.push(f.child);
      }
      const top = Object.entries(self)
        .sort((a, b) => b[1] - a[1])
        .slice(0, 8)
        .map(([n, ms]) => [n, Math.round(ms * 100) / 100] as [string, number]);
      commits.push({ at: performance.now(), render, top, self });
    },
  };
  const tick = (t: number) => {
    frames.push(t);
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
  try {
    new PerformanceObserver((list) => {
      for (const e of list.getEntries()) loaf.push((e as unknown as { toJSON(): unknown }).toJSON());
    }).observe({ type: "long-animation-frame", buffered: true });
  } catch {
    // No long-animation-frame in this Chromium: the commits still count.
  }
  w.__reactProfile = { commits, frames, loaf, origin: performance.timeOrigin };
}

/** Folds the page's commits, frames and long animation frames, and the stand-in's sends, into a ReactProfile (pure). */
export function summarizeReactProfile(
  raw: {
    commits: { at: number; render: number; top: [string, number][]; self: Record<string, number> }[];
    frames: number[];
    loaf: {
      startTime: number;
      duration: number;
      renderStart: number;
      styleAndLayoutStart: number;
      scripts?: {
        invoker?: string;
        sourceFunctionName?: string;
        duration: number;
        forcedStyleAndLayoutDuration?: number;
      }[];
    }[];
    origin: number;
  },
  sends: { wall: number; kind: string }[],
  from: number,
  to: number,
): ReactProfile {
  const r2 = (x: number) => Math.round(x * 10) / 10;
  const commits = raw.commits.filter((c) => c.at >= from && c.at <= to);
  const frames = raw.frames.filter((t) => t >= from && t <= to);
  const slow: [number, number][] = [];
  for (let i = 1; i < frames.length; i++)
    if (frames[i]! - frames[i - 1]! >= SLOW_FRAME_MS) slow.push([frames[i - 1]!, frames[i]!]);
  const inSlow = (t: number) => slow.find(([a, b]) => t > a && t <= b);
  const add = (into: Map<string, Named>, name: string, ms: number) => {
    const row = into.get(name) ?? { name, ms: 0, count: 0 };
    row.ms += ms;
    row.count += 1;
    into.set(name, row);
  };
  const all = new Map<string, Named>();
  const slowC = new Map<string, Named>();
  for (const c of commits)
    for (const [name, ms] of Object.entries(c.self)) {
      add(all, name, ms);
      if (inSlow(c.at)) add(slowC, name, ms);
    }
  const pageSends = sends
    .map((s) => ({ at: s.wall - raw.origin, kind: s.kind }))
    .filter((s) => s.at >= from && s.at <= to);
  const kindsAll = new Map<string, Named>();
  const kindsSlow = new Map<string, Named>();
  for (const s of pageSends) {
    add(kindsAll, s.kind, 0);
    if (inSlow(s.at)) add(kindsSlow, s.kind, 0);
  }
  const scripts = new Map<string, Named & { forced_layout_ms: number }>();
  const loafs = raw.loaf.filter((l) => l.startTime >= from && l.startTime <= to);
  let loafMs = 0,
    renderMs = 0,
    styleMs = 0,
    scriptMs = 0;
  for (const l of loafs) {
    loafMs += l.duration;
    const end = l.startTime + l.duration;
    if (l.renderStart > 0) renderMs += end - l.renderStart;
    if (l.styleAndLayoutStart > 0) styleMs += end - l.styleAndLayoutStart;
    for (const s of l.scripts ?? []) {
      scriptMs += s.duration;
      const name = `${s.invoker ?? "?"} :: ${s.sourceFunctionName || "?"}`;
      const row = scripts.get(name) ?? { name, ms: 0, count: 0, forced_layout_ms: 0 };
      row.ms += s.duration;
      row.count += 1;
      row.forced_layout_ms += s.forcedStyleAndLayoutDuration ?? 0;
      scripts.set(name, row);
    }
  }
  const sorted = <T extends Named>(m: Map<string, T>, n = 15) =>
    [...m.values()]
      .sort((a, b) => b.ms - a.ms || b.count - a.count)
      .slice(0, n)
      .map((row) => ({
        ...row,
        ms: r2(row.ms),
        ...("forced_layout_ms" in row
          ? { forced_layout_ms: r2((row as { forced_layout_ms: number }).forced_layout_ms) }
          : {}),
      }));
  const renders = commits.map((c) => c.render).sort((a, b) => a - b);
  const q = (p: number) =>
    renders.length ? r2(renders[Math.min(renders.length - 1, Math.ceil(p * renders.length) - 1)]!) : null;
  const slowest = slow
    .map(([a, b]) => {
      const inside = commits.filter((c) => c.at > a && c.at <= b);
      const top = new Map<string, number>();
      for (const c of inside) for (const [n, ms] of c.top) top.set(n, (top.get(n) ?? 0) + ms);
      return {
        at: r2(b),
        gap_ms: r2(b - a),
        render_ms: r2(inside.reduce((s, c) => s + c.render, 0)),
        top: [...top.entries()]
          .sort((x, y) => y[1] - x[1])
          .slice(0, 6)
          .map(([n, ms]) => [n, r2(ms)] as [string, number]),
        kinds: pageSends.filter((s) => s.at > a && s.at <= b).map((s) => s.kind),
      };
    })
    .sort((x, y) => y.gap_ms - x.gap_ms)
    .slice(0, 12);
  return {
    commits: commits.length,
    commit_render_ms_p50: q(0.5),
    commit_render_ms_p95: q(0.95),
    commits_over_8ms: renders.filter((x) => x >= 8).length,
    slow_frames: slow.length,
    components_all: sorted(all),
    components_slow: sorted(slowC),
    loaf_scripts: sorted(scripts) as (Named & { forced_layout_ms: number })[],
    loaf: {
      count: loafs.length,
      ms: r2(loafMs),
      render_ms: r2(renderMs),
      style_layout_ms: r2(styleMs),
      script_ms: r2(scriptMs),
    },
    kinds_slow: sorted(kindsSlow, 20),
    kinds_all: sorted(kindsAll, 20),
    slowest,
  };
}

async function taskSeconds(cdp: CDPSession): Promise<number> {
  const { metrics } = (await cdp.send("Performance.getMetrics")) as {
    metrics: { name: string; value: number }[];
  };
  return metrics.find((m) => m.name === "TaskDuration")?.value ?? 0;
}

async function run(): Promise<Reading> {
  const log: ReplayLog = parseLog(path.basename(LOG_FILE), fs.readFileSync(LOG_FILE, "utf8"));
  const releases: (() => unknown)[] = [];
  try {
    // ---------- the stand-in acpmux: serves the session, keeps the frame tally the page sends ----------
    let served = 0;
    let status = "running";
    // Every attached socket gets the records: the worker arm's painter attaches beside the pane.
    const sockets = new Set<{ send(data: string): void }>();
    let measuring = false;
    const counts = new Map<number, number>();
    /// The pane's own tally in the worker arm (frame_* there are the worker's).
    const paneCounts = new Map<number, number>();
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
          return {
            protocolVersion: 1,
            _meta: {
              acpmux: { origin: "local", extensions: [], operations: [] },
            },
          };
        case "_acpmux/watch":
          return { sessions: [summary()] };
        case "_acpmux/attach":
          return {
            session: summary(),
            lastSeq: log.events[served - 1]?.seq ?? 0,
            events: log.events.slice(0, served),
          };
        case "_acpmux/events":
          return {
            events: [],
            hasMore: false,
            lastSeq: log.events[served - 1]?.seq ?? 0,
          };
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
          const message = JSON.parse(String(raw)) as {
            id?: number;
            method: string;
            params?: unknown;
          };
          if (message.method === "_acpmux/attach") sockets.add(ws);
          if (message.method === "_acpmux/perf" && measuring) {
            // The arm's painter counts as the reading; a tally without `painter` is the pane's.
            const by = (message.params as { painter?: string } | null)?.painter ?? "react";
            if (by === PAINTER) addTally(counts, message.params);
            else if (by === "react") addTally(paneCounts, message.params);
          }
          if (message.id !== undefined)
            ws.send(
              JSON.stringify({
                jsonrpc: "2.0",
                id: message.id,
                result: answer(message.method),
              }),
            );
        },
      },
    });
    releases.push(() => daemon.stop(true));
    const sends: { wall: number; kind: string }[] = [];
    const emit = (event: EventRecord) => {
      if (REACT_PROFILE && measuring)
        sends.push({ wall: Date.now(), kind: String((event as { kind?: unknown }).kind ?? "?") });
      const text = JSON.stringify({
        jsonrpc: "2.0",
        method: "_acpmux/event",
        params: event,
      });
      for (const ws of sockets) ws.send(text);
    };

    // ---------- the pane, built as production React ----------
    const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "replay-under-load-"));
    releases.push(() => fs.rmSync(out, { recursive: true, force: true }));
    const { build } = await import("vite");
    if (PAINTER !== "dom-floor")
      await build({
        configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
        build: {
          outDir: out,
          emptyOutDir: true,
          ...(PROFILE || TRACE || REACT_PROFILE ? { minify: false } : {}),
        },
        // React's profiling build fills each fiber's actualDuration, which the commit hook reads.
        ...(REACT_PROFILE ? { resolve: { alias: { "react-dom/client": "react-dom/profiling" } } } : {}),
        logLevel: "error",
      });
    const statics = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      async fetch(request) {
        const pathname = new URL(request.url).pathname;
        if (pathname === "/__painter-worker.js")
          return new Response(PAINTER_WORKER_JS, {
            headers: { "content-type": "text/javascript" },
          });
        if (pathname === "/__painter-dom.html")
          return new Response(DOM_FLOOR_HTML, {
            headers: { "content-type": "text/html" },
          });
        const file = Bun.file(path.join(out, pathname === "/" ? "index.html" : pathname));
        return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
      },
    });
    releases.push(() => statics.stop(true));
    const browser = await chromium.launch({ headless: true });
    releases.push(() => browser.close());
    const page = await browser.newPage({
      viewport: { width: 900, height: 700 },
    });
    await page.addInitScript(() => {
      const w = window as unknown as { __long: { at: number; ms: number }[] };
      w.__long = [];
      new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) w.__long.push({ at: entry.startTime, ms: entry.duration });
      }).observe({ type: "longtask", buffered: true });
    });
    if (REACT_PROFILE) await page.addInitScript(installReactProfiler);
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Performance.enable");
    if (PROFILE || TRACE) {
      await cdp.send("Profiler.enable");
      await cdp.send("Profiler.setSamplingInterval", { interval: 200 });
      await cdp.send("Profiler.start");
    }
    const endpoint = `ws://127.0.0.1:${daemon.port}/`;
    if (PAINTER === "worker")
      await page.addInitScript(workerOverlay, {
        endpoint,
        session: log.sessionId,
      });
    const url =
      `http://127.0.0.1:${statics.port}/${PAINTER === "dom-floor" ? "__painter-dom.html" : ""}#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}` +
      `&token=t&session=${encodeURIComponent(log.sessionId)}` +
      // A shipped build's scheme, as Leo's NIGHTLY names: the dev host's default `cmux-dev` turns on the dev-only
      // layout-motion audit (devMotionAudit.ts), which sampled every box each frame and was ~8% of this reading.
      `&scheme=cmux`;
    const consoleTail: string[] = [];
    page.on("console", (m) => consoleTail.push(`${m.type()}: ${m.text()}`.slice(0, 300)));
    page.on("pageerror", (e) => consoleTail.push(`pageerror: ${e.message}`.slice(0, 300)));
    await page.goto(url);
    try {
      await page.locator(PAINTER === "dom-floor" ? "#painter" : ".acpmux-scroll").waitFor({ timeout: 120_000 });
    } catch (error) {
      const body = (await page.evaluate(() => document.body?.innerText ?? "")).slice(0, 400);
      throw new Error(
        `the pane never drew its transcript: ${String(error).split("\n")[0]}; page: ${JSON.stringify(body)}; console: ${consoleTail.slice(-8).join(" | ")}`,
      );
    }
    const want = PAINTER === "worker" ? 2 : 1;
    for (let tries = 0; sockets.size < want && tries < 600; tries++) await page.waitForTimeout(50);
    if (sockets.size < want) throw new Error(`${log.name}: the pane never attached`);

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
    if (TRACE)
      await browser.startTracing(page, {
        categories: [
          "toplevel",
          "devtools.timeline",
          "disabled-by-default-devtools.timeline",
          "v8",
          "v8.execute",
          "blink.user_timing",
          "disabled-by-default-v8.gc",
        ],
      });
    const pageStart = await page.evaluate(() => performance.now());
    const taskBefore = await taskSeconds(cdp);
    const wallBefore = performance.now();
    await page.waitForTimeout(SECONDS * 1000);
    const taskAfter = await taskSeconds(cdp);
    const wallMs = performance.now() - wallBefore;
    if (PROFILE || TRACE) {
      const profile = ((await cdp.send("Profiler.stop")) as { profile: CpuProfile }).profile;
      if (PROFILE) printProfile(profile, "replay", wallMs);
      if (TRACE) {
        // The trace's bytes go to the file as they came (no parse and re-stringify: a minute's trace is hundreds of
        // MB), after the profile, so replay-attribution.py reads the profile first and streams the trace's events.
        const fd = fs.openSync(TRACE, "w");
        fs.writeSync(fd, `{"profile":${JSON.stringify(profile)},"trace":`);
        fs.writeSync(fd, await browser.stopTracing());
        fs.writeSync(fd, "}");
        fs.closeSync(fd);
      }
    }
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
    const reactProfile = REACT_PROFILE
      ? summarizeReactProfile(
          (await page.evaluate(() => (window as unknown as { __reactProfile: unknown }).__reactProfile)) as Parameters<
            typeof summarizeReactProfile
          >[0],
          sends,
          pageStart,
          pageEnd,
        )
      : undefined;
    const frames = [...counts.values()].reduce((sum, n) => sum + n, 0);
    const over50 = [...counts.entries()].reduce((sum, [index, n]) => sum + (index * BUCKET_MS >= 50 ? n : 0), 0);
    const enough = frames >= MIN_FRAMES;
    return {
      schema: "replay-under-load/v1",
      scenario: `replay ${log.name} at ${RATE} records/s, ${SECONDS} s window${PAINTER === "react" ? "" : `, painter ${PAINTER}`}`,
      log: log.name,
      log_records: log.events.length,
      rate: RATE,
      seconds: SECONDS,
      records: sent,
      painter: PAINTER,
      ...(PAINTER === "worker" ? { react_frame_p95_ms: quantile(paneCounts, 0.95) } : {}),
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
      chromium: browser.version(),
      at: new Date().toISOString().replace(/\.\d+Z$/, "Z"),
      ...(reactProfile ? { react_profile: reactProfile } : {}),
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
    // One line with the cause: a vite build error's message starts "Build failed with 1 error:" and names the file
    // and the Babel error only on the lines after it, and the sensor keeps a log's tail, which is stack frames.
    const message = error instanceof Error ? error.message : String(error);
    const cause = message
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean)
      .slice(0, 3)
      .join(" | ");
    console.error(`replay-under-load: FAILED: ${cause.slice(0, 500)}`);
    if (message.includes("\n")) console.error(message);
    process.exitCode = 1;
  }
}
