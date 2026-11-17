// l10n-allow-file: benchmark output, not shipped UI.
// What one keystroke in the composer costs in the god chat while a reply streams, against the small chat under the
// same stream (CMUX-571; Leo, 2026-11-12: a god chat shows "no perceivable difference", within 1.2x). The typing
// goal (composer-typing.bench.ts, key to frame) was read only on a light seeded chat; this reads it on the god session
// (godFixture.ts, ~34,600 rows) and its small twin (godLog("small")), each attached whole through its own stand-in
// acpmux (transcript-replay.bench.ts's), both in one browser, as the pane ships (a vite build).
// Each round types KEYS letters into each page's composer (Playwright key events GAP ms apart) while that page's
// daemon streams a reply into it: a reply token every 16 ms (one record a frame, the replay's burst rate), from a
// turn started for the segment and ended after it. The sides alternate (god first on odd rounds, small first on
// even), seconds apart, so a slow minute of a shared runner lands on both. Per key, from the page's own
// typingStats (perf.ts: keydown's event time to the next frame's start, as the Mac bench reads it): p50 and p95.
// A segment's p95 of 40+ keys is one round's number; the verdict is the median over rounds of each round's
// god / small ratio with a seeded bootstrap 95% interval, as god-ratio-ab.sh reads its rounds. Rounds run until the
// p50 and p95 ratio intervals are both narrower than --width (0.05) or --max-rounds.
// Key to frame is a latency, so it is read on the wall clock; with CLOCK=cpu each segment also reads the main
// thread's CPU ms per second (threadTicks) while it types and streams: the load each page carries.
// --profile: a CPU profile of every typing window, summed over rounds, printed per key for each side, then the
// functions that cost god more per key than small (where O(transcript) work on the key path would show).
//   bun bench/god-typing.bench.ts [--keys 40] [--gap 80] [--rounds 12] [--max-rounds 60] [--width 0.05] [--profile]
//   cmux-ci test --setup playwright -- bash -c 'cd webviews && CLOCK=cpu bun bench/god-typing.bench.ts'
/// <reference types="bun" />
import path from "node:path";
import fs from "node:fs";
import os from "node:os";
import type { CDPSession, Page } from "playwright";
import type { EventRecord } from "../src/agent-session/acpmux/direct";
import { installPaintedFrames } from "../test/support/paintedFrames";
import { chromium } from "./browsers";
import { godLog, LATEST_TEXT } from "./godFixture";
import { checkSeq, rowsIn, tokens, toRecord, type ReplayLog } from "./replayLogs";
import { cpuSession } from "./stability";
import { answer, emit, rest, selfTimes, totalTimes, type Daemon, type Play } from "./transcript-replay.bench";

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : undefined;
};
const KEYS = Number(flag("--keys") ?? 40);
const GAP_MS = Number(flag("--gap") ?? 80);
const MIN_ROUNDS = Number(flag("--rounds") ?? 12);
const MAX_ROUNDS = Number(flag("--max-rounds") ?? 60);
const WIDTH = Number(flag("--width") ?? 0.05);
const PROFILE = argv.includes("--profile");
const CPU_CLOCK = process.env.CLOCK === "cpu";
/// A reply token every this many ms while the keys are typed: one record a frame, as the replay plays a burst.
const TOKEN_MS = 16;
const PROMPT = ".acpmux-composer-prompt[contenteditable='true'], .acpmux-composer-prompt [contenteditable='true']";
const webviews = path.resolve(import.meta.dir, "..");

type Segment = { p50: number; p95: number; max: number; keys: number; cpuMsPerS?: number; tokens: number };
type Side = {
  name: "god" | "small";
  log: ReplayLog;
  play: Play;
  page: Page;
  cpu: CDPSession | null;
  cdp: CDPSession;
  rows: number;
  segments: Segment[];
  self: Map<string, number>;
  total: Map<string, number>;
  keysProfiled: number;
};

/// The median of `values` (pure).
export function median(values: readonly number[]): number {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = sorted.length >> 1;
  return sorted.length % 2 ? sorted[mid]! : (sorted[mid - 1]! + sorted[mid]!) / 2;
}

