// l10n-allow-file: bench fixture prompts and replies, not shipped UI.
// A chat at any length costs what an empty one does (cmuxterm-hq goals/chats-flat-at-any-length.md: "A chat at 100k
// rows, and 20 such chats open, costs at most 1.2x an empty chat in renderer CPU (idle and streaming), RSS ..."). It
// opens the production pane (a vite build of the pane's dev entry) in Chromium with --process-per-site, as the app
// gives cmux-page one renderer, on a stand-in acpmux, in four launches of their own:
//   empty x1     one chat of one turn (the smallest chat that draws a reply);
//   long x1      one chat of ROWS transcript rows (ROWS/2 turns: a question and its answer each);
//   empty xN     N (CHATS, default 20) one-turn chats, the newest shown and the rest hidden;
//   long xN      N chats of ROWS rows each, the newest shown and the rest hidden;
//   grown x1/xN  one-turn chats that then take ROWS rows live while open (GROW_BATCH records a frame), as a chat that
//                ran for days in an open tab does: an opened long chat loads only its newest page, so it cannot show
//                what keeping every streamed record costs;
// and in each, once the pages settle:
//   idle         the renderers' CPU (/proc/PID/stat utime+stime) over IDLE_S seconds of nothing, as % of one core;
//   streaming    the same while the shown chat streams a turn of TPS chunks a second for STREAM_S seconds;
//   renderer MB  the renderers' proportional set size (/proc/PID/smaps_rollup Pss) after a collection on every page.
// Rows (PERF_ROW, chat_100k_flat.*): each value per launch, each long/empty ratio at x1 and xN, and ratio_max, the
// worst of the ratios a run measured (long and grown, each over empty; CASES below): the goal's number (NOW benches
// row chat_100k_flat_ratio_max, target 1.2, the worse of ratio_max and grown_many.ratio_max). A CPU ratio is
// taken over a floor of CPU_FLOOR_PCT (default 1 % of a core) on both sides, so two near-idle readings are not a ratio
// of noise.
// HIDDEN=0 keeps every chat shown. PROFILE=DIR writes CDP CPU profiles of the long x1 and grown x1 idle and streaming
// windows.
// GROW_OPEN=1 grows the grown chats as one turn that never ends (a coordinator's: steers, replies and tool calls into a
// running turn, ten records a grown row pair, no turn_result), which a chat that sheds only at a turn's end never
// sheds (direct.ts `shedOlderHeld`, `midTurnCut`). For the case cmux#43436 left out.
// The fixture's turns are plain prose (no code blocks), so the pane's highlighter, which runs on the main thread on an
// http: page and in a worker on cmux-page:, does no work here.
//   bun bench/chat-100k-flat.bench.ts [rows=100000] [chats=20]
// Linux only (it reads /proc).
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { ServerWebSocket } from "bun";
import type { CDPSession, Page } from "playwright";
import { PAPERCUT_CHAT, papercutEvents } from "../test/support/papercutChat";
import { chromium } from "./browsers";
import { newestPage } from "./daemonPage";
import { perfRow } from "./perfRow";
import { settledAt } from "./stability";

const ROWS = Number(process.argv[2] ?? 100_000);
const CHATS = Number(process.argv[3] ?? 20);
const IDLE_S = Number(process.env.IDLE_S ?? 10);
const STREAM_S = Number(process.env.STREAM_S ?? 10);
const TPS = Number(process.env.TPS ?? 30);
const CPU_FLOOR_PCT = Number(process.env.CPU_FLOOR_PCT ?? 1);
const HIDDEN = process.env.HIDDEN !== "0";
const PROFILE = process.env.PROFILE;
const GROW_BATCH = Number(process.env.GROW_BATCH ?? 400);
const CASES = process.env.CASES ?? "all";
// A grown-many run's rows carry their own prefix: the perf cron stores them from a part of their own.
const ROW = CASES === "grown-many" ? "chat_100k_flat.grown_many" : "chat_100k_flat";
if (!["all", "main", "grown-many"].includes(CASES)) {
  console.error("chat-100k-flat: CASES is all, main or grown-many");
  process.exit(2);
}
const GROW_OPEN = process.env.GROW_OPEN === "1";
if (!Number.isInteger(ROWS) || ROWS < 2 || !Number.isInteger(CHATS) || CHATS < 2) {
  console.error("usage: bun bench/chat-100k-flat.bench.ts [rows=100000] [chats=20]");
  process.exit(2);
}
if (process.platform !== "linux") {
  console.error("chat-100k-flat: Linux only (renderer CPU and memory from /proc)");
  process.exit(2);
}
const webviews = path.resolve(import.meta.dir, "..");
const TICK_HZ = 100; // USER_HZ, the unit of /proc/PID/stat utime and stime on Linux.

