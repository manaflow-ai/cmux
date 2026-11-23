// l10n-allow-file: bench output labels, not shipped UI.
// The NEXT desktop chat under several heavy coordinators at once (Leo, 2026-11-19, paraphrased: simulate a load as
// heavy as his biggest coordinator chats, without his real chats: many events arriving at once, several coordinators
// at the same time; stress test everything). The records come from coord-sim (cmux-tui/crates/coord-sim, `surface
// --target app-host`): COORDS chats shaped by histograms of real coordinator sessions, each holding HISTORY records
// before a reader comes, then streaming for SECONDS at RATE times their real pace (filler text, no transcript).
// The production pane (a vite build of the pane's dev entry) runs in Chromium with --process-per-site, as the app
// gives cmux-page one renderer, on a stand-in acpmux that serves those records as acpmux does (attach and events
// pages: daemonPage.ts) and pushes the live ones as `_acpmux/event`. While every chat streams, scripted readers:
//   attach     open one page per chat (up to READERS): first_row is navigation to the first transcript row painted,
//              attach_rpc the stand-in's attach answer after navigation (both ms; p50/p95 over the pages);
//   scroll     wheel up the newest page's transcript (40 px a frame, SCROLL_STEPS steps): frame interval p50/p95,
//              fps, long frames (over 50 ms) and janky frames (over 1.5 refresh intervals, 25 ms);
//   find       Find in Chat for a word every chat holds: the action to its bar painted, ms;
//   switch     on the first page, select each other chat in turn (`chat.select`, as the sidebar does): the call to
//              a row of that chat painted, ms;
//   typing     KEYS letters into the newest page's composer: the pane's own typingStats (keydown to next frame);
//   renderer   the renderers' CPU (% of one core) over CPU_S seconds of streaming with every page open, and their
//              PSS after it, each divided by the chats open (per chat), plus the totals.
// Rows: PERF_ROW coord_sim_load.c<COORDS>.<measure>. Raw samples: RUN_DIR (COORD_SIM_RUN_DIR, default a temp dir)
// /app-host-c<COORDS>/samples.ndjson, one line per sample ({"t","target","metric","value","unit"}), and summary.json.
//   COORD_SIM_BIN=../cmux-tui/crates/coord-sim/target/release/coord-sim \
//     bun bench/coord-sim-load.bench.ts [coords=3] [rate=10] [seconds=60] [history=5000]
// COORD_SIM_RECORDS=DIR serves records written before (coord-sim surface --target app-host --out DIR).
// COORD_SIM_SESSIONS=DIR,DIR serves sized acpmux session dirs as the chats' history (TAIL_RECORDS of each); STREAM=0 idle.
// Linux only (renderer CPU and memory from /proc).
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { ServerWebSocket } from "bun";
import type { Page } from "playwright";
import { chromium } from "./browsers";
import { newestPage } from "./daemonPage";
import { perfRow, TARGET_MS } from "./perfRow";
import { cpuTicks, pssMB, renderers, TICK_HZ } from "./procStats";

const COORDS = Number(process.argv[2] ?? 3);
const RATE = Number(process.argv[3] ?? 10);
const SECONDS = Number(process.argv[4] ?? 60);
const HISTORY = Number(process.argv[5] ?? 5000);
const READERS = Math.min(COORDS, Number(process.env.READERS ?? 20));
const SCROLL_STEPS = Number(process.env.SCROLL_STEPS ?? 120);
const KEYS = Number(process.env.KEYS ?? 40);
const CPU_S = Number(process.env.CPU_S ?? 10);
const SWITCHES = Math.min(COORDS - 1, Number(process.env.SWITCHES ?? 5));
// Sized chats (the generator's acpmux session dirs: session.json and events/NNNNNN.ndjson, 1 MB to 4 GB): chat i takes
// session i's newest TAIL_RECORDS records as its history (read from the newest event file back, so a 4 GB chat costs
// only its tail here; acpmux pages the same way). STREAM=0 measures them idle.
const SESSIONS = (process.env.COORD_SIM_SESSIONS ?? "").split(",").filter(Boolean);
const TAIL_RECORDS = Number(process.env.TAIL_RECORDS ?? 20_000);
const STREAM = process.env.STREAM !== "0";
const PROMPT = ".acpmux-composer-prompt[contenteditable='true'], .acpmux-composer-prompt [contenteditable='true']";
if (process.platform !== "linux") {
  console.error("coord-sim-load: Linux only (renderer CPU and memory from /proc)");
  process.exit(2);
}
if (!(COORDS >= 1 && RATE > 0 && SECONDS > 0)) {
  console.error("usage: bun bench/coord-sim-load.bench.ts [coords=3] [rate=10] [seconds=60] [history=5000]");
  process.exit(2);
}
const webviews = path.resolve(import.meta.dir, "..");
// LABEL names the run in its rows and RUN_DIR folder (a sized run: LABEL=c3-1gb).
const TAG = process.env.LABEL ?? `c${COORDS}${process.env.STREAM === "0" ? "-idle" : ""}`;
const ROW = `coord_sim_load.${TAG}`;

