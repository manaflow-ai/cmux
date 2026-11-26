// l10n-allow-file: bench output labels, not shipped UI.
// One orchestrator chat supervising 16 sub-sessions while all of them stream (cmuxterm-hq RFD 0167 row 12, goal
// competitive-orchestrator-16; Leo, 2026-11-24: "i never only want top x changes. you all need to be working through all
// useful ones end to end to end." and "go even further beyond"). The bar is a UI frame: no frame of the orchestrator's
// pane may take longer than 16 ms (p99) while its 16 children stream.
//
// The production pane (a vite build of the pane's dev entry, as coord-sim-load.bench.ts builds it) runs in Chromium on
// a stand-in acpmux. The stand-in serves one parent chat in a running turn and CHILDREN sub-sessions it started
// (`startedBy`, as hub/subsessions.rs lists them): half on this machine in their own worktree (`hostKind: local`,
// `worktree`, `branch`), half on Cloud machines (`hostKind: cloud`, `host`), so the pane draws both places at once.
// While the window runs:
//   parent    streams its coordinator turn: reply chunks, thoughts and tool calls (start, wait, send) at PARENT_RATE/s;
//   children  each streams its own turn (chunks and tool calls, to any page attached to it) at CHILD_RATE/s, and
//             acpmux's `_acpmux/session_changed` for it (the doing line: plan step and latest tool, its queue) at
//             CHANGE_RATE/s, which is what the parent's Subagents tray and sub-session cards redraw from.
// A frame's time is its work: from its animation frame callback until the page rendered it (a message posted in the
// callback runs after the rendering update: script, style, layout, paint), as composer-typing.bench.ts's frameWork
// probe reads it, on Chromium's own 60 Hz. Every frame over SECONDS is a sample. The frame intervals count the frames
// dropped against 60 Hz (an interval over 1.5 frames), which is where work between frames (the socket's messages, a
// React commit in a task) shows. With the frame limit off (UNTHROTTLED=1) the intervals are not a frame's cost: an
// idle page there still waits ~17 ms once every few dozen frames.
// Rows (PERF_ROW, webui.<name> in the perf cron):
//   orchestrator.c<N>.frame_ms         p50/p95 of every frame's work while all stream
//   orchestrator.c<N>.frame_ms_p99     the p99 (as p50 and p95): NOW's competitive.orchestrator.p99_frame_ms_16_children
//   orchestrator.c<N>.frames_over_16ms count of frames whose work is over 16 ms (the goal's bar)
//   orchestrator.c<N>.dropped_frames   frames dropped against 60 Hz while all stream
//   orchestrator.c<N>.idle_frame_ms_p99 the same page with nothing streaming: the fixed floor of a frame here
//   orchestrator.c<N>.long_task_ms     the long tasks' sum over the window
// Raw: RUN_DIR (ORCH_RUN_DIR, default a temp dir)/orchestrator-c<N>/summary.json and frames.json.
//   bun bench/orchestrator-16.bench.ts [children=16] [seconds=30]
// Env: PARENT_RATE (default 20), CHILD_RATE (default 8), CHANGE_RATE (default 2), HISTORY (default 2000), CLOUD (how
// many children are on Cloud, default half), UNTHROTTLED=1 turns the frame limit off.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { ServerWebSocket } from "bun";
import { chromium } from "./browsers";
import { newestPage } from "./daemonPage";
import { perfRow, TARGET_MS } from "./perfRow";

