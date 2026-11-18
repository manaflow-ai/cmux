// l10n-allow-file: benchmark output, not shipped UI.
// An agent UI surface streaming into a long chat (plans/cmux-next/agent-ui-surfaces-DESIGN.md, "Streaming and
// frames"): what the pane's frames cost while one surface card takes 40 updates at about 60 Hz, against the same
// transcript taking the same 40 tool-call updates without a surface. The real pane (a vite build of
// vite.config.acpmux-pane.mjs, as tool-call-burst.bench.ts builds it) joins a stand-in acpmux that answers
// initialize, `_acpmux/watch`, `_acpmux/attach` and `_acpmux/events`; the chat is `--turns` finished turns
// (loadFixture.ts, about 6 rows each: 250 turns is about 1,500 rows), then a running turn. Labs
// `labs.agentUiSurfaces` is on in both arms (`cmuxAcpmuxBridge.applyAgentUiSurfaces(true)`).
// Arms, alternating, `--rounds` each, each in a fresh page:
//   with      a tool call whose updates carry `_meta.acpmux.uiSurface` (cmux.ui-surface/1, as Rust emits it): Rust's
//             golden `cmux-catalog-cards` (approval, table, charts, progress...) growing a node every few updates
//             while `streaming`, its progress moving, `ready` on the last (uiSurfaceStreamFixture.ts, the fixture the
//             live pane's golden.py `ui_surface_stream` streams too)
//   without   the same tool call and the same 40 updates, with no surface
// Rows: ui_surface_stream.<arm>.frame_gap_ms p50 / p95 / max (rAF intervals from the first update to 200 ms after
// the last), .frames_over_16ms (count), .long_tasks (> 50 ms), .cls (layout shift). Headless Chromium has no real
// display refresh, so its rAF cadence is the compositor's own; compare arms, not absolute numbers with a Mac.
//   bun bench/ui-surface-stream-frames.bench.ts [--turns 250] [--updates 40] [--hz 60] [--rounds 3]
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium } from "./browsers";
import type { Browser, Page } from "playwright";
import type { EventRecord } from "../src/agent-session/acpmux/direct";
import { loadTurn } from "../src/agent-session/acpmux/loadFixture";
import {
  UI_SURFACE_STREAM_CALL,
  UI_SURFACE_STREAM_HZ,
  UI_SURFACE_STREAM_TITLE,
  UI_SURFACE_STREAM_UPDATES,
  uiSurfaceStreamAt,
} from "../src/agent-session/acpmux/uiSurfaceStreamFixture";
import { perfRow } from "./perfRow";
import { toRecord, type Step } from "./replayLogs";

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : undefined;
};
const TURNS = Number(flag("--turns") ?? 250);
const UPDATES = Number(flag("--updates") ?? UI_SURFACE_STREAM_UPDATES);
const HZ = Number(flag("--hz") ?? UI_SURFACE_STREAM_HZ);
const ROUNDS = Number(flag("--rounds") ?? 3);
const webviews = path.resolve(import.meta.dir, "..");
const sessionId = "ui-surface-stream";
const CALL = UI_SURFACE_STREAM_CALL;

/// The chat before the stream: `TURNS` finished turns, then the running turn's prompt and a line of reply.
function prefix(start: number): EventRecord[] {
  const events: EventRecord[] = [];
  const push = (at: number, step: Step) => events.push(toRecord(sessionId, events.length + 1, at, step));
  for (let turn = 0; turn < TURNS; turn += 1)
    for (const step of loadTurn(turn)) push(start + turn * 60_000, step as Step);
  const at = start + TURNS * 60_000;
  push(at, { mux: "user_message", msg: { text: "Show the release status." } });
  push(at, { mux: "turn_started" });
  push(at + 500, {
    update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Here's where it stands." } },
  });
  return events;
}

function updateStep(index: number, withSurface: boolean): Step {
  return {
    update: {
      sessionUpdate: index === 0 ? "tool_call" : "tool_call_update",
      toolCallId: CALL,
      ...(index === 0 ? { kind: "other", title: UI_SURFACE_STREAM_TITLE } : {}),
      status: index === UPDATES - 1 ? "completed" : "in_progress",
      // The shared golden stream (uiSurfaceStreamFixture.ts), as the live pane's golden.py `ui_surface_stream` plays it.
      ...(withSurface ? { _meta: { acpmux: { uiSurface: uiSurfaceStreamAt(index, UPDATES) } } } : {}),
    },
  };
}