type Rec = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
type Template = { events: Rec[]; session: Record<string, unknown>; turns: number };
const template = (turns: number): Template => {
  const { events, session } = papercutEvents({ turns, running: false });
  return { events: events as Rec[], session, turns };
};
const sessionId = (index: number) =>
  index === 0 ? PAPERCUT_CHAT : `0190b000-0000-7000-8000-${(0x200000 + index).toString(16).padStart(12, "0")}`;
// A page of records re-keyed from the template's chat to `id` (only what goes out is copied: one template per size).
const rekey = <T>(value: T, id: string): T =>
  id === PAPERCUT_CHAT ? value : JSON.parse(JSON.stringify(value).replaceAll(PAPERCUT_CHAT, id));

/// The renderer processes under `root` (a Chromium launch), by their command line.
function renderers(root: number): number[] {
  const children = new Map<number, number[]>();
  for (const entry of fs.readdirSync("/proc")) {
    if (!/^\d+$/.test(entry)) continue;
    try {
      const stat = fs.readFileSync(`/proc/${entry}/stat`, "utf8");
      const parent = Number(stat.slice(stat.lastIndexOf(")") + 2).split(" ")[1]);
      children.set(parent, [...(children.get(parent) ?? []), Number(entry)]);
    } catch {
      // Gone between the listing and the read.
    }
  }
  const out: number[] = [];
  const walk = (pid: number) => {
    for (const child of children.get(pid) ?? []) {
      try {
        if (fs.readFileSync(`/proc/${child}/cmdline`, "utf8").includes("--type=renderer")) out.push(child);
      } catch {
        // Gone.
      }
      walk(child);
    }
  };
  walk(root);
  return out;
}
/// utime + stime of `pids` in clock ticks (a process gone since the listing counts nothing).
function cpuTicks(pids: number[]): number {
  let ticks = 0;
  for (const pid of pids) {
    try {
      const stat = fs.readFileSync(`/proc/${pid}/stat`, "utf8");
      const fields = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
      ticks += Number(fields[11]) + Number(fields[12]);
    } catch {
      // Gone.
    }
  }
  return ticks;
}
const pssMB = (pid: number) =>
  Number(/^Pss:\s+(\d+) kB/m.exec(fs.readFileSync(`/proc/${pid}/smaps_rollup`, "utf8"))?.[1] ?? 0) / 1024;

type Launch = { name: string; idlePct: number; streamPct: number; mb: number; renderers: number };

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

