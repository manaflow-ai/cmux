// l10n-allow-file: bench fixture prompts and replies, not shipped UI.
// Opening a chat, stage by stage: the production pane (a vite build of the pane's dev entry) joins a
// stand-in acpmux that holds a TURNS-turn chat, as test/support/papercutChat.ts does. Each round is a
// cold page load (a fresh browser context: no HTTP or compiled-code cache), so what comes before
// `attach` is a first launch's cost, and the stages after it are what a chat switch shares. Each round
// records, from navigation start (performance.now()):
//   attach     the stand-in answered `_acpmux/attach` (the history left the daemon);
//   firstRow   the first transcript row painted;
//   latest     the newest message ("Answer N:") painted;
//   settled    nothing moved for 400 ms after that: no long task or layout shift, and the scroller's
//              position and height unchanged.
// The stages that follow `attach` are the page's own: parse, first render and layout passes.
// Long tasks (count, total) and the layout-shift sum cover the whole load; the transcript's scroll drift
// after `latest` says how much the page still moved after the newest messages appeared.
//   bun bench/chat-open.bench.ts [rounds=7] [turns=300]
// PROFILE=1 adds a CPU profile of one load and prints the functions with the most self time between
// navigation and the newest message plus 500 ms. The build is then unminified (so functions keep their
// names) and every timed round runs on it, so the stage times are not the production build's.
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium } from "playwright";
import { PAPERCUT_CHAT, papercutEvents } from "../test/support/papercutChat";

const ROUNDS = Number(process.argv[2] ?? 7);
const TURNS = Number(process.argv[3] ?? 300);
const webviews = path.resolve(import.meta.dir, "..");
const LATEST = `Answer ${TURNS}:`;

const { events, session } = papercutEvents({ turns: TURNS, running: false });
let attachedAt = 0;
let attachBytes = 0;
let attachEvents = 0;
/// When each protocol call first reached the stand-in in this load (epoch ms).
let arrivals = new Map<string, number>();
let socketOpenedAt = 0;
/// The newest `limit` events before `beforeSeq`, oldest first, and whether older ones remain: the page the
/// daemon answers an attach or an older-history read with.
const newest = (limit: number, beforeSeq = Infinity) => {
  const older = events.filter((event) => event.seq < beforeSeq);
  return { page: older.slice(-limit), hasMore: older.length > limit };
};
const answer = (method: string, params: Record<string, unknown> = {}): unknown => {
  switch (method) {
    case "initialize":
      return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    case "_acpmux/watch":
      return { sessions: [session] };
    case "_acpmux/attach": {
      // As the daemon does: the newest `limit` events, and hasMore while older ones remain.
      const { page, hasMore } = newest(Number(params.limit ?? 400));
      const result = { session, lastSeq: events.at(-1)?.seq ?? 0, events: page, hasMore };
      attachBytes = JSON.stringify(result).length;
      attachEvents = page.length;
      return result;
    }
    case "_acpmux/events": {
      // The prompt index (hub/paging.rs prompt_index): every prompt before `beforeSeq`, each cut to its
      // text, in one reply.
      if (params.promptIndex === true) {
        const before = params.beforeSeq === undefined ? Infinity : Number(params.beforeSeq);
        const prompts = events
          .filter((event) => event.kind === "user_message" && event.seq < before)
          .map((event) => ({ ...event, msg: { text: String((event.msg as { text?: string }).text ?? "") } }));
        return { events: prompts, hasMore: false, lastSeq: events.at(-1)?.seq ?? 0 };
      }
      if (params.beforeSeq !== undefined) {
        const { page, hasMore } = newest(Number(params.limit ?? 400), Number(params.beforeSeq));
        return { events: page, hasMore, lastSeq: events.at(-1)?.seq ?? 0 };
      }
      return { events: [], hasMore: false, lastSeq: events.at(-1)?.seq ?? 0 };
    }
    default:
      return null;
  }
};