// ---------- the stand-in acpmux ----------
type Play = { events: EventRecord[]; served: number; socket?: { send(data: string): void } };
let play: Play | undefined;
const summary = (p: Play) => ({
  sessionId,
  cwd: "/mock/project",
  title: "UI surface stream",
  harness: "claude",
  name: "claude",
  status: "running",
  steering: true,
  queuePaused: false,
  queued: 0,
  queue: [],
  turnCount: TURNS + 1,
  updatedAt: p.events.at(-1)?.at ?? Date.now(),
});
function answer(method: string): unknown {
  const p = play!;
  switch (method) {
    case "initialize":
      return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
    case "_acpmux/watch":
      return { sessions: [summary(p)] };
    case "_acpmux/attach":
      return { session: summary(p), lastSeq: p.served, events: p.events.slice(0, p.served) };
    case "_acpmux/events":
      return { events: [], hasMore: false, lastSeq: p.served };
    default:
      return null;
  }
}
const emit = (event: EventRecord) =>
  play?.socket?.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }));

// ---------- the page side ----------
/** Init script: frame times, long tasks and layout shifts. Self-contained. */
function instrument() {
  const w = window as unknown as {
    __frames: number[];
    __long: { at: number; ms: number }[];
    __shifts: { at: number; value: number }[];
  };
  if (w.__frames) return;
  w.__frames = [];
  w.__long = [];
  w.__shifts = [];
  const frame = (at: number) => {
    w.__frames.push(at);
    requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);
  try {
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) w.__long.push({ at: entry.startTime, ms: entry.duration });
    }).observe({ type: "longtask", buffered: true });
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries() as unknown as {
        startTime: number;
        value: number;
        hadRecentInput: boolean;
      }[])
        if (!entry.hadRecentInput) w.__shifts.push({ at: entry.startTime, value: entry.value });
    }).observe({ type: "layout-shift", buffered: true });
  } catch {
    // An engine without them reads 0.
  }
}

const percentile = (values: number[], p: number) => {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted.length ? sorted[Math.min(sorted.length - 1, Math.round((sorted.length - 1) * p))]! : 0;
};
const r1 = (value: number) => Math.round(value * 10) / 10;

type Round = {
  frameP50: number;
  frameP95: number;
  frameMax: number;
  over16: number;
  frames: number;
  longTasks: number;
  longestTask: number;
  cls: number;
  cardDrawn: boolean;
};