try {
  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "chat-100k-flat-"));
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
      return new Response(file, { headers: pathname.endsWith(".css") ? { "cache-control": "max-age=3600" } : {} });
    },
  });
  releases.push(() => statics.stop(true));

  const small = template(1);
  const long = template(Math.floor(ROWS / 2));
  console.log(
    `chat-100k-flat: ${ROWS} rows (${long.turns} turns, ${long.events.length} records) vs 1 turn; x1 and x${CHATS}; ` +
      `idle ${IDLE_S}s, streaming ${STREAM_S}s at ${TPS}/s; ${HIDDEN ? "all but the newest chat hidden" : "every chat shown"}`,
  );

  const runLaunch = async (
    name: string,
    chat: Template,
    count: number,
    { profile, grow = 0 }: { profile?: string; grow?: number } = {},
  ): Promise<Launch> => {
    // The stand-in daemon for this launch: `count` chats of `chat`, and what streamed into each since.
    const sessions = Array.from({ length: count }, (_, index) => ({
      ...chat.session,
      sessionId: sessionId(index),
      title: `Chat ${index + 1}`,
      status: "ready",
    }));
    const streamed = new Map<string, Rec[]>();
    const sockets = new Map<string, ServerWebSocket<undefined>>();
    const recordsOf = (id: string) => {
      const extra = streamed.get(id);
      return extra?.length ? [...chat.events, ...extra] : chat.events;
    };
    const lastSeqOf = (id: string) => recordsOf(id).at(-1)?.seq ?? 0;
    const summaryOf = (id: string) => {
      const session = sessions.find((s) => s.sessionId === id) ?? sessions[0]!;
      return { ...session, lastSeq: lastSeqOf(id) };
    };
    const answer = (ws: ServerWebSocket<undefined>, method: string, params: Record<string, unknown>): unknown => {
      const id = String(params.sessionId ?? PAPERCUT_CHAT);
      switch (method) {
        case "initialize":
          return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
        case "_acpmux/watch":
          return { sessions: sessions.map((s) => summaryOf(s.sessionId)) };
        case "_acpmux/attach": {
          sockets.set(id, ws);
          const records = recordsOf(id);
          const { page, hasMore } = newestPage(records, {
            limit: Number(params.limit ?? 400),
            maxBytes: params.maxBytes,
          });
          return { session: summaryOf(id), lastSeq: lastSeqOf(id), events: rekey(page, id), hasMore };
        }
        case "_acpmux/events": {
          const records = recordsOf(id);
          if (params.promptIndex === true) {
            const before = params.beforeSeq === undefined ? Infinity : Number(params.beforeSeq);
            const prompts = records.filter((record) => record.kind === "user_message" && record.seq < before);
            return { events: rekey(prompts, id), hasMore: false, lastSeq: lastSeqOf(id) };
          }
          if (params.beforeSeq !== undefined) {
            const { page, hasMore } = newestPage(records, {
              limit: Number(params.limit ?? 400),
              beforeSeq: Number(params.beforeSeq),
              maxBytes: params.maxBytes,
            });
            return { events: rekey(page, id), hasMore, lastSeq: lastSeqOf(id) };
          }
          return { events: [], hasMore: false, lastSeq: lastSeqOf(id) };
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
            JSON.stringify({
              jsonrpc: "2.0",
              id: message.id,
              result: answer(ws, message.method, message.params ?? {}),
            }),
          );
        },
      },
    });
    const notify = (id: string, method: string, params: unknown) =>
      sockets.get(id)?.send(JSON.stringify({ jsonrpc: "2.0", method, params }));
    const emit = (id: string, dir: string, kind: string, msg: Record<string, unknown>) => {
      const list = streamed.get(id) ?? [];
      streamed.set(id, list);
      const record: Rec = { sessionId: id, seq: lastSeqOf(id) + 1, at: Date.now(), dir, kind, msg };
      list.push(record);
      notify(id, "_acpmux/event", record);
    };
    const setStatus = (id: string, status: string) => {
      const session = sessions.find((s) => s.sessionId === id)!;
      session.status = status;
      notify(id, "_acpmux/session_changed", {
        sessionId: id,
        session: summaryOf(id),
        kind: "status",
        seq: lastSeqOf(id),
      });
    };

    const server = await chromium.launchServer({
      headless: true,
      args: ["--process-per-site", "--js-flags=--expose-gc"],
    });
    const root = server.process().pid!;
    const browser = await chromium.connect(server.wsEndpoint());
    const context = await browser.newContext({ viewport: { width: 1200, height: 800 } });
    try {
      const origin = `http://127.0.0.1:${statics.port}`;
      const urlFor = (index: number) =>
        `${origin}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&session=${sessionId(index)}`;
      const firstText = `Answer ${chat.turns}:`;
      const pages: { page: Page; cdp: CDPSession }[] = [];
      for (let index = 0; index < count; index++) {
        const page = await context.newPage();
        await page.goto(urlFor(index));
        await page.waitForFunction((text) => document.body.textContent?.includes(text), firstText, {
          timeout: 180_000,
          polling: "raf",
        });
        pages.push({ page, cdp: await context.newCDPSession(page) });
      }
      if (grow > 0) {
        // Grown: each chat takes `grow` finished turns live, GROW_BATCH records at a time, a frame apart.
        const began = performance.now();
        for (let turn = 1, batch = 0; turn <= grow; turn++) {
          for (let index = 0; index < count && GROW_OPEN; index++) {
            const id = sessionId(index);
            const said = (sessionUpdate: string, fields: Record<string, unknown>) =>
              emit(id, "in", sessionUpdate, {
                method: "session/update",
                params: { sessionId: "agent-1", update: { sessionUpdate, ...fields } },
              });
            if (turn === 1) {
              emit(id, "mux", "user_message", { text: "Grown question: coordinate the lanes" });
              emit(id, "mux", "turn_started", {});
            }
            emit(id, "mux", "user_message", { text: `Grown steer ${turn}`, steer: true });
            for (let chunk = 0; chunk < 7; chunk++)
              said("agent_message_chunk", {
                messageId: `grown-${turn}`,
                content: {
                  type: "text",
                  text: chunk === 0 ? `Grown answer ${turn}: ` : `the checks are green ${chunk}. `,
                },
              });
            said("tool_call", {
              toolCallId: `grown-call-${turn}`,
              kind: "execute",
              title: `check ${turn}`,
              status: "in_progress",
            });
            said("tool_call_update", {
              toolCallId: `grown-call-${turn}`,
              status: "completed",
              content: [{ type: "content", content: { type: "text", text: `ok ${turn}` } }],
            });
            batch += 10;
          }
          for (let index = 0; index < count && !GROW_OPEN; index++) {
            const id = sessionId(index);
            emit(id, "mux", "user_message", { text: `Grown question ${turn}` });
            emit(id, "mux", "turn_started", {});
            emit(id, "in", "agent_message_chunk", {
              method: "session/update",
              params: {
                sessionId: "agent-1",
                update: {
                  sessionUpdate: "agent_message_chunk",
                  content: { type: "text", text: `Grown answer ${turn}: the checks on the merged head are green.` },
                },
              },
            });
            emit(id, "mux", "turn_result", { status: "completed" });
            batch += 4;
          }
          if (batch >= GROW_BATCH) {
            batch = 0;
            // fixed-wait: one frame between batches, so the pages apply them as they would a fast stream.
            await Bun.sleep(16);
          }
        }
        const lastText = `Grown answer ${grow}:`;
        for (const { page } of pages)
          await page.waitForFunction((text) => document.body.textContent?.includes(text), lastText, {
            timeout: 900_000,
            polling: 1000,
          });
        console.log(
          `  ${name}: grew ${grow} turns a chat live in ${((performance.now() - began) / 1000).toFixed(1)} s`,
        );
      }
      // The pages' own settling (read-ahead, fonts, the first paints) is not idle.
      await new Promise((resolve) => setTimeout(resolve, 3000));
      for (const { page } of pages) await settledAt(page).catch(() => undefined);
      if (HIDDEN) {
        // A chat tab that is not shown: its document turns hidden, as CEF's WasHidden makes it in the app.
        for (const { page } of pages.slice(0, -1))
          await page.evaluate(() => {
            Object.defineProperty(document, "visibilityState", { configurable: true, get: () => "hidden" });
            Object.defineProperty(document, "hidden", { configurable: true, get: () => true });
            document.dispatchEvent(new Event("visibilitychange"));
          });
        await new Promise((resolve) => setTimeout(resolve, 2000));
      }
      const window = async (seconds: number, during?: () => Promise<void>) => {
        const pids = renderers(root);
        const from = cpuTicks(pids);
        const began = performance.now();
        if (during) await during();
        else await new Promise((resolve) => setTimeout(resolve, seconds * 1000));
        const elapsed = (performance.now() - began) / 1000;
        return ((cpuTicks(pids) - from) / TICK_HZ / elapsed) * 100;
      };
      const shownProfiler = pages.at(-1)!.cdp;
      if (profile) {
        await shownProfiler.send("Profiler.enable");
        await shownProfiler.send("Profiler.start");
      }
      const idlePct = await window(IDLE_S);
      if (profile) {
        const { profile: cpu } = (await shownProfiler.send("Profiler.stop")) as { profile: unknown };
        fs.mkdirSync(profile, { recursive: true });
        fs.writeFileSync(path.join(profile, `${name}-idle.cpuprofile`), JSON.stringify(cpu));
      }
      // Streaming: the shown chat (the newest) runs a turn whose reply arrives TPS chunks a second.
      const shown = sessionId(count - 1);
      const shownCdp = pages.at(-1)!.cdp;
      emit(shown, "mux", "user_message", { text: "Stream a reply" });
      emit(shown, "mux", "turn_started", {});
      setStatus(shown, "running");
      await new Promise((resolve) => setTimeout(resolve, 300));
      if (profile) {
        await shownCdp.send("Profiler.enable");
        await shownCdp.send("Profiler.start");
      }
      let sent = 0;
      const streamPct = await window(STREAM_S, async () => {
        const began = performance.now();
        const total = Math.ceil(TPS * STREAM_S);
        while (sent < total) {
          const due = Math.min(total, Math.floor(((performance.now() - began) / 1000) * TPS) + 1);
          for (; sent < due; sent++)
            emit(shown, "in", "agent_message_chunk", {
              method: "session/update",
              params: {
                sessionId: "agent-1",
                update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: `word${sent} ` } },
              },
            });
          // fixed-wait: the wall-clock pacing of the stream itself.
          await Bun.sleep(5);
        }
      });
      if (profile) {
        const { profile: cpu } = (await shownCdp.send("Profiler.stop")) as { profile: unknown };
        fs.mkdirSync(profile, { recursive: true });
        const file = path.join(profile, `${name}-streaming.cpuprofile`);
        fs.writeFileSync(file, JSON.stringify(cpu));
        console.log(`chat-100k-flat: CPU profile of ${name} streaming: ${file}`);
      }
      emit(shown, "mux", "turn_result", { status: "completed" });
      setStatus(shown, "ready");
      await new Promise((resolve) => setTimeout(resolve, 1000));
      for (const { cdp } of pages) await cdp.send("HeapProfiler.collectGarbage");
      await new Promise((resolve) => setTimeout(resolve, 1500));
      const pids = renderers(root);
      const mb = pids.reduce((sum, pid) => sum + pssMB(pid), 0);
      const row: Launch = { name, idlePct, streamPct, mb, renderers: pids.length };
      console.log(`${name} | ${row.renderers} | ${idlePct.toFixed(2)} | ${streamPct.toFixed(2)} | ${mb.toFixed(1)}`);
      perfRow({ name: `${ROW}.${name}.idle_cpu_pct`, p50: idlePct, p95: idlePct, unit: "pct", clock: "cpu" });
      perfRow({
        name: `${ROW}.${name}.stream_cpu_pct`,
        p50: streamPct,
        p95: streamPct,
        unit: "pct",
        clock: "cpu",
      });
      perfRow({ name: `${ROW}.${name}.renderer_mb`, p50: mb, p95: mb, unit: "MB" });
      return row;
    } finally {
      await context.close().catch(() => undefined);
      await server.close().catch(() => undefined);
      await daemon.stop(true);
    }
  };

  console.log("launch | renderers | idle CPU % | streaming CPU % | renderer MB");
  // CASES=main runs every case but grown xN; CASES=grown-many runs only empty xN and grown xN (20 chats taking 100k rows
  // each live takes about 28 minutes on a 4-vCPU runner, so the perf cron runs it as a part of its own); CASES=all
  // runs every case. The grown-many max is chat_100k_flat.grown_many.ratio_max, and the goal reads the worse of the two.
  const pairs: [string, Launch, Launch][] = [];
  if (CASES !== "grown-many") {
    const emptyOne = await runLaunch("empty_x1", small, 1);
    const longOne = await runLaunch("long_x1", long, 1, { profile: PROFILE });
    const grownOne = await runLaunch("grown_x1", small, 1, { profile: PROFILE, grow: long.turns });
    pairs.push(["long_x1", longOne, emptyOne], ["grown_x1", grownOne, emptyOne]);
  }
  const emptyMany = await runLaunch(`empty_x${CHATS}`, small, CHATS);
  if (CASES !== "grown-many") pairs.push([`long_x${CHATS}`, await runLaunch(`long_x${CHATS}`, long, CHATS), emptyMany]);
  if (CASES !== "main")
    pairs.push([`grown_x${CHATS}`, await runLaunch(`grown_x${CHATS}`, small, CHATS, { grow: long.turns }), emptyMany]);
  const cpuRatio = (a: number, b: number) => Math.max(a, CPU_FLOOR_PCT) / Math.max(b, CPU_FLOOR_PCT);
  const ratios: [string, number][] = [];
  for (const [label, big, base] of pairs) {
    ratios.push([`${label}.idle_cpu_ratio`, cpuRatio(big.idlePct, base.idlePct)]);
    ratios.push([`${label}.stream_cpu_ratio`, cpuRatio(big.streamPct, base.streamPct)]);
    ratios.push([`${label}.renderer_mb_ratio`, big.mb / base.mb]);
  }
  for (const [name, value] of ratios) {
    console.log(`chat-100k-flat: ${name} ${value.toFixed(2)}x`);
    perfRow({ name: `${ROW}.${name}`, p50: value, p95: value, unit: "x", target: 1.2, floor: 0.05 });
  }
  const [worst, max] = ratios.reduce((a, b) => (b[1] > a[1] ? b : a));
  console.log(`chat-100k-flat: worst ratio ${max.toFixed(2)}x (${worst}); target 1.2x`);
  const maxRow = `${ROW}.ratio_max`;
  perfRow({ name: maxRow, p50: max, p95: max, unit: "x", target: 1.2, floor: 0.05 });
} finally {
  await release();
}