type Rec = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
type Manifest = { chats: { sessionId: string; title: string; history: number; live: number }[]; rate: number };
const readNdjson = (file: string): Rec[] =>
  fs
    .readFileSync(file, "utf8")
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line) as Rec);
const eventFiles = (dir: string) =>
  fs
    .readdirSync(path.join(dir, "events"))
    .filter((name) => name.endsWith(".ndjson"))
    .sort()
    .map((name) => path.join(dir, "events", name));
const sessionBytes = (dir: string) => eventFiles(dir).reduce((sum, file) => sum + fs.statSync(file).size, 0);
/// The newest `limit` records of an acpmux session dir, keyed to `id` (the chat the stand-in serves them as).
function sessionTail(dir: string, id: string, limit: number, index: number): Rec[] {
  const out: Rec[] = [];
  for (const file of eventFiles(dir).reverse()) {
    const lines = fs.readFileSync(file, "utf8").split("\n").filter(Boolean);
    for (let i = lines.length - 1; i >= 0 && out.length < limit; i--)
      out.push({ ...(JSON.parse(lines[i]!) as Rec), sessionId: id });
    if (out.length >= limit) break;
  }
  if (!out.length) throw new Error(`coord-sim-load: no records in ${dir} (chat ${index})`);
  return out.reverse();
}
const pct = (values: number[], p: number) => {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted.length ? sorted[Math.min(sorted.length - 1, Math.round((sorted.length - 1) * p))]! : 0;
};

const releases: (() => unknown)[] = [];
const release = async () => {
  for (const stop of releases.splice(0).reverse()) {
    try {
      await stop();
    } catch {
      // Release the rest.
    }
  }
};
process.once("SIGINT", () => void release().then(() => process.exit(130)));

const runDir = path.join(
  process.env.COORD_SIM_RUN_DIR ?? fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "coord-sim-run-")),
  `app-host-${TAG}`,
);
fs.mkdirSync(runDir, { recursive: true });
const samplesOut = fs.createWriteStream(path.join(runDir, "samples.ndjson"));
const sample = (metric: string, value: number, unit: string, extra: Record<string, unknown> = {}) =>
  samplesOut.write(`${JSON.stringify({ t: "sample", target: "app-host", metric, value, unit, ...extra })}\n`);
const summary: Record<string, unknown> = {
  schema: "coord-sim-surface.v1",
  target: "app-host",
  coordinators: COORDS,
  rate: RATE,
  seconds: SECONDS,
  history: HISTORY,
};
const row = (name: string, values: number[], unit: string, target?: number) => {
  if (!values.length) return;
  const out = { p50: pct(values, 0.5), p95: pct(values, 0.95), max: pct(values, 1), n: values.length, unit };
  summary[name] = out;
  perfRow({ name: `${ROW}.${name}`, p50: out.p50, p95: out.p95, unit, ...(target ? { target } : {}) });
};