async function round(browser: Browser, url: string, withSurface: boolean): Promise<Round> {
  const start = Date.now() - (TURNS + 1) * 60_000;
  const events = prefix(start);
  play = { events, served: events.length };
  const page: Page = await browser.newPage({ viewport: { width: 900, height: 700 } });
  try {
    await page.addInitScript(instrument);
    await page.goto(url);
    await page.locator("[data-row-id]").first().waitFor({ timeout: 60_000 });
    await page.waitForFunction(() => !!(window as { cmuxAcpmuxBridge?: unknown }).cmuxAcpmuxBridge, null, {
      timeout: 60_000,
    });
    await page.evaluate(() =>
      (
        window as unknown as { cmuxAcpmuxBridge: { applyAgentUiSurfaces?(on: boolean): void } }
      ).cmuxAcpmuxBridge.applyAgentUiSurfaces?.(true),
    );
    for (let tries = 0; !play.socket && tries < 600; tries++) await Bun.sleep(20); // fixed-wait: polls the stand-in daemon's own state, not the page
    if (!play.socket) throw new Error("the pane never attached");
    // fixed-wait: lets the attach's first paint and its follow-up page loads settle, as tool-call-burst does.
    await page.waitForTimeout(1500);
    const since = await page.evaluate(() => performance.now());
    const gap = 1000 / HZ;
    const t0 = performance.now();
    for (let index = 0; index < UPDATES; index += 1) {
      const wait = t0 + index * gap - performance.now();
      if (wait > 0) await Bun.sleep(wait); // fixed-wait: paces the stream on the wall clock (the behavior under test)
      const record = toRecord(sessionId, play.served + 1, Date.now(), updateStep(index, withSurface));
      play.events.push(record);
      play.served += 1;
      emit(record);
    }
    // fixed-wait: the frames after the last update are part of the measured window.
    await page.waitForTimeout(400);
    const cardDrawn = (await page.locator(".uis-card").count()) > 0;
    const data = await page.evaluate(() => {
      const w = window as unknown as {
        __frames: number[];
        __long: { at: number; ms: number }[];
        __shifts: { at: number; value: number }[];
      };
      return { frames: w.__frames, long: w.__long, shifts: w.__shifts, now: performance.now() };
    });
    const until = since + UPDATES * gap + 200;
    const frames = data.frames.filter((at) => at >= since && at <= until);
    const gaps = frames.slice(1).map((at, index) => at - frames[index]!);
    const long = data.long.filter((task) => task.at >= since && task.at <= until);
    return {
      frameP50: r1(percentile(gaps, 0.5)),
      frameP95: r1(percentile(gaps, 0.95)),
      frameMax: r1(Math.max(0, ...gaps)),
      over16: gaps.filter((value) => value > 16.7).length,
      frames: gaps.length,
      longTasks: long.length,
      longestTask: Math.round(Math.max(0, ...long.map((task) => task.ms))),
      cls:
        Math.round(
          data.shifts.filter((s) => s.at >= since && s.at <= until).reduce((sum, s) => sum + s.value, 0) * 1e4,
        ) / 1e4,
      cardDrawn,
    };
  } finally {
    await page.close();
  }
}

if (import.meta.main) {
  const releases: (() => unknown)[] = [];
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
          if (message.method === "_acpmux/attach" && play) play.socket = ws;
          if (message.id !== undefined)
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method) }));
        },
      },
    });
    releases.push(() => daemon.stop(true));
    const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "ui-surface-stream-bench-"));
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
    const url = `http://127.0.0.1:${statics.port}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&session=${sessionId}`;
    const arms = { with: [] as Round[], without: [] as Round[] };
    for (let index = 0; index < ROUNDS; index += 1)
      for (const arm of ["without", "with"] as const) arms[arm].push(await round(browser, url, arm === "with"));
    const records = prefix(Date.now()).length;
    for (const arm of ["without", "with"] as const) {
      const rounds = arms[arm];
      console.log(
        `ui-surface-stream: ${arm} (${UPDATES} updates at ${HZ} Hz, ${TURNS} turns / ${records} records before) ` +
          rounds
            .map(
              (r) =>
                `[frame p50 ${r.frameP50} p95 ${r.frameP95} max ${r.frameMax} | >16.7ms ${r.over16}/${r.frames} | ` +
                `long ${r.longTasks} (${r.longestTask} ms) | cls ${r.cls}${arm === "with" ? ` | card ${r.cardDrawn}` : ""}]`,
            )
            .join(" "),
      );
      const med = (pick: (r: Round) => number) => percentile(rounds.map(pick), 0.5);
      const worst = (pick: (r: Round) => number) => Math.max(...rounds.map(pick));
      const name = `ui_surface_stream.${arm}`;
      perfRow({ name: `${name}.frame_gap_ms`, p50: med((r) => r.frameP50), p95: med((r) => r.frameP95), target: 16.7 });
      perfRow({ name: `${name}.frame_gap_max_ms`, p50: med((r) => r.frameMax), p95: worst((r) => r.frameMax) });
      perfRow({
        name: `${name}.frames_over_16ms`,
        p50: med((r) => r.over16),
        p95: worst((r) => r.over16),
        unit: "count",
        target: 0,
      });
      perfRow({
        name: `${name}.long_tasks`,
        p50: med((r) => r.longTasks),
        p95: worst((r) => r.longTasks),
        unit: "count",
        target: 0,
      });
      perfRow({ name: `${name}.cls`, p50: med((r) => r.cls), p95: worst((r) => r.cls), unit: "score", target: 0.01 });
    }
    if (arms.with.some((r) => !r.cardDrawn))
      console.log("ui-surface-stream: WARNING the surface card never drew in a `with` round");
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