/// The median's 95% interval: a seeded bootstrap over the rounds (pure; mulberry32, as god-ratio-ab.sh seeds its own).
export function medianInterval(values: readonly number[], draws = 4000): [number, number] {
  let a = 1;
  const random = () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  const meds: number[] = [];
  for (let draw = 0; draw < draws; draw++)
    meds.push(median(values.map(() => values[Math.floor(random() * values.length)]!)));
  meds.sort((x, y) => x - y);
  return [meds[Math.floor(draws * 0.025)]!, meds[Math.floor(draws * 0.975)]!];
}

const round3 = (value: number) => Math.round(value * 1000) / 1000;

async function threadMs(cdp: CDPSession | null): Promise<number> {
  if (!cdp) return 0;
  const { metrics } = (await cdp.send("Performance.getMetrics")) as { metrics: { name: string; value: number }[] };
  return (metrics.find((each) => each.name === "ThreadTime")?.value ?? 0) * 1000;
}

/// The page of one side: its log attached whole (status running), the chat drawn to its newest reply, the composer
/// focused and warmed (its lazy parts loaded).
async function openSide(
  browser: Awaited<ReturnType<typeof chromium.launch>>,
  daemon: Daemon,
  statics: number,
  name: Side["name"],
  log: ReplayLog,
): Promise<Side> {
  const play: Play = { log, served: log.events.length, status: "running" };
  daemon.play = play;
  const page = await browser.newPage({ viewport: { width: 1100, height: 820 } });
  await installPaintedFrames(page);
  const url =
    `http://127.0.0.1:${statics}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}` +
    `&token=t&session=${encodeURIComponent(log.sessionId)}`;
  const opened = performance.now();
  await page.goto(url);
  await page.getByText(LATEST_TEXT).first().waitFor({ timeout: 300_000 });
  await page.locator(PROMPT).first().waitFor({ timeout: 60_000 });
  await rest(page);
  console.log(
    `god-typing: ${name} (${log.events.length} records, ${rowsIn(log.events)} rows) drawn in ` +
      `${((performance.now() - opened) / 1000).toFixed(1)} s`,
  );
  const cdp = await page.context().newCDPSession(page);
  if (PROFILE) await cdp.send("Profiler.enable");
  const cpu = CPU_CLOCK ? await cpuSession(page, true) : null;
  await page.locator(PROMPT).first().click();
  for (const key of "warm") await page.keyboard.press(key);
  await page.waitForTimeout(500);
  for (let i = 0; i < 4; i += 1) await page.keyboard.press("Backspace");
  await page.waitForTimeout(500);
  return {
    name,
    log,
    play,
    page,
    cdp,
    cpu,
    rows: rowsIn(log.events),
    segments: [],
    self: new Map(),
    total: new Map(),
    keysProfiled: 0,
  };
}

/// A record appended to the side's log and sent live, as acpmux sends a new event.
function stream(side: Side, step: Parameters<typeof toRecord>[3]) {
  const record: EventRecord = toRecord(side.log.sessionId, side.log.events.length + 1, Date.now(), step);
  side.log.events.push(record);
  side.play.served = record.seq;
  emit(side.play, record);
}