try {
  // The records: coord-sim writes them, or a directory written before.
  let recordsDir = process.env.COORD_SIM_RECORDS;
  if (!recordsDir) {
    recordsDir = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "coord-sim-records-"));
    const dir = recordsDir;
    releases.push(() => fs.rmSync(dir, { recursive: true, force: true }));
    const bin =
      process.env.COORD_SIM_BIN ?? path.join(webviews, "../cmux-tui/crates/coord-sim/target/release/coord-sim");
    const made = Bun.spawnSync([
      bin,
      "surface",
      "--target",
      "app-host",
      "--coordinators",
      String(COORDS),
      "--rate",
      String(RATE),
      "--seconds",
      String(SECONDS),
      "--history",
      String(HISTORY),
      "--out",
      dir,
    ]);
    if (made.exitCode !== 0) throw new Error(`coord-sim: ${made.stderr.toString()}`);
  }
  const manifest = JSON.parse(fs.readFileSync(path.join(recordsDir, "manifest.json"), "utf8")) as Manifest;
  const history = manifest.chats.map((chat, i) => {
    const sized = SESSIONS[i % Math.max(1, SESSIONS.length)];
    return sized
      ? sessionTail(sized, chat.sessionId, TAIL_RECORDS, i)
      : readNdjson(path.join(recordsDir!, `history-${i}.ndjson`));
  });
  // A sized chat's live records continue its own sequence.
  const nextSeq = new Map(manifest.chats.map((chat, i) => [chat.sessionId, (history[i]!.at(-1)?.seq ?? 0) + 1]));
  const live = STREAM
    ? readNdjson(path.join(recordsDir, "live.ndjson")).map((rec) => {
        const seq = nextSeq.get(rec.sessionId) ?? rec.seq;
        nextSeq.set(rec.sessionId, seq + 1);
        return { ...rec, seq };
      })
    : [];
  if (SESSIONS.length) summary.sessions = SESSIONS.map((dir) => ({ dir, bytes: sessionBytes(dir) }));
  console.log(
    `coord-sim-load: ${COORDS} coordinators at ${RATE}x for ${SECONDS}s, ${HISTORY} records each before attach, ` +
      `${live.length} live records (${(live.length / SECONDS).toFixed(0)}/s), ${READERS} readers`,
  );

  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "coord-sim-load-"));
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
      if (!(await file.exists())) return new Response("not found", { status: 404 });
      return new Response(file);
    },
  });
  releases.push(() => statics.stop(true));

  // The stand-in daemon: every chat's history, plus what streamed into it since.
  const records = new Map<string, Rec[]>(manifest.chats.map((chat, i) => [chat.sessionId, history[i]!]));
  const sessions = manifest.chats.map((chat) => ({
    sessionId: chat.sessionId,
    cwd: "/home/dev/cmux",
    title: chat.title,
    harness: "claude",
    family: "claude",
    status: "running",
    turnCount: 1,
    updatedAt: Date.now(),
  }));
  const lastSeqOf = (id: string) => records.get(id)?.at(-1)?.seq ?? 0;
  const summaryOf = (id: string) => ({
    ...(sessions.find((s) => s.sessionId === id) ?? sessions[0]!),
    lastSeq: lastSeqOf(id),
  });
  const watchers = new Map<string, Set<ServerWebSocket<undefined>>>();
  const attachAnswered: { id: string; at: number }[] = [];
  const answer = (ws: ServerWebSocket<undefined>, method: string, params: Record<string, unknown>): unknown => {
    const id = String(params.sessionId ?? sessions[0]!.sessionId);
    const list = records.get(id) ?? [];
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: sessions.map((s) => summaryOf(s.sessionId)) };
      case "_acpmux/attach": {
        const set = watchers.get(id) ?? new Set();
        set.add(ws);
        watchers.set(id, set);
        const { page, hasMore } = newestPage(list, { limit: Number(params.limit ?? 400), maxBytes: params.maxBytes });
        attachAnswered.push({ id, at: performance.now() });
        return { session: summaryOf(id), lastSeq: lastSeqOf(id), events: page, hasMore };
      }
      case "_acpmux/events": {
        if (params.promptIndex === true) {
          const before = params.beforeSeq === undefined ? Infinity : Number(params.beforeSeq);
          const prompts = list.filter((r) => r.kind === "user_message" && r.seq < before);
          return { events: prompts, hasMore: false, lastSeq: lastSeqOf(id) };
        }
        if (params.beforeSeq !== undefined) {
          const { page, hasMore } = newestPage(list, {
            limit: Number(params.limit ?? 400),
            beforeSeq: Number(params.beforeSeq),
            maxBytes: params.maxBytes,
          });
          return { events: page, hasMore, lastSeq: lastSeqOf(id) };
        }
        const after = Number(params.afterSeq ?? lastSeqOf(id));
        return { events: list.filter((r) => r.seq > after), hasMore: false, lastSeq: lastSeqOf(id) };
      }
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
        const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, unknown> };
        if (message.id === undefined) return;
        ws.send(
          JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(ws, message.method, message.params ?? {}) }),
        );
      },
      close(ws) {
        for (const set of watchers.values()) set.delete(ws);
      },
    },
  });
  releases.push(() => daemon.stop(true));

  // The stream: every chat's live records at their offsets, from now until SECONDS (or the readers finish).
  let streaming = true;
  let streamed = 0;
  let behindMs = 0;
  const streamStart = performance.now();
  const stream = (async () => {
    for (const rec of live) {
      if (!streaming) break;
      const due = streamStart + rec.at;
      const now = performance.now();
      if (due > now) await Bun.sleep(due - now);
      else behindMs = Math.max(behindMs, now - due);
      const list = records.get(rec.sessionId);
      if (!list) continue;
      const record = { ...rec, at: Date.now() };
      list.push(record);
      streamed += 1;
      const text = JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: record });
      for (const ws of watchers.get(rec.sessionId) ?? []) ws.send(text);
    }
  })();
  releases.push(() => {
    streaming = false;
  });

  const server = await chromium.launchServer({
    headless: true,
    args: ["--process-per-site", "--js-flags=--expose-gc"],
  });
  releases.push(() => server.close());
  const root = server.process().pid!;
  const browser = await chromium.connect(server.wsEndpoint());
  const context = await browser.newContext({ viewport: { width: 1200, height: 800 } });
  await context.addInitScript(() => {
    const w = window as unknown as { __firstRow?: number; __longTasks: number[] };
    w.__longTasks = [];
    try {
      new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) w.__longTasks.push(entry.duration);
      }).observe({ type: "longtask", buffered: true });
    } catch {
      // No long task timing in this engine.
    }
    const tick = () => {
      if (!w.__firstRow && document.querySelector("[data-row-id]"))
        requestAnimationFrame(() => setTimeout(() => (w.__firstRow ||= performance.now()), 0));
      if (!w.__firstRow) requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  });
  const urlFor = (id: string) =>
    `http://127.0.0.1:${statics.port}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&session=${id}`;

  // Attach: one reader per chat, while all of them stream.
  const pages: Page[] = [];
  const firstRows: number[] = [];
  const attachRpc: number[] = [];
  for (let i = 0; i < READERS; i++) {
    const id = manifest.chats[i]!.sessionId;
    const page = await context.newPage();
    const began = performance.now();
    const answeredBefore = attachAnswered.length;
    await page.goto(urlFor(id));
    await page.waitForFunction(() => (window as unknown as { __firstRow?: number }).__firstRow, undefined, {
      timeout: 120_000,
      polling: 100,
    });
    const first = await page.evaluate(() => (window as unknown as { __firstRow: number }).__firstRow);
    const answered = attachAnswered.slice(answeredBefore).find((a) => a.id === id);
    firstRows.push(first);
    sample("first_row", first, "ms", { chat: i });
    if (answered) {
      attachRpc.push(answered.at - began);
      sample("attach_rpc", answered.at - began, "ms", { chat: i });
    }
    pages.push(page);
  }
  row("first_row", firstRows, "ms", TARGET_MS.load);
  row("attach_rpc", attachRpc, "ms");

  // Renderer CPU and memory with every reader open and every chat streaming.
  const pids = renderers(root);
  const t0 = cpuTicks(pids);
  const c0 = performance.now();
  await Bun.sleep(CPU_S * 1000);
  const cpuPct = ((cpuTicks(pids) - t0) / TICK_HZ / ((performance.now() - c0) / 1000)) * 100;
  for (const page of pages) await page.evaluate(() => (globalThis as unknown as { gc?: () => void }).gc?.());
  const mb = pids.reduce((sum, pid) => {
    try {
      return sum + pssMB(pid);
    } catch {
      return sum;
    }
  }, 0);
  sample("renderer_cpu_pct", cpuPct, "%", { renderers: pids.length, chats: pages.length });
  sample("renderer_mb", mb, "MB", { renderers: pids.length, chats: pages.length });
  row("renderer_cpu_pct", [cpuPct], "%");
  row("renderer_cpu_pct_per_chat", [cpuPct / pages.length], "%");
  row("renderer_mb", [mb], "MB");
  row("renderer_mb_per_chat", [mb / pages.length], "MB");

  // Scroll the newest page while it streams.
  const shown = pages.at(-1)!;
  await shown.bringToFront();
  await shown.locator(".acpmux-scroll").first().hover();
  await shown.evaluate(() => {
    const w = window as unknown as { __frames: number[]; __framesOn: boolean; __longTasks: number[] };
    w.__frames = [];
    w.__framesOn = true;
    w.__longTasks.length = 0;
    const step = (now: number) => {
      if (!w.__framesOn) return;
      w.__frames.push(now);
      requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  });
  for (let i = 0; i < SCROLL_STEPS; i++) {
    await shown.mouse.wheel(0, -40);
    await shown.evaluate(() => new Promise((done) => requestAnimationFrame(done)));
  }
  const scroll = await shown.evaluate(() => {
    const w = window as unknown as { __frames: number[]; __framesOn: boolean; __longTasks: number[] };
    w.__framesOn = false;
    return { frames: w.__frames, longTasks: [...w.__longTasks] };
  });
  const intervals = scroll.frames.slice(1).map((t, i) => t - scroll.frames[i]!);
  for (const ms of intervals) sample("scroll_frame", ms, "ms");
  const span = (scroll.frames.at(-1)! - scroll.frames[0]!) / 1000;
  row("scroll_frame", intervals, "ms", TARGET_MS.frameWork + 6.7);
  row("scroll_fps", [span > 0 ? intervals.length / span : 0], "fps");
  row("scroll_long_frames", [intervals.filter((ms) => ms > 50).length], "count");
  row("scroll_jank_frames", [intervals.filter((ms) => ms > 25).length], "count");
  row("scroll_long_task_ms", [scroll.longTasks.reduce((a, b) => a + b, 0)], "ms");

  // Find in Chat for a word the filler always has.
  const finds: number[] = [];
  for (const word of ["kernel", "merge", "patch"]) {
    const ms = await shown.evaluate(async (text) => {
      const actions = (window as unknown as { cmuxAcpmuxActions?: Record<string, (a: unknown) => Promise<unknown>> })
        .cmuxAcpmuxActions;
      const began = performance.now();
      await actions?.["chat.find"]?.({ text });
      for (let i = 0; i < 600 && !document.querySelector(".acpmux-find"); i++)
        await new Promise((done) => requestAnimationFrame(done));
      await new Promise((done) => requestAnimationFrame(() => setTimeout(done, 0)));
      return performance.now() - began;
    }, word);
    finds.push(ms);
    sample("find", ms, "ms", { word });
    await shown.keyboard.press("Escape");
  }
  row("find", finds, "ms", TARGET_MS.response);

  // Switch chats on the first page, as the sidebar does.
  const switches: number[] = [];
  const first = pages[0]!;
  await first.bringToFront();
  for (let i = 1; i <= SWITCHES; i++) {
    const id = manifest.chats[i]!.sessionId;
    const ms = await first.evaluate(async (sessionId) => {
      const before = new Set(
        [...document.querySelectorAll("[data-row-id]")].map((el) => el.getAttribute("data-row-id")),
      );
      const actions = (window as unknown as { cmuxAcpmuxActions?: Record<string, (a: unknown) => Promise<unknown>> })
        .cmuxAcpmuxActions;
      const began = performance.now();
      void actions?.["chat.select"]?.({ sessionId });
      for (let f = 0; f < 1200; f++) {
        await new Promise((done) => requestAnimationFrame(done));
        const rows = [...document.querySelectorAll("[data-row-id]")];
        if (rows.length && rows.every((el) => !before.has(el.getAttribute("data-row-id")))) break;
      }
      await new Promise((done) => requestAnimationFrame(() => setTimeout(done, 0)));
      return performance.now() - began;
    }, id);
    switches.push(ms);
    sample("switch", ms, "ms", { to: i });
  }
  row("switch", switches, "ms", TARGET_MS.response);

  // Typing into the newest page's composer while everything streams.
  await shown.bringToFront();
  await shown.locator(PROMPT).first().click();
  await shown.evaluate(() =>
    (window as unknown as { cmuxAcpmuxDebug: { resetTyping(): unknown } }).cmuxAcpmuxDebug.resetTyping(),
  );
  for (let i = 0; i < KEYS; i++) await shown.keyboard.type(String.fromCharCode(97 + (i % 26)), { delay: 50 });
  const typing = (await shown.evaluate(() =>
    (window as unknown as { cmuxAcpmuxDebug: { typingStats(): unknown } }).cmuxAcpmuxDebug.typingStats(),
  )) as { keys: number; to_frame: { p50_ms: number; p95_ms: number; max_ms: number } };
  summary.typing = typing;
  sample("typing_to_frame_p95", typing.to_frame.p95_ms, "ms", { keys: typing.keys });
  perfRow({
    name: `${ROW}.typing_to_frame`,
    p50: typing.to_frame.p50_ms,
    p95: typing.to_frame.p95_ms,
    unit: "ms",
    target: TARGET_MS.frameWork + 6.7,
  });

  streaming = false;
  await stream;
  summary.streamed = streamed;
  summary.stream_events_per_s = streamed / ((performance.now() - streamStart) / 1000);
  summary.stream_behind_max_ms = behindMs;
  row("stream_events_per_s", [summary.stream_events_per_s as number], "events/s");
  fs.writeFileSync(path.join(runDir, "summary.json"), JSON.stringify(summary, null, 2));
  console.log(`coord-sim-load: samples in ${runDir}`);
  console.log(JSON.stringify(summary));
} finally {
  samplesOut.end();
  await release();
}