/// A bundle position back to its source file and line, from the build's source map (a VLQ decode, so
/// the bench needs no source-map package).
function sourceMapper(dir: string) {
  const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  type Mapped = { sources: string[]; lines: number[][][] };
  const cache = new Map<string, Mapped | null>();
  function load(file: string): Mapped | null {
    const mapFile = path.join(dir, "assets", `${file}.map`);
    if (!fs.existsSync(mapFile)) return null;
    const raw = JSON.parse(fs.readFileSync(mapFile, "utf8")) as { sources: string[]; mappings: string };
    let source = 0;
    let line = 0;
    let column = 0;
    const lines = raw.mappings.split(";").map((segment) => {
      let generated = 0;
      return segment
        .split(",")
        .filter(Boolean)
        .map((part) => {
          const values: number[] = [];
          let shift = 0;
          let value = 0;
          for (const char of part) {
            const digit = B64.indexOf(char);
            value += (digit & 31) << shift;
            if (digit & 32) shift += 5;
            else {
              values.push(value & 1 ? -(value >> 1) : value >> 1);
              value = 0;
              shift = 0;
            }
          }
          generated += values[0]!;
          if (values.length > 1) {
            source += values[1]!;
            line += values[2]!;
            column += values[3]!;
          }
          return [generated, source, line, column];
        });
    });
    return { sources: raw.sources, lines };
  }
  return (file: string, lineNumber: number, columnNumber: number): string => {
    if (!cache.has(file)) cache.set(file, load(file));
    const map = cache.get(file);
    const segments = map?.lines[lineNumber];
    if (!map || !segments?.length) return `${file}:${lineNumber + 1}`;
    let best = segments[0]!;
    for (const segment of segments) if (segment[0]! <= columnNumber) best = segment;
    return `${map.sources[best[1]!]?.replace(/^(\.\.\/)+/, "")}:${best[2]! + 1}`;
  };
}
const releases: [string, () => unknown][] = [];
const release = async () => {
  for (const [, stop] of releases.reverse()) await Promise.resolve(stop()).catch(() => undefined);
};