/// One round's segment on one side: a turn starts and streams a token a frame while KEYS keys are typed, then ends.
async function segment(side: Side, round: number): Promise<Segment> {
  const { page } = side;
  stream(side, { mux: "user_message", msg: { text: `Round ${round}: keep going` } });
  stream(side, { mux: "turn_started" });
  const words = tokens(round, 400);
  let sent = 0;
  const timer = setInterval(() => stream(side, { update: textChunk(words[sent++ % words.length]!) }), TOKEN_MS);
  try {
    // The stream under way before the first key (its first rows drawn).
    await page.waitForTimeout(300);
    await page.evaluate(() => (window as any).cmuxAcpmuxDebug.resetTyping());
    if (PROFILE) {
      await side.cdp.send("Profiler.setSamplingInterval", { interval: 100 });
      await side.cdp.send("Profiler.start");
    }
    const cpuBefore = await threadMs(side.cpu);
    const startedAt = performance.now();
    const letters = "abcdefghijklmnopqrstuvwxyz";
    for (let i = 0; i < KEYS; i += 1) {
      await page.keyboard.press(letters[(i + round) % letters.length]!);
      await page.waitForTimeout(GAP_MS);
    }
    const seconds = (performance.now() - startedAt) / 1000;
    const cpuMs = (await threadMs(side.cpu)) - cpuBefore;
    if (PROFILE) {
      const { profile } = (await side.cdp.send("Profiler.stop")) as { profile: Parameters<typeof selfTimes>[0] };
      for (const [map, times] of [
        [side.self, selfTimes(profile, 1)],
        [side.total, totalTimes(profile, 1)],
      ] as const)
        for (const [fn, ms] of times) map.set(fn, (map.get(fn) ?? 0) + ms);
      side.keysProfiled += KEYS;
    }
    const typing = (await page.evaluate(() => (window as any).cmuxAcpmuxDebug.typingStats())) as {
      keys: number;
      to_frame?: { p50_ms?: number; p95_ms?: number; max_ms?: number };
    };
    if (!typing.to_frame || typing.keys < KEYS * 0.9)
      throw new Error(`${side.name}: the page counted ${typing.keys} of ${KEYS} keys`);
    return {
      keys: typing.keys,
      p50: typing.to_frame.p50_ms ?? NaN,
      p95: typing.to_frame.p95_ms ?? NaN,
      max: typing.to_frame.max_ms ?? NaN,
      tokens: sent,
      ...(side.cpu ? { cpuMsPerS: Math.round((cpuMs / seconds) * 10) / 10 } : {}),
    };
  } finally {
    clearInterval(timer);
    stream(side, { mux: "turn_result", msg: { status: "completed" } });
    // The prompt emptied for the next round: what it held is not what the next keys measure.
    await page.keyboard.press("ControlOrMeta+a");
    await page.keyboard.press("Backspace");
    await page.waitForTimeout(400);
  }
}

const textChunk = (value: string) => ({
  sessionUpdate: "agent_message_chunk",
  content: { type: "text", text: value },
});

type Verdict = { stat: "p50" | "p95"; ratio: number; lo: number; hi: number; small: number; god: number };
/// Per stat, the median over rounds of god / small, its interval, and each side's median ms (pure).
export function verdict(god: readonly Segment[], small: readonly Segment[]): Verdict[] {
  return (["p50", "p95"] as const).map((stat) => {
    const ratios = god.map((segment, index) => segment[stat] / small[index]![stat]);
    const [lo, hi] = medianInterval(ratios);
    return {
      stat,
      ratio: round3(median(ratios)),
      lo: round3(lo),
      hi: round3(hi),
      small: round3(median(small.map((each) => each[stat]))),
      god: round3(median(god.map((each) => each[stat]))),
    };
  });
}

