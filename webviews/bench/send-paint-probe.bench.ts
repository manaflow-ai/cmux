// l10n-allow-file: bench fixture prompts and replies, not shipped UI.
// Enter in the composer to the first painted frame that shows the sent bubble, and what the frames cost meanwhile,
// in the production pane (a vite build of the pane's dev entry) joined to a stand-in acpmux holding HISTORY finished
// turns (about 3 rows each). Light instrumentation only: one capturing keydown listener, a MutationObserver that
// notes when the bubble's node first holds the prompt, one read per painted frame (cmuxAfterPaint), a rAF loop for
// frame intervals, and the Long Animation Frames / Event Timing observers. Per round a fresh page.
//   bun bench/send-paint-probe.bench.ts --history 7 --rounds 12 [--cpu 4] [--profile] [--json FILE]
// MINIFY=0 builds unminified so a --profile names functions.
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium } from "./browsers";
import type { Browser, CDPSession, Page } from "playwright";
import { installPaintedFrames } from "../test/support/paintedFrames";

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : undefined;
};
const HISTORY = Number(flag("--history") ?? 7);
const ROUNDS = Number(flag("--rounds") ?? 10);
const CPU = Number(flag("--cpu") ?? 1);
const PROFILE = argv.includes("--profile");
/// --trace: one more round under a Chromium trace; reports the style and layout passes in the Enter's task.
const TRACE = argv.includes("--trace");
const JSON_OUT = flag("--json");
const MINIFY = process.env.MINIFY !== "0";
const webviews = path.resolve(import.meta.dir, "..");
const SESSION = "0190a000-0000-7000-8000-0000000000e9";
const PROMPT = "Find every retry loop and fix the cap";