const CHILDREN = Number(process.argv[2] ?? 16);
const SECONDS = Number(process.argv[3] ?? 30);
const IDLE_SECONDS = Number(process.env.IDLE_SECONDS ?? 5);
const PARENT_RATE = Number(process.env.PARENT_RATE ?? 20);
const CHILD_RATE = Number(process.env.CHILD_RATE ?? 8);
const CHANGE_RATE = Number(process.env.CHANGE_RATE ?? 2);
const HISTORY = Number(process.env.HISTORY ?? 2000);
const CLOUD = Math.min(CHILDREN, Number(process.env.CLOUD ?? Math.floor(CHILDREN / 2)));
const UNTHROTTLED = process.env.UNTHROTTLED === "1";
const FRAME_MS = 1000 / 60;
/// The goal's bar: a frame that takes longer than this is over.
const FRAME_BAR_MS = 16;
if (!(CHILDREN >= 1 && SECONDS > 0)) {
  console.error("usage: bun bench/orchestrator-16.bench.ts [children=16] [seconds=30]");
  process.exit(2);
}
const webviews = path.resolve(import.meta.dir, "..");
const TAG = `c${CHILDREN}`;
const ROW = `orchestrator.${TAG}`;

type Rec = {
  sessionId: string;
  seq: number;
  at: number;
  dir: string;
  kind: string;
  msg: Record<string, unknown>;
};
const pct = (values: number[], p: number) => {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted.length ? sorted[Math.min(sorted.length - 1, Math.round((sorted.length - 1) * p))]! : 0;
};

// Filler text: words that read like a coordinator's and a worker's, no transcript.
const WORDS =
  "the build check worktree child lane test merge patch cloud local wait steer cancel status report frame sidebar tray read edit run cargo bun file diff branch review".split(
    " ",
  );
let rng = 1;
const rand = () => {
  rng = (rng * 1103515245 + 12345) & 0x7fffffff;
  return rng / 0x7fffffff;
};
const words = (n: number) => Array.from({ length: n }, () => WORDS[Math.floor(rand() * WORDS.length)]).join(" ");

const PARENT = "orch-0000-0000-0000-000000000000";
const childId = (i: number) => `orch-child-${String(i).padStart(4, "0")}-0000-000000000000`;
const childName = (i: number) => `child-${String(i + 1).padStart(2, "0")}`;
const seqs = new Map<string, number>();
const nextSeq = (id: string) => {
  const seq = (seqs.get(id) ?? 0) + 1;
  seqs.set(id, seq);
  return seq;
};
const update = (
  sessionId: string,
  kind: string,
  body: Record<string, unknown>,
  meta?: Record<string, unknown>,
): Rec => ({
  sessionId,
  seq: nextSeq(sessionId),
  at: Date.now(),
  dir: "in",
  kind,
  msg: {
    jsonrpc: "2.0",
    method: "session/update",
    params: {
      ...(meta ? { _meta: meta } : {}),
      sessionId,
      update: { ...body, sessionUpdate: kind },
    },
  },
});
const mux = (sessionId: string, kind: string, msg: Record<string, unknown>): Rec => ({
  sessionId,
  seq: nextSeq(sessionId),
  at: Date.now(),
  dir: "mux",
  kind,
  msg,
});
let toolN = 0;
let msgN = 0;
/// One step of a turn: a reply chunk, a thought, or a tool call and its result (two records).
function turnStep(sessionId: string, turnId: string, tools: string[]): Rec[] {
  const r = rand();
  if (r < 0.5)
    return [
      update(
        sessionId,
        "agent_message_chunk",
        {
          content: { type: "text", text: `${words(6 + Math.floor(rand() * 10))} ` },
          messageId: `msg-${turnId}`,
        },
        { acpmux: { segment: `${turnId}.${msgN++ % 8}` } },
      ),
    ];
  if (r < 0.65) return [update(sessionId, "agent_thought_chunk", { content: { type: "text", text: `${words(8)} ` } })];
  const id = `toolu_${++toolN}`;
  const tool = tools[Math.floor(rand() * tools.length)]!;
  return [
    update(sessionId, "tool_call", {
      toolCallId: id,
      title: `${tool} ${words(3)}`,
      kind: tool === "Bash" ? "execute" : tool === "Edit" ? "edit" : tool === "Read" ? "read" : "other",
      status: "in_progress",
      rawInput: { command: words(5), description: words(4) },
      _meta: { claude: { tool } },
    }),
    update(sessionId, "tool_call_update", {
      toolCallId: id,
      status: "completed",
      content: [{ type: "content", content: { type: "text", text: words(20 + Math.floor(rand() * 40)) } }],
    }),
  ];
}
const PARENT_TOOLS = [
  "mcp__cmux-subsessions__wait_for_sessions",
  "mcp__cmux-subsessions__get_session",
  "mcp__cmux-subsessions__send_message",
  "mcp__cmux-subsessions__list_sessions",
  "Bash",
];
const CHILD_TOOLS = ["Bash", "Read", "Edit", "Grep"];
function openTurn(sessionId: string, turnId: string, prompt: string): Rec[] {
  return [
    mux(sessionId, "user_message", {
      _meta: { origin: { actor: "person", verified: true } },
      inlineParts: [{ kind: "text", text: prompt }],
      text: prompt,
    }),
    mux(sessionId, "turn_started", { turnId }),
  ];
}

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
  process.env.ORCH_RUN_DIR ?? fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "orchestrator-run-")),
  `orchestrator-${TAG}`,
);
fs.mkdirSync(runDir, { recursive: true });
const summary: Record<string, unknown> = {
  schema: "orchestrator-frames.v1",
  children: CHILDREN,
  cloud: CLOUD,
  seconds: SECONDS,
  parentRate: PARENT_RATE,
  childRate: CHILD_RATE,
  changeRate: CHANGE_RATE,
  history: HISTORY,
  unthrottled: UNTHROTTLED,
};