if (import.meta.main) {
  const releases: (() => unknown)[] = [];
  try {
    const god = godLog("god");
    const small = godLog("small");
    for (const log of [god, small]) checkSeq(log);
    const daemons: Daemon[] = [0, 1].map(() => {
      const daemon: Daemon = { port: 0 };
      const server = Bun.serve({
        port: 0,
        hostname: "127.0.0.1",
        fetch(request, server) {
          return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
        },
        websocket: {
          message(ws, raw) {
            const message = JSON.parse(String(raw)) as { id?: number; method: string };
            const p = daemon.play;
            if (message.method === "_acpmux/attach" && p) p.socket = ws;
            if (message.id !== undefined)
              ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: p ? answer(p, message.method) : null }));
          },
        },
      });
      daemon.port = server.port ?? 0;
      releases.push(() => server.stop(true));
      return daemon;
    });
    const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "god-typing-bench-"));
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
    // Each page asks the React it loaded: the production build, never the development bundle.
    const sides = [
      await openSide(browser, daemons[0]!, statics.port!, "god", god),
      await openSide(browser, daemons[1]!, statics.port!, "small", small),
    ] as const;
    let verdicts: Verdict[] = [];
    for (let round = 1; round <= MAX_ROUNDS; round++) {
      const order = round % 2 ? sides : ([sides[1], sides[0]] as const);
      for (const side of order) {
        await side.page.bringToFront();
        await side.page.locator(PROMPT).first().focus();
        side.segments.push(await segment(side, round));
      }
      const [g, s] = [sides[0].segments.at(-1)!, sides[1].segments.at(-1)!];
      console.log(
        `  round ${round}: god p50 ${g.p50} p95 ${g.p95} max ${g.max} | small p50 ${s.p50} p95 ${s.p95} max ${s.max}` +
          (g.cpuMsPerS !== undefined ? ` | cpu ms/s god ${g.cpuMsPerS} small ${s.cpuMsPerS}` : "") +
          ` | tokens ${g.tokens}/${s.tokens}`,
      );
      if (round < MIN_ROUNDS) continue;
      verdicts = verdict(sides[0].segments, sides[1].segments);
      if (verdicts.every((each) => each.hi - each.lo < WIDTH)) break;
    }
    const rounds = sides[0].segments.length;
    console.log(
      `god-typing: ${rounds} rounds, ${KEYS} keys a side a round, ${GAP_MS} ms apart, a reply token every ${TOKEN_MS} ms; ` +
        `god ${sides[0].rows} rows, small ${sides[1].rows} rows; key to frame, ms (median over rounds) and the median ` +
        `over rounds of god / small with its 95% interval`,
    );
    for (const each of verdicts)
      console.log(
        `  key_to_frame ${each.stat}: small ${each.small} ms god ${each.god} ms ratio ${each.ratio} ` +
          `[${each.lo}, ${each.hi}] width ${round3(each.hi - each.lo)}`,
      );
    if (CPU_CLOCK) {
      const cpu = (side: Side) => round3(median(side.segments.map((each) => each.cpuMsPerS ?? 0)));
      console.log(`  main-thread cpu ms/s while typing and streaming: small ${cpu(sides[1])} god ${cpu(sides[0])}`);
    }
    console.log(
      `GOD-TYPING ${JSON.stringify({ rounds, keys: KEYS, gap_ms: GAP_MS, verdicts, sides: sides.map((side) => ({ name: side.name, rows: side.rows, segments: side.segments })) })}`,
    );
    if (PROFILE) {
      const top = (map: Map<string, number>, keys: number, count: number) =>
        [...map.entries()]
          .sort((a, b) => b[1] - a[1])
          .slice(0, count)
          .map(([fn, ms]) => `    ${(ms / keys).toFixed(3)} ms/key  ${fn}`)
          .join("\n");
      for (const side of sides) {
        console.log(`PROFILE ${side.name} self, per key (stream included):\n${top(side.self, side.keysProfiled, 30)}`);
        console.log(
          `PROFILE ${side.name} total, per key (stream included):\n${top(side.total, side.keysProfiled, 40)}`,
        );
      }
      const [g, s] = sides;
      const grew = (kind: "self" | "total") =>
        [...g[kind].entries()]
          .map(([fn, ms]) => [fn, s[kind].get(fn) ?? 0, ms] as const)
          .map(([fn, a, b]) => [fn, a / s.keysProfiled, b / g.keysProfiled] as const)
          .sort((x, y) => y[2] - y[1] - (x[2] - x[1]))
          .slice(0, 25)
          .map(([fn, a, b]) => `    ${a.toFixed(3)} -> ${b.toFixed(3)} ms/key  ${fn}`)
          .join("\n");
      console.log(`PROFILE god over small, self ms per key (small -> god):\n${grew("self")}`);
      console.log(`PROFILE god over small, total ms per key (small -> god):\n${grew("total")}`);
    }
  } finally {
    for (const release of releases.reverse()) {
      try {
        await release();
      } catch {
        // Release the rest.
      }
    }
  }
}