// ---------- the stand-in acpmux ----------
let status = "idle";
const summary = () => ({
  sessionId: SESSION,
  cwd: "/home/dev/sun",
  title: "Retry policy",
  harness: "claude",
  family: "claude",
  status,
  steering: true,
  queuePaused: false,
  queued: 0,
  queue: [],
  turnCount: HISTORY,
  updatedAt: Date.now(),
});
const chunk = (text: string) => ({
  method: "session/update",
  params: { sessionId: "agent-1", update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
});
type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
const events: Event[] = [];
const record = (dir: string, kind: string, msg: Record<string, unknown>): Event => {
  const event = { sessionId: SESSION, seq: events.length + 1, at: Date.now(), dir, kind, msg };
  events.push(event);
  return event;
};
for (let turn = 0; turn < HISTORY; turn++) {
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
const opened = events.length;
function answer(method: string): unknown {
  switch (method) {
    case "initialize":
      return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    case "_acpmux/watch":
      return { sessions: [summary()] };
    case "_acpmux/attach":
      return { session: summary(), lastSeq: events.length, events: events.slice() };
    case "_acpmux/events":
      return { events: [], hasMore: false, lastSeq: events.length };
    default:
      return null;
  }
}

// ---------- page side ----------
type Probe = {
  keydownTs: number;
  mountAt: number;
  paintAt: number;
  paintFrameTs: number;
  frames: number[];
  loaf: { start: number; duration: number; blocking: number; scripts: { fn: string; src: string; dur: number }[] }[];
  evt: { name: string; start: number; procStart: number; procEnd: number; duration: number }[];
};
function arm(prompt: string) {
  const w = window as unknown as { __p: Probe; __stopFrames?: () => void };
  const p: Probe = { keydownTs: 0, mountAt: 0, paintAt: 0, paintFrameTs: 0, frames: [], loaf: [], evt: [] };
  w.__p = p;
  const has = () =>
    [...document.querySelectorAll(".cv-user__bubble")].find((node) => node.textContent?.includes(prompt)) as
      | HTMLElement
      | undefined;
  new PerformanceObserver((list) => {
    for (const e of list.getEntries() as unknown as {
      startTime: number;
      duration: number;
      blockingDuration: number;
      scripts: { sourceFunctionName: string; sourceURL: string; invoker: string; duration: number }[];
    }[])
      p.loaf.push({
        start: e.startTime,
        duration: e.duration,
        blocking: e.blockingDuration,
        scripts: e.scripts.map((s) => ({
          fn: s.sourceFunctionName || s.invoker,
          src: s.sourceURL.split("/").pop() ?? "",
          dur: s.duration,
        })),
      });
  }).observe({ type: "long-animation-frame", buffered: false });
  new PerformanceObserver((list) => {
    for (const e of list.getEntries() as PerformanceEventTiming[])
      p.evt.push({
        name: e.name,
        start: e.startTime,
        procStart: e.processingStart,
        procEnd: e.processingEnd,
        duration: e.duration,
      });
  }).observe({ type: "event", durationThreshold: 16, buffered: false } as PerformanceObserverInit);
  addEventListener(
    "keydown",
    (e) => {
      if ((e as KeyboardEvent).key === "Enter" && !p.keydownTs) p.keydownTs = e.timeStamp;
    },
    { capture: true },
  );
  const mo = new MutationObserver(() => {
    if (!p.mountAt && has()) {
      p.mountAt = performance.now();
      mo.disconnect();
    }
  });
  mo.observe(document.body, { childList: true, subtree: true, characterData: true });
  const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
  window.cmuxAfterPaint((frame) => {
    if (!p.keydownTs) return;
    const bubble = has();
    if (!bubble) return;
    const b = bubble.getBoundingClientRect();
    const v = scroller.getBoundingClientRect();
    if (b.height > 0 && b.bottom > v.top && b.top < v.bottom) {
      p.paintAt = performance.now();
      p.paintFrameTs = frame;
      return false;
    }
  });
  let on = true;
  const tick = (ts: number) => {
    p.frames.push(ts);
    if (on) requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
  w.__stopFrames = () => (on = false);
}

type Round = {
  keyToMount: number;
  keyToPaint: number;
  mountToPaint: number;
  enterProcessing: number;
  enterQueue: number;
  frameMax: number;
  framesOver17: number;
  framesOver33: number;
  frameCount: number;
  loafCount: number;
  loafMax: number;
  loafBlocking: number;
  scripts: { fn: string; src: string; dur: number }[];
};

let profileOut: unknown;
let rowsLogged = false;
type TraceEv = {
  name: string;
  ph: string;
  ts: number;
  dur?: number;
  tid: number;
  args?: {
    data?: { type?: string; stackTrace?: { functionName: string; url: string; lineNumber: number }[] };
    beginData?: { stackTrace?: { functionName: string; url: string; lineNumber: number }[] };
  };
};
let traceOut: TraceEv[] = [];
async function round(browser: Browser, url: string, profile: boolean, trace = false): Promise<Round> {
  events.length = opened;
  status = "idle";
  const page: Page = await browser.newPage({ viewport: { width: 900, height: 640 } });
  let cdp: CDPSession | undefined;
  try {
    await installPaintedFrames(page);
    await page.addInitScript(() => Object.assign(window, { cmuxFrameBudget: "on" }));
    await page.goto(url);
    await page.locator(".acpmux-composer-prompt").waitFor({ timeout: 120_000 });
    await page.locator("[data-row-id]").first().waitFor({ timeout: 120_000 });
    await page.locator(".acpmux-composer-prompt").click();
    await page.keyboard.type(PROMPT);
    await page.mouse.move(0, 0);
    await page.waitForTimeout(1500);
    if (!rowsLogged) {
      rowsLogged = true;
      const rows = await page.evaluate(
        () =>
          (window as unknown as { cmuxAcpmuxDebug?: { chatState(): { rows?: number } } }).cmuxAcpmuxDebug?.chatState()
            .rows,
      );
      console.log(`transcript rows before the send: ${rows}`);
    }
    cdp = await page.context().newCDPSession(page);
    if (CPU > 1) await cdp.send("Emulation.setCPUThrottlingRate", { rate: CPU });
    await page.evaluate(arm, PROMPT);
    await page.waitForTimeout(300);
    if (trace) {
      traceOut = [];
      cdp.on("Tracing.dataCollected", (e) => traceOut.push(...(e.value as unknown as TraceEv[])));
      await cdp.send("Tracing.start", {
        categories:
          "devtools.timeline,disabled-by-default-devtools.timeline,disabled-by-default-devtools.timeline.stack",
        transferMode: "ReportEvents",
      });
    }
    if (profile) {
      await cdp.send("Profiler.enable");
      await cdp.send("Profiler.setSamplingInterval", { interval: 100 });
      await cdp.send("Profiler.start");
    }
    await page.keyboard.press("Enter");
    await page.waitForFunction(() => (window as unknown as { __p: Probe }).__p.paintAt > 0, null, {
      timeout: 30_000,
      polling: 50,
    });
    if (profile) {
      await page.waitForTimeout(400);
      const { profile: out } = await cdp.send("Profiler.stop");
      profileOut = out;
    }
    if (trace) {
      await page.waitForTimeout(400);
      const done = new Promise((resolve) => cdp!.once("Tracing.tracingComplete", resolve));
      await cdp.send("Tracing.end");
      await done;
    }
    // The rest of the send's motion (the rise, the follow) shows in the frames of the next second.
    await page.waitForTimeout(1200);
    const p = await page.evaluate(() => {
      const w = window as unknown as { __p: Probe; __stopFrames: () => void };
      w.__stopFrames();
      return w.__p;
    });
    const from = p.keydownTs;
    const until = from + 1200;
    const fs_ = p.frames.filter((t) => t >= from - 17 && t <= until);
    const gaps = fs_.slice(1).map((t, i) => t - fs_[i]!);
    const loaf = p.loaf.filter((l) => l.start + l.duration >= from && l.start <= until);
    const enter = p.evt.find((e) => e.name === "keydown" && Math.abs(e.start - from) < 1);
    return {
      keyToMount: p.mountAt - from,
      keyToPaint: p.paintAt - from,
      mountToPaint: p.paintAt - p.mountAt,
      enterProcessing: enter ? enter.procEnd - enter.procStart : Number.NaN,
      enterQueue: enter ? enter.procStart - enter.start : Number.NaN,
      frameMax: gaps.length ? Math.max(...gaps) : 0,
      framesOver17: gaps.filter((g) => g > 17.5).length,
      framesOver33: gaps.filter((g) => g > 34).length,
      frameCount: fs_.length,
      loafCount: loaf.length,
      loafMax: loaf.length ? Math.max(...loaf.map((l) => l.duration)) : 0,
      loafBlocking: loaf.reduce((s, l) => s + l.blocking, 0),
      scripts: loaf.flatMap((l) => l.scripts).sort((a, b) => b.dur - a.dur),
    };
  } finally {
    await cdp?.detach().catch(() => {});
    await page.close();
  }
}

type Node = { id: number; callFrame: { functionName: string; url: string; lineNumber: number }; children?: number[] };
function summarize(profile: { nodes: Node[]; samples: number[]; timeDeltas: number[] }, windowMs: [number, number]) {
  const byId = new Map(profile.nodes.map((n) => [n.id, n]));
  const parent = new Map<number, number>();
  for (const n of profile.nodes) for (const c of n.children ?? []) parent.set(c, n.id);
  const label = (n: Node) =>
    `${n.callFrame.functionName || "(anon)"} ${n.callFrame.url.split("/").pop()}:${n.callFrame.lineNumber + 1}`;
  const self = new Map<string, number>();
  const total = new Map<string, number>();
  let busy = 0;
  // Sample times (ms from the profile's start); t0 is the first sample inside the Enter's keydown handler.
  const times: number[] = [];
  let acc = 0;
  for (const d of profile.timeDeltas) times.push((acc += d / 1000));
  const inKeydown = (id: number) => {
    for (let at: number | undefined = id; at !== undefined; at = parent.get(at))
      if (/^(onKeyDown|keydown|runCustomHandler)$/.test(byId.get(at)!.callFrame.functionName)) return true;
    return false;
  };
  const k = profile.samples.findIndex(inKeydown);
  const t0 = k >= 0 ? times[k]! : 0;
  profile.samples.forEach((id, i) => {
    const dt = (profile.timeDeltas[i + 1] ?? profile.timeDeltas[i] ?? 0) / 1000;
    const rel = times[i]! - t0;
    if (rel < windowMs[0] - 1 || rel > windowMs[1]) return;
    const n = byId.get(id)!;
    if (["(idle)", "(program)", "(garbage collector)"].includes(n.callFrame.functionName)) {
      if (n.callFrame.functionName !== "(idle)") busy += dt;
      if (n.callFrame.functionName === "(garbage collector)") self.set("(gc)", (self.get("(gc)") ?? 0) + dt);
      return;
    }
    busy += dt;
    self.set(label(n), (self.get(label(n)) ?? 0) + dt);
    const seen = new Set<string>();
    for (let at: number | undefined = id; at !== undefined; at = parent.get(at)) {
      const l = label(byId.get(at)!);
      if (seen.has(l)) continue;
      seen.add(l);
      total.set(l, (total.get(l) ?? 0) + dt);
    }
  });
  const top = (m: Map<string, number>, k: number) =>
    [...m.entries()]
      .sort((a, b) => b[1] - a[1])
      .slice(0, k)
      .map(([l, ms]) => `${ms.toFixed(1).padStart(7)} ms  ${l}`);
  return { busy, self: top(self, 25), total: top(total, 45) };
}

const q = (values: number[], at: number) => {
  const s = values.filter((v) => Number.isFinite(v)).sort((a, b) => a - b);
  if (!s.length) return Number.NaN;
  return s[Math.min(s.length - 1, Math.max(0, Math.ceil(at * s.length) - 1))]!;
};

if (import.meta.main) {
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
          params?: { _meta?: { acpmux?: { promptId?: string } } };
        };
        if (message.method === "session/prompt" && message.id !== undefined) {
          const promptId = message.params?._meta?.acpmux?.promptId;
          status = "running";
          const emit = (kind: string, msg: Record<string, unknown>) =>
            ws.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: record("mux", kind, msg) }));
          emit("user_message", { text: PROMPT, ...(promptId ? { promptId } : {}) });
          emit("turn_started", {});
          ws.send(
            JSON.stringify({
              jsonrpc: "2.0",
              method: "_acpmux/session_changed",
              params: { sessionId: SESSION, session: summary(), kind: "status", seq: events.length },
            }),
          );
          return;
        }
        if (message.id !== undefined)
          ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method) }));
      },
    },
  });
  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "send-paint-probe-"));
  const { build } = await import("vite");
  await build({
    configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
    build: { outDir: out, emptyOutDir: true, minify: MINIFY },
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
  const url = `http://127.0.0.1:${statics.port}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&session=${SESSION}`;
  const browser = await chromium.launch({ headless: true });
  const rounds: Round[] = [];
  try {
    // One warm-up round, not counted (the first page pays the browser's cold caches).
    await round(browser, url, false);
    for (let i = 0; i < ROUNDS; i++) {
      const r = await round(browser, url, false);
      rounds.push(r);
      console.log(
        `round ${i + 1}: key->mount ${r.keyToMount.toFixed(1)} key->paint ${r.keyToPaint.toFixed(1)} enterProc ${r.enterProcessing} frameMax ${r.frameMax.toFixed(1)} >17 ${r.framesOver17} loafMax ${r.loafMax.toFixed(0)} blocking ${r.loafBlocking.toFixed(0)} top ${r.scripts
          .slice(0, 3)
          .map((s) => `${s.fn}@${s.src}=${s.dur.toFixed(0)}`)
          .join(", ")}`,
      );
    }
    if (TRACE) {
      await round(browser, url, false, true);
      const key = traceOut.find((e) => e.name === "EventDispatch" && e.args?.data?.type === "keydown" && e.ph === "X");
      const task =
        key &&
        traceOut.find(
          (e) =>
            e.name === "RunTask" &&
            e.ph === "X" &&
            e.tid === key.tid &&
            e.ts <= key.ts &&
            e.ts + (e.dur ?? 0) >= key.ts,
        );
      if (task) {
        const inTask = traceOut.filter(
          (e) => e.tid === task.tid && e.ph === "X" && e.ts >= task.ts && e.ts <= task.ts + task.dur!,
        );
        console.log(`trace: the Enter's task ${(task.dur! / 1000).toFixed(1)} ms`);
        for (const e of inTask.filter((e) =>
          ["Layout", "UpdateLayoutTree", "RecalculateStyles", "Paint", "PrePaint"].includes(e.name),
        )) {
          const st = e.args?.beginData?.stackTrace ?? e.args?.data?.stackTrace ?? [];
          console.log(
            `  ${e.name.padEnd(17)} at +${((e.ts - task.ts) / 1000).toFixed(1).padStart(6)} ms  ${((e.dur ?? 0) / 1000).toFixed(1).padStart(6)} ms  ${st
              .slice(0, 3)
              .map((f) => `${f.functionName || "(anon)"}:${f.lineNumber + 1}`)
              .join(" < ")}`,
          );
        }
        const next = traceOut.filter(
          (e) =>
            e.tid === task.tid &&
            e.ph === "X" &&
            e.ts > task.ts + task.dur! &&
            e.ts < task.ts + task.dur! + 150_000 &&
            ["Layout", "UpdateLayoutTree", "Paint"].includes(e.name),
        );
        console.log(
          `  then to +150 ms after the task: ${next.map((e) => `${e.name} ${((e.dur ?? 0) / 1000).toFixed(1)}`).join(", ")}`,
        );
      } else console.log("trace: no keydown task found");
    }
    if (PROFILE) {
      const r = await round(browser, url, true);
      const prof = profileOut as Parameters<typeof summarize>[0];
      for (const [name, w] of [
        ["Enter to bubble painted", [0, r.keyToPaint]],
        ["bubble painted to +300 ms", [r.keyToPaint, r.keyToPaint + 300]],
      ] as const) {
        const s = summarize(prof, [w[0], w[1]]);
        console.log(
          `profile (${name}, key->paint ${r.keyToPaint.toFixed(1)} ms): busy ${s.busy.toFixed(1)} ms\n-- self --`,
        );
        console.log(s.self.join("\n"));
        console.log("-- total (inclusive) --");
        console.log(s.total.join("\n"));
      }
    }
  } finally {
    await browser.close();
    void statics.stop(true);
    void daemon.stop(true);
    // KEEP_OUT=1 keeps the built pane, so a trace's line numbers can be read against it.
    if (process.env.KEEP_OUT === "1") console.log(`built pane kept at ${out}`);
    else fs.rmSync(out, { recursive: true, force: true });
  }
  const keys = [
    "keyToMount",
    "keyToPaint",
    "mountToPaint",
    "enterProcessing",
    "enterQueue",
    "frameMax",
    "framesOver17",
    "framesOver33",
    "loafCount",
    "loafMax",
    "loafBlocking",
  ] as const;
  console.log(`\nsend-paint-probe: history ${HISTORY} turns, cpu x${CPU}, ${rounds.length} rounds, minify ${MINIFY}`);
  console.log("metric | p50 | p90 | max");
  const summaryRow: Record<string, { p50: number; p90: number; max: number }> = {};
  for (const k of keys) {
    const v = rounds.map((r) => r[k]);
    summaryRow[k] = { p50: q(v, 0.5), p90: q(v, 0.9), max: q(v, 1) };
    console.log(`${k} | ${q(v, 0.5).toFixed(1)} | ${q(v, 0.9).toFixed(1)} | ${q(v, 1).toFixed(1)}`);
  }
  const fnTotals = new Map<string, number>();
  for (const r of rounds)
    for (const s of r.scripts) fnTotals.set(`${s.fn}@${s.src}`, (fnTotals.get(`${s.fn}@${s.src}`) ?? 0) + s.dur);
  console.log("LoAF script attribution (summed over rounds, ms):");
  for (const [k, v] of [...fnTotals.entries()].sort((a, b) => b[1] - a[1]).slice(0, 10))
    console.log(`  ${(v / rounds.length).toFixed(1)} ms/round  ${k}`);
  if (JSON_OUT) fs.writeFileSync(JSON_OUT, JSON.stringify({ HISTORY, CPU, rounds, summary: summaryRow }, null, 2));
}