try {
  // The parent's history: earlier turns, then the running one, which started every child.
  const records = new Map<string, Rec[]>();
  const parentRecs: Rec[] = [];
  let turn = 0;
  while (parentRecs.length < HISTORY) {
    const turnId = `turn-p-${++turn}`;
    parentRecs.push(...openTurn(PARENT, turnId, words(12)));
    for (let i = 0; i < 40; i++) parentRecs.push(...turnStep(PARENT, turnId, PARENT_TOOLS));
    parentRecs.push(mux(PARENT, "turn_end", { stopReason: "end_turn", turnId }));
  }
  const liveTurn = `turn-p-${++turn}`;
  parentRecs.push(
    ...openTurn(PARENT, liveTurn, `Start ${CHILDREN} sub-sessions, local and cloud, and supervise them.`),
  );
  for (let i = 0; i < CHILDREN; i++) {
    const id = `toolu_start_${i}`;
    parentRecs.push(
      update(PARENT, "tool_call", {
        toolCallId: id,
        title: "mcp__cmux-subsessions__start_session",
        kind: "other",
        status: "in_progress",
        rawInput: {
          name: childName(i),
          prompt: words(20),
          worktree: true,
          host: i < CLOUD ? "cloud" : "auto",
        },
        _meta: { claude: { tool: "mcp__cmux-subsessions__start_session" } },
      }),
      update(PARENT, "tool_call_update", {
        toolCallId: id,
        status: "completed",
        content: [
          {
            type: "content",
            content: {
              type: "text",
              text: `Created sub-session ${childName(i)} (sessionId ${childId(i)}, depth 1).`,
            },
          },
        ],
      }),
    );
  }
  records.set(PARENT, parentRecs);
  const now = Date.now();
  const sessions: Record<string, unknown>[] = [
    {
      sessionId: PARENT,
      cwd: "/home/dev/cmux",
      title: "Orchestrator",
      harness: "claude",
      family: "claude",
      status: "running",
      turnCount: turn,
      createdAt: now - 3_600_000,
      updatedAt: now,
      hostKind: "local",
      lane: { state: "working", step: "supervise sub-sessions" },
      turn: { activity: "wait_for_sessions" },
    },
  ];
  for (let i = 0; i < CHILDREN; i++) {
    const id = childId(i);
    const cloud = i < CLOUD;
    const childTurn = `turn-c${i}-1`;
    records.set(id, [...openTurn(id, childTurn, words(20))]);
    sessions.push({
      sessionId: id,
      cwd: `/home/dev/cmux-wt/${childName(i)}`,
      title: `${childName(i)}: ${words(4)}`,
      shortName: childName(i),
      harness: i % 3 === 2 ? "codex" : "claude",
      family: i % 3 === 2 ? "codex" : "claude",
      status: "running",
      turnCount: 1,
      createdAt: now - 60_000 + i,
      updatedAt: now,
      startedBy: PARENT,
      hostKind: cloud ? "cloud" : "local",
      ...(cloud ? { host: `cloud-${childName(i)}`, peer: `cloud-${childName(i)}` } : {}),
      worktree: `/home/dev/cmux-wt/${childName(i)}`,
      branch: `lane/${childName(i)}`,
      lane: { state: "working", step: words(4) },
      turn: { activity: `Bash ${words(2)}` },
    });
  }
  const turnOf = new Map(sessions.map((s, i) => [s.sessionId as string, i === 0 ? liveTurn : `turn-c${i - 1}-1`]));
  console.log(
    `orchestrator-16: 1 parent + ${CHILDREN} children (${CHILDREN - CLOUD} local worktrees, ${CLOUD} cloud), ` +
      `${HISTORY} parent records before attach, parent ${PARENT_RATE}/s, each child ${CHILD_RATE}/s and ` +
      `${CHANGE_RATE} list changes/s, ${SECONDS}s, frame limit ${UNTHROTTLED ? "off" : "60 Hz"}`,
  );

  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "orchestrator-16-"));
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

  // The stand-in daemon (coord-sim-load.bench.ts's), with the session list's changes pushed to every watcher.
  const lastSeqOf = (id: string) => records.get(id)?.at(-1)?.seq ?? 0;
  const summaryOf = (id: string) => ({
    ...(sessions.find((s) => s.sessionId === id) ?? sessions[0]!),
    lastSeq: lastSeqOf(id),
  });
  const watchers = new Map<string, Set<ServerWebSocket<undefined>>>();
  const listWatchers = new Set<ServerWebSocket<undefined>>();
  let listSeq = 1;
  const answer = (ws: ServerWebSocket<undefined>, method: string, params: Record<string, unknown>): unknown => {
    const id = String(params.sessionId ?? PARENT);
    const list = records.get(id) ?? [];
    switch (method) {
      case "initialize":
        return {
          protocolVersion: 1,
          _meta: { acpmux: { origin: "local", extensions: [], operations: [] } },
        };
      case "_acpmux/watch":
        listWatchers.add(ws);
        return { sessions: sessions.map((s) => summaryOf(s.sessionId as string)), listSeq };
      case "_acpmux/sessions":
        return { sessions: sessions.map((s) => summaryOf(s.sessionId as string)), listSeq };
      case "_acpmux/attach": {
        const set = watchers.get(id) ?? new Set();
        set.add(ws);
        watchers.set(id, set);
        const { page, hasMore } = newestPage(list, {
          limit: Number(params.limit ?? 400),
          maxBytes: params.maxBytes,
        });
        return { session: summaryOf(id), lastSeq: lastSeqOf(id), events: page, hasMore };
      }
      case "_acpmux/events": {
        if (params.promptIndex === true) {
          const before = params.beforeSeq === undefined ? Infinity : Number(params.beforeSeq);
          return {
            events: list.filter((r) => r.kind === "user_message" && r.seq < before),
            hasMore: false,
            lastSeq: lastSeqOf(id),
          };
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
        return {
          events: list.filter((r) => r.seq > after),
          hasMore: false,
          lastSeq: lastSeqOf(id),
        };
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
        const message = JSON.parse(String(raw)) as {
          id?: number;
          method: string;
          params?: Record<string, unknown>;
        };
        if (message.id === undefined) return;
        ws.send(
          JSON.stringify({
            jsonrpc: "2.0",
            id: message.id,
            result: answer(ws, message.method, message.params ?? {}),
          }),
        );
      },
      close(ws) {
        listWatchers.delete(ws);
        for (const set of watchers.values()) set.delete(ws);
      },
    },
  });
  releases.push(() => daemon.stop(true));

  // The stream: every session's turn steps and the children's list changes, each on its own clock.
  const counts = { events: 0, changes: 0 };
  const push = (rec: Rec) => {
    records.get(rec.sessionId)!.push(rec);
    counts.events += 1;
    const text = JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: rec });
    for (const ws of watchers.get(rec.sessionId) ?? []) ws.send(text);
  };
  const change = (index: number) => {
    const s = sessions[index]!;
    s.updatedAt = Date.now();
    s.lane = { state: "working", step: words(4) };
    s.turn = {
      activity: `${CHILD_TOOLS[Math.floor(rand() * CHILD_TOOLS.length)]} ${words(2)}`,
    };
    s.queued = rand() < 0.1 ? 1 : 0;
    counts.changes += 1;
    const text = JSON.stringify({
      jsonrpc: "2.0",
      method: "_acpmux/session_changed",
      params: { kind: "updated", session: summaryOf(s.sessionId as string), listSeq: ++listSeq },
    });
    for (const ws of listWatchers) ws.send(text);
  };
  let streaming = false;
  const timers: ReturnType<typeof setInterval>[] = [];
  const startStream = () => {
    streaming = true;
    timers.push(
      setInterval(() => {
        if (streaming) for (const rec of turnStep(PARENT, liveTurn, PARENT_TOOLS)) push(rec);
      }, 1000 / PARENT_RATE),
    );
    for (let i = 0; i < CHILDREN; i++) {
      const id = childId(i);
      // Staggered so the children's events spread over the frame, as real ones do.
      setTimeout(
        () => {
          timers.push(
            setInterval(() => {
              if (streaming) for (const rec of turnStep(id, turnOf.get(id)!, CHILD_TOOLS)) push(rec);
            }, 1000 / CHILD_RATE),
            setInterval(() => streaming && change(i + 1), 1000 / CHANGE_RATE),
          );
        },
        (i * 1000) / CHILD_RATE / CHILDREN,
      );
    }
  };
  const stopStream = () => {
    streaming = false;
    for (const t of timers.splice(0)) clearInterval(t);
  };
  releases.push(stopStream);

  const server = await chromium.launchServer({
    headless: true,
    args: UNTHROTTLED ? ["--disable-frame-rate-limit", "--disable-gpu-vsync"] : [],
  });
  releases.push(() => server.close());
  const browser = await chromium.connect(server.wsEndpoint());
  const context = await browser.newContext({ viewport: { width: 1400, height: 900 } });
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
      if (!w.__firstRow && document.querySelector("[data-row-id]")) w.__firstRow = performance.now();
      if (!w.__firstRow) requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  });
  const page = await context.newPage();
  await page.goto(
    `http://127.0.0.1:${statics.port}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&scheme=cmux&session=${PARENT}`,
  );
  await page.waitForFunction(() => (window as unknown as { __firstRow?: number }).__firstRow, undefined, {
    timeout: 120_000,
    polling: 100,
  });
  // Let the first page settle before any window.
  await Bun.sleep(2000);

  const frames = async (seconds: number) => {
    await page.evaluate(() => {
      const w = window as unknown as {
        __frames: number[];
        __work: number[];
        __framesOn: boolean;
        __longTasks: number[];
      };
      w.__frames = [];
      w.__work = [];
      w.__framesOn = true;
      w.__longTasks.length = 0;
      const step = (t: number) => {
        if (!w.__framesOn) return;
        w.__frames.push(t);
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
    await Bun.sleep(seconds * 1000);
    const got = await page.evaluate(() => {
      const w = window as unknown as {
        __frames: number[];
        __work: number[];
        __framesOn: boolean;
        __longTasks: number[];
      };
      w.__framesOn = false;
      return { frames: w.__frames, work: w.__work, longTasks: [...w.__longTasks] };
    });
    return {
      work: got.work,
      intervals: got.frames.slice(1).map((t, i) => t - got.frames[i]!),
      longTasks: got.longTasks,
    };
  };

  // The floor: the same page with nothing streaming.
  const idle = await frames(IDLE_SECONDS);
  // All 16 children and the parent streaming.
  startStream();
  await Bun.sleep(1000);
  const counted = { ...counts };
  const busy = await frames(SECONDS);
  const streamed = {
    events: counts.events - counted.events,
    changes: counts.changes - counted.changes,
  };
  stopStream();
  const trayChildren = await page.evaluate(
    (names) => names.filter((name) => document.body.innerText.includes(name)).length,
    Array.from({ length: CHILDREN }, (_, i) => childName(i)),
  );

  const p = (values: number[]) => ({
    n: values.length,
    p50: pct(values, 0.5),
    p95: pct(values, 0.95),
    p99: pct(values, 0.99),
    max: pct(values, 1),
    mean: values.reduce((a, b) => a + b, 0) / Math.max(1, values.length),
  });
  const busyStats = p(busy.work);
  const idleStats = p(idle.work);
  const dropped = (intervals: number[]) =>
    intervals.reduce((sum, ms) => sum + (ms > FRAME_MS * 1.5 ? Math.round(ms / FRAME_MS) - 1 : 0), 0);
  Object.assign(summary, {
    frame_ms: busyStats,
    idle_frame_ms: idleStats,
    interval_ms: p(busy.intervals),
    idle_interval_ms: p(idle.intervals),
    dropped_frames: dropped(busy.intervals),
    idle_dropped_frames: dropped(idle.intervals),
    frames_over_16ms: busy.work.filter((ms) => ms > FRAME_BAR_MS).length,
    frames_over_33ms: busy.work.filter((ms) => ms > 33.3).length,
    long_task_ms: busy.longTasks.reduce((a, b) => a + b, 0),
    long_tasks: busy.longTasks.length,
    streamed,
    events_per_s: streamed.events / SECONDS,
    changes_per_s: streamed.changes / SECONDS,
    children_named_on_page: trayChildren,
  });
  fs.writeFileSync(path.join(runDir, "summary.json"), JSON.stringify(summary, null, 2));
  fs.writeFileSync(path.join(runDir, "frames.json"), JSON.stringify({ busy, idle }));
  if (busyStats.n < 10) throw new Error(`orchestrator-16: only ${busyStats.n} frames in ${SECONDS}s`);

  perfRow({
    name: `${ROW}.frame_ms`,
    p50: busyStats.p50,
    p95: busyStats.p95,
    unit: "ms",
    target: FRAME_BAR_MS,
  });
  perfRow({
    name: `${ROW}.frame_ms_p99`,
    p50: busyStats.p99,
    p95: busyStats.p99,
    unit: "ms",
    target: FRAME_BAR_MS,
    version: 1,
  });
  perfRow({ name: `${ROW}.idle_frame_ms_p99`, p50: idleStats.p99, p95: idleStats.p99, unit: "ms" });
  perfRow({
    name: `${ROW}.frames_over_16ms`,
    p95: summary.frames_over_16ms as number,
    unit: "count",
    target: Math.max(1, Math.floor(busyStats.n / 100)),
  });
  perfRow({
    name: `${ROW}.dropped_frames`,
    p95: summary.dropped_frames as number,
    unit: "count",
    target: Math.max(1, Math.floor(busyStats.n / 100)),
  });
  perfRow({
    name: `${ROW}.long_task_ms`,
    p95: summary.long_task_ms as number,
    unit: "ms",
    target: TARGET_MS.response,
  });
  console.log(`orchestrator-16: raw in ${runDir}`);
  console.log(JSON.stringify(summary));
} finally {
  await release();
}