try {
  const daemon = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch(request, server) {
      return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
    },
    websocket: {
      open() {
        socketOpenedAt ||= Date.now();
      },
      message(ws, raw) {
        const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, unknown> };
        if (!arrivals.has(message.method)) arrivals.set(message.method, Date.now());
        if (message.id === undefined) return;
        const result = answer(message.method, (message as { params?: Record<string, unknown> }).params);
        if (message.method === "_acpmux/attach") attachedAt = Date.now();
        ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
      },
    },
  });
  releases.push(["stand-in acpmux", () => daemon.stop(true)]);

  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "chat-open-bench-"));
  releases.push(["pane build", () => fs.rmSync(out, { recursive: true, force: true })]);
  const { build } = await import("vite");
  await build({
    configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
    build: {
      outDir: out,
      emptyOutDir: true,
      ...(process.env.PROFILE === "1" ? { minify: false, sourcemap: true } : {}),
    },
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
  releases.push(["static server", () => statics.stop(true)]);
  const url = `http://127.0.0.1:${statics.port}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&session=${PAPERCUT_CHAT}`;
  const browser = await chromium.launch({ headless: true });
  releases.push(["browser", () => browser.close()]);

  type Round = {
    attach: number;
    firstRow: number;
    latest: number;
    settled: number;
    longTasks: number;
    longMs: number;
    shift: number;
    drift: number;
    socket: number;
    initialize: number;
    watch: number;
    dcl: number;
    scriptKiB: number;
    scripts: string[];
    forced: { writes: number; writeMs: number; reads: number; readMs: number; byClass: Record<string, number>; log: string[] };
  };
  const open = async (rail = "compact"): Promise<Round> => {
    const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
    await page.addInitScript((rail) => {
      localStorage.setItem("cmux.experiments", JSON.stringify({ "thread-minimap-layout": rail }));
    }, rail);
    await page.addInitScript(([latestText, instrument]) => {
      const forced = {
        writes: 0,
        writeMs: 0,
        reads: 0,
        readMs: 0,
        byClass: {} as Record<string, number>,
        log: [] as string[],
      };
      (window as unknown as { __forced: typeof forced }).__forced = forced;
      // INSTRUMENT=1: scroll writes and layout reads the page makes, and the time each takes (a write
      // or read after a DOM change is where the browser lays out synchronously).
      if (instrument) {
        const top = Object.getOwnPropertyDescriptor(Element.prototype, "scrollTop")!;
        Object.defineProperty(Element.prototype, "scrollTop", {
          ...top,
          set(this: Element, value: number) {
            const started = performance.now();
            top.set!.call(this, value);
            forced.writes += 1;
            forced.writeMs += performance.now() - started;
            const key = String(this.className).split(" ")[0] || this.tagName;
            forced.log.push(`${key} to ${Math.round(value)} at ${started.toFixed(0)} ms, ${(performance.now() - started).toFixed(1)} ms`);
            forced.byClass[key] = (forced.byClass[key] ?? 0) + 1;
          },
        });
        const rect = Element.prototype.getBoundingClientRect;
        Element.prototype.getBoundingClientRect = function (this: Element) {
          const started = performance.now();
          const box = rect.call(this);
          forced.reads += 1;
          forced.readMs += performance.now() - started;
          return box;
        };
      }
      const state = { firstRow: 0, latest: 0, activity: 0, longTasks: 0, longMs: 0, shift: 0, top: -1, drift: 0 };
      (window as unknown as { __open: typeof state }).__open = state;
      const afterPaint = (done: () => void) => requestAnimationFrame(() => setTimeout(done, 0));
      new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) {
          state.longTasks += 1;
          state.longMs += entry.duration;
          state.activity = Math.max(state.activity, entry.startTime + entry.duration);
        }
      }).observe({ type: "longtask", buffered: true });
      new PerformanceObserver((list) => {
        for (const entry of list.getEntries() as unknown as { value: number; hadRecentInput: boolean; startTime: number }[]) {
          if (entry.hadRecentInput) continue;
          state.shift += entry.value;
          state.activity = Math.max(state.activity, entry.startTime);
        }
      }).observe({ type: "layout-shift", buffered: true });
      const tick = () => {
        const now = performance.now();
        if (!state.firstRow && document.querySelector("[data-row-id]")) afterPaint(() => (state.firstRow ||= performance.now()));
        if (!state.latest && document.body.textContent?.includes(latestText)) afterPaint(() => (state.latest ||= performance.now()));
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
        const top = scroller ? scroller.scrollTop + scroller.scrollHeight : -1;
        if (top !== state.top) {
          if (state.latest) state.drift += 1;
          state.top = top;
          state.activity = Math.max(state.activity, now);
        }
        requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    }, [LATEST, process.env.INSTRUMENT === "1"] as const);
    attachedAt = 0;
    arrivals = new Map();
    socketOpenedAt = 0;
    const started = Date.now();
    await page.goto(url);
    await page.waitForFunction(
      () => {
        const state = (window as unknown as { __open: { latest: number; activity: number } }).__open;
        return state.latest > 0 && performance.now() - Math.max(state.latest, state.activity) > 400;
      },
      undefined,
      { timeout: 120_000, polling: 100 },
    );
    const got = await page.evaluate(() => {
      const state = (
        window as unknown as {
          __open: {
            firstRow: number;
            latest: number;
            activity: number;
            longTasks: number;
            longMs: number;
            shift: number;
            drift: number;
          };
        }
      ).__open;
      const forced = (window as unknown as { __forced: unknown }).__forced;
      const nav = performance.getEntriesByType("navigation")[0] as PerformanceNavigationTiming;
      const scripts = performance.getEntriesByType("resource").filter((r) => (r as PerformanceResourceTiming).initiatorType === "script" || r.name.endsWith(".js")) as PerformanceResourceTiming[];
      return {
        ...state,
        origin: performance.timeOrigin,
        forced,
        dcl: nav.domContentLoadedEventEnd,
        scriptKiB: scripts.reduce((sum, r) => sum + r.decodedBodySize, 0) / 1024,
        scripts: scripts
          .map((r) => `${r.name.split("/").pop()} ${(r.decodedBodySize / 1024).toFixed(0)} KiB`)
          .sort((a, b) => Number(b.split(" ").at(-2)) - Number(a.split(" ").at(-2))),
      };
    });
    await page.close();
    const attach = attachedAt ? attachedAt - got.origin : 0;
    const at = (when: number | undefined) => (when ? when - got.origin : 0);
    void started;
    return {
      attach,
      firstRow: got.firstRow,
      latest: got.latest,
      settled: Math.max(got.latest, got.activity),
      longTasks: got.longTasks,
      longMs: got.longMs,
      shift: got.shift,
      drift: got.drift,
      socket: at(socketOpenedAt),
      initialize: at(arrivals.get("initialize")),
      watch: at(arrivals.get("_acpmux/watch")),
      dcl: got.dcl,
      scriptKiB: got.scriptKiB,
      scripts: got.scripts as unknown as string[],
      forced: got.forced as Round["forced"],
    };
  };

  if (process.env.PROFILE === "1") {
    const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Profiler.enable");
    await cdp.send("Profiler.setSamplingInterval", { interval: 200 });
    await cdp.send("Profiler.start");
    await page.goto(url);
    await page.getByText(LATEST, { exact: false }).first().waitFor({ timeout: 120_000 });
    await page.waitForTimeout(500);
    const { profile } = (await cdp.send("Profiler.stop")) as {
      profile: {
        nodes: { id: number; callFrame: { functionName: string; url: string; lineNumber: number; columnNumber: number } }[];
        samples: number[];
        timeDeltas: number[];
      };
    };
    const mapper = sourceMapper(out);
    const byId = new Map(profile.nodes.map((node) => [node.id, node]));
    const self = new Map<string, number>();
    profile.samples.forEach((id, index) => {
      const frame = byId.get(id)!.callFrame;
      const file = frame.url.split("/").slice(-1)[0] ?? "";
      const where = file ? mapper(file, frame.lineNumber, frame.columnNumber) : "(native)";
      const key = `${frame.functionName || "(anon)"} ${where}`;
      self.set(key, (self.get(key) ?? 0) + (profile.timeDeltas[index] ?? 0) / 1000);
    });
    const total = [...self.values()].reduce((a, b) => a + b, 0);
    console.log(`profile: ${total.toFixed(0)} ms sampled; top self time (ms)`);
    for (const [key, ms] of [...self].sort((a, b) => b[1] - a[1]).slice(0, 30)) console.log(`${ms.toFixed(1)}\t${key}`);
    await page.close();
  }
  // ARMS=off,compact: the thread rail's layout per arm (compact is the default), interleaved in
  // alternating order so drift hits every arm alike.
  const arms = process.env.ARMS?.split(",") ?? ["compact"];
  await open(arms[0]); // warm the page's caches
  const byArm = new Map<string, Round[]>(arms.map((arm) => [arm, []]));
  for (let round = 0; round < ROUNDS; round += 1)
    for (const arm of round % 2 ? [...arms].reverse() : arms) byArm.get(arm)!.push(await open(arm));
  for (const [arm, rounds] of byArm) {
    const median = (pick: (r: Round) => number) =>
      [...rounds.map(pick)].sort((a, b) => a - b)[Math.floor(rounds.length / 2)]!;
    console.log(
      `chat-open [rail ${arm}]: ${TURNS} turns, ${events.length} events, attach page ${attachEvents} events, ${(attachBytes / 1024).toFixed(0)} KiB, median of ${ROUNDS}`,
    );
    console.log(
      "boot: page DOMContentLoaded ms | socket opened ms | initialize arrived ms | watch arrived ms | script KiB (decoded)",
    );
    console.log(
      [
        median((r) => r.dcl).toFixed(0),
        median((r) => r.socket).toFixed(0),
        median((r) => r.initialize).toFixed(0),
        median((r) => r.watch).toFixed(0),
        median((r) => r.scriptKiB).toFixed(0),
      ].join(" | "),
    );
    if (process.env.INSTRUMENT === "1") {
      const last = rounds.at(-1)!.forced;
      console.log(
        `forced layout in one load: scrollTop writes ${last.writes} (${last.writeMs.toFixed(1)} ms) ${JSON.stringify(last.byClass)}, getBoundingClientRect reads ${last.reads} (${last.readMs.toFixed(1)} ms)`,
      );
      for (const line of last.log) console.log(`  scrollTop write: ${line}`);
    }
    console.log(`scripts loaded (${rounds[0]!.scripts.length}): ${rounds[0]!.scripts.slice(0, 12).join(", ")}`);
    console.log(
      "attach ms | firstRow ms | latest ms | settled ms | long tasks | long ms | layout shift | scroll moves after latest",
    );
    console.log(
      [
        median((r) => r.attach).toFixed(0),
        median((r) => r.firstRow).toFixed(0),
        median((r) => r.latest).toFixed(0),
        median((r) => r.settled).toFixed(0),
        median((r) => r.longTasks).toFixed(0),
        median((r) => r.longMs).toFixed(0),
        median((r) => r.shift).toFixed(4),
        median((r) => r.drift).toFixed(0),
      ].join(" | "),
    );
  }
} finally {
  await release();
}
