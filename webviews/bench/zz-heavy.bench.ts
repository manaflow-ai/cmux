// l10n-allow-file: benchmark output, not shipped UI.
// What one keystroke in the agent chat's composer costs, at transcript lengths of 60, 1,500 and 6,000 rows (CMUX-571,
// Leo: "improve performance (chat, everything related)"; Leo, 2026-11-12: long chats must have "no perceivable
// difference"). A key should render the composer and nothing that does not read its text: not the pane root, not the
// transcript, not a row, and its cost should not grow with the transcript.
//
// The real pane (`?mock`: the real direct client against the in-page mock daemon), built as it ships (the server
// setup below). Each length is a light chat
// (`cmuxAcpmuxDebug.loadSeed(turns, { light: true })`), then `--keys` letters typed into the prompt with real key
// events (Playwright's keyboard, `--gap` ms apart, about a fast typist's pace). Per key:
//   renders   `acpmuxPerf.renders`: the pane root (AcpmuxPane), the transcript, the composer, every row and row frame
//   layout    the page's layouts and style recalcs (CDP Performance.getMetrics LayoutCount, RecalcStyleCount)
//   script    main-thread script, layout and style time (ScriptDuration, LayoutDuration, RecalcStyleDuration), ms
//   to_frame  the page's own typingStats (keydown to the next frame, p50 / p95), as the Mac bench reads it
//   key_frame the bench's own keydown-to-next-frame per key (p50 / p95 / max), from an init script's rAF clock
//   longest_task_ms  the longest main-thread task while the keys are typed (PerformanceObserver longtask: 0 when
//             none reached 50 ms), and long_tasks how many did
//   frames_over_16ms  rAF intervals while typing past 20 ms (a frame that missed at least one 16.7 ms vsync), and
//             frame_gap_max the longest
//   burst_keys keys whose next frame was another key's too (the page could not draw between them)
//
// Under load (chats stream while the person types): `--stream CHUNKS_PER_S` streams an assistant reply into the open
// chat (`session/update` agent_message_chunk notifications), and `--tool-lines LINES_PER_S` runs a shell call whose
// output grows a line per `tool_call_update` (`_meta.terminal_output.data`, the append form pi sends). Both start
// a second before the warm-up keys and run until the last key is measured. The frames are raw JSON strings with
// increasing `_meta.acpmux.seq`, handed to the client's transport socket `onmessage` a push at a time, as
// `BridgeSocket.receive({connection, frames})` does with the host's push: one push per ~16 ms (the host pacer's
// display frame) holding every frame due since the last. So the client's receive, parse, reduce and emit all run as
// they do in the app, and a change to any of them is measured. Default 0: without the flags the bench is unchanged.
//   bun bench/composer-typing.bench.ts [--lengths 60,1500,6000] [--keys 60] [--gap 80] [--dev] [--profile]
//     [--stream CHUNKS_PER_S] [--tool-lines LINES_PER_S]
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium } from "./browsers";
import type { Page } from "playwright";
import { warmViteServer } from "../test/support/warmDevServer";

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : undefined;
};
const LENGTHS = (flag("--lengths") ?? "60,1500,6000").split(",").map(Number);
const KEYS = Number(flag("--keys") ?? 60);
const GAP_MS = Number(flag("--gap") ?? 80);
/// With --profile: a CPU profile over the typed keys, and the functions with the most time per key (inclusive and self).
const PROFILE = argv.includes("--profile");
const DEV = argv.includes("--dev");
const STREAM_PER_S = Number(flag("--stream") ?? 0);
const TOOL_LINES_PER_S = Number(flag("--tool-lines") ?? 0);
const LOADED = STREAM_PER_S > 0 || TOOL_LINES_PER_S > 0;
const webviews = path.resolve(import.meta.dir, "..");
const PROMPT = ".acpmux-composer-prompt[contenteditable='true'], .acpmux-composer-prompt [contenteditable='true']";
const METRICS = [
  "LayoutCount",
  "RecalcStyleCount",
  "ScriptDuration",
  "LayoutDuration",
  "RecalcStyleDuration",
  "TaskDuration",
] as const;

async function openChat(page: Page, port: number, turns: number) {
  await page.goto(`http://127.0.0.1:${port}/?mock`);
  await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
  const seeded = (await page.evaluate(
    (count) => (window as any).cmuxAcpmuxDebug.loadSeed(count, { light: true }),
    turns,
  )) as Record<string, any>;
  if (seeded.error) throw new Error(`loadSeed: ${seeded.error}`);
  await page.locator(PROMPT).first().waitFor({ timeout: 20_000 });
  return { rows: seeded.rows as number, session: seeded.session as string };
}

type Probe = { keys: number[]; frames: number[]; long: { at: number; ms: number }[] };

/// Init script: the bench's own clock for keys and frames (self-contained). Each keydown's time, each frame
/// callback's time and each long task, from the first frame on; the bench reads the window it typed in.
function typingProbe() {
  const w = window as unknown as { __typingProbe?: Probe };
  if (w.__typingProbe) return;
  const probe: Probe = { keys: [], frames: [], long: [] };
  w.__typingProbe = probe;
  const tick = () => {
    probe.frames.push(performance.now());
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
  addEventListener("keydown", (event) => probe.keys.push(event.timeStamp), true);
  try {
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) probe.long.push({ at: entry.startTime, ms: entry.duration });
    }).observe({ type: "longtask", buffered: true });
  } catch {
    // An engine without long tasks reads 0.
  }
}

/// Starts the stream load in the page (see the header): a running turn on the open chat, then a push every ~16 ms
/// of every reply chunk and tool output line due since the last, as raw frames through the client's transport
/// socket. The client is found through React's fiber above the composer (the pane keeps it in a ref and exposes no
/// handle), and each push reads its socket then, as the host's push reaches whichever socket is live.
async function startLoad(page: Page, session: string, chunksPerS: number, linesPerS: number) {
  const started = (await page.evaluate(
    ({ session, chunksPerS, linesPerS, selectors }) => {
      type Socket = { readyState: number; onmessage: ((message: { data: string }) => void) | null };
      type Client = { socket?: Socket; lastSeq: number; selectedSessionId?: string };
      const isClient = (value: any): value is Client =>
        !!value &&
        typeof value === "object" &&
        typeof value.lastSeq === "number" &&
        "selectedSessionId" in value &&
        typeof value.socket?.onmessage === "function";
      let client: Client | undefined;
      for (const selector of selectors) {
        const element = document.querySelector(selector) as any;
        if (!element) continue;
        const key = Object.keys(element).find((name) => name.startsWith("__reactFiber$"));
        for (let fiber = key ? element[key] : undefined; fiber && !client; fiber = fiber.return) {
          for (let hook = fiber.memoizedState; hook && typeof hook === "object" && "next" in hook; hook = hook.next) {
            const current = hook.memoizedState?.current;
            if (isClient(current)) {
              client = current;
              break;
            }
          }
        }
        if (client) break;
      }
      if (!client) return { error: "no direct client found through the pane's fiber" };
      if (client.selectedSessionId !== session)
        return { error: `the client shows ${String(client.selectedSessionId)}, not the seeded ${session}` };
      const live = client;
      let seq = live.lastSeq;
      const id = JSON.stringify(session);
      const event = (kind: string, msg: string) =>
        `{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":${id},"seq":${++seq},"at":${Date.now()},"dir":"mux","kind":"${kind}","msg":${msg}}}`;
      const update = (body: string) =>
        `{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":${id},"update":${body},"_meta":{"acpmux":{"seq":${++seq},"at":${Date.now()}}}}}`;
      const words = [
        "the",
        "composer",
        "keeps",
        "its",
        "draft",
        "while",
        "rows",
        "stream",
        "in",
        "and",
        "each",
        "frame",
        "should",
        "draw",
        "only",
        "what",
        "changed",
        "`receive`",
        "parses",
        "**once**",
        "then",
        "reduces",
      ];
      let chunkIndex = 0;
      const chunk = () => {
        chunkIndex += 1;
        let text = "";
        for (let i = 0; i < 5; i += 1) text += `${words[(chunkIndex * 7 + i * 3) % words.length]} `;
        if (chunkIndex % 40 === 0) text += "\n\n";
        else if (chunkIndex % 9 === 0) text += "\n- ";
        return update(
          `{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":${JSON.stringify(text)}}}`,
        );
      };
      const call = `composer-load-${Date.now()}`;
      let lineIndex = 0;
      const line = () => {
        lineIndex += 1;
        const data = `[${String(lineIndex).padStart(6, "0")}] compiling src/agent-session/module${lineIndex % 97}.ts ok\n`;
        return update(
          `{"sessionUpdate":"tool_call_update","toolCallId":"${call}","status":"in_progress","_meta":{"terminal_output":{"data":${JSON.stringify(data)}}}}`,
        );
      };
      // As BridgeSocket.receive: every frame of one push in one task, in order, while the socket is open.
      const push = (frames: string[]) => {
        const socket = live.socket;
        for (const data of frames) {
          if (!socket || socket.readyState !== 1) return;
          socket.onmessage?.({ data });
        }
      };
      const opening = [
        event("user_message", `{"text":"Build it and explain what changed"}`),
        event("turn_started", "{}"),
      ];
      if (linesPerS > 0)
        opening.push(
          update(
            `{"sessionUpdate":"tool_call","toolCallId":"${call}","title":"Run bun run build","kind":"execute","status":"in_progress","rawInput":{"command":"bun run build"}}`,
          ),
        );
      push(opening);
      const t0 = performance.now();
      const state = { pushes: 0, frames: opening.length, chunks: 0, lines: 0, stopped: false, push_ms_max: 0 };
      (window as unknown as { __streamLoad: typeof state }).__streamLoad = state;
      const pump = () => {
        if (state.stopped) return;
        const elapsed = (performance.now() - t0) / 1000;
        const frames: string[] = [];
        for (; state.chunks < Math.floor(elapsed * chunksPerS); state.chunks += 1) frames.push(chunk());
        for (; state.lines < Math.floor(elapsed * linesPerS); state.lines += 1) frames.push(line());
        if (frames.length) {
          const at = performance.now();
          push(frames);
          state.push_ms_max = Math.max(state.push_ms_max, performance.now() - at);
          state.pushes += 1;
          state.frames += frames.length;
        }
        setTimeout(pump, 16);
      };
      setTimeout(pump, 16);
      return { seq: live.lastSeq };
    },
    { session, chunksPerS, linesPerS, selectors: [PROMPT, ".acpmux-scroll", ".acpmux-composer"] },
  )) as { error?: string };
  if (started.error) throw new Error(`stream load: ${started.error}`);
}

type CpuProfile = {
  nodes: { id: number; callFrame: { functionName: string; url: string; lineNumber: number }; children?: number[] }[];
  samples: number[];
  timeDeltas: number[];
};

/// Per key, ms: each function's inclusive time (once per sample however deep it recurses) and self time.
function printProfile(length: number, profile: CpuProfile) {
  const byId = new Map(profile.nodes.map((node) => [node.id, node]));
  const parent = new Map<number, number>();
  for (const node of profile.nodes) for (const child of node.children ?? []) parent.set(child, node.id);
  const name = (id: number) => {
    const frame = byId.get(id)!.callFrame;
    const file = frame.url.split("/").pop()?.split("?")[0] ?? "";
    return `${frame.functionName || "(anon)"} ${file}:${frame.lineNumber + 1}`;
  };
  const inclusive = new Map<string, number>();
  const self = new Map<string, number>();
  profile.samples.forEach((id, index) => {
    const ms = (profile.timeDeltas[index + 1] ?? 0) / 1000;
    const fn = byId.get(id)?.callFrame.functionName;
    if (fn === "(idle)" || fn === "(program)") return;
    self.set(name(id), (self.get(name(id)) ?? 0) + ms);
    const seen = new Set<string>();
    for (let at: number | undefined = id; at !== undefined; at = parent.get(at)) {
      const key = name(at);
      if (seen.has(key)) continue;
      seen.add(key);
      inclusive.set(key, (inclusive.get(key) ?? 0) + ms);
    }
  });
  const top = (map: Map<string, number>, count: number) =>
    [...map.entries()]
      .sort((a, b) => b[1] - a[1])
      .slice(0, count)
      .map(([key, ms]) => `  ${(ms / KEYS).toFixed(3)} ms/key  ${key}`)
      .join("\n");
  console.log(`PROFILE ${length} rows, inclusive:\n${top(inclusive, 90)}`);
  console.log(`PROFILE ${length} rows, self:\n${top(self, 40)}`);
}

// The pane as it ships (a vite build: production React, the React Compiler pass), served as files; --dev serves the
// dev server's pane instead (development React, several times the script time per render). With --profile the build
// is unminified, so the profile names functions.
const releases: (() => unknown)[] = [];
let port: number;
if (DEV) {
  const { createServer } = await import("vite");
  const vite = await createServer({
    configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
    server: { port: 0, host: "127.0.0.1", strictPort: false },
    logLevel: "error",
  });
  releases.push(() => vite.close());
  await vite.listen();
  await warmViteServer(vite, "/?mock");
  port = (vite.httpServer!.address() as { port: number }).port;
} else {
  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "composer-typing-bench-"));
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
  port = statics.port!;
}
const browser = await chromium.launch({ headless: true });
releases.push(() => browser.close());
try {
  const table: Record<string, unknown>[] = [];
  for (const length of LENGTHS) {
    const page = await browser.newPage({ viewport: { width: 1100, height: 820 } });
    await page.addInitScript(typingProbe);
    const { rows, session } = await openChat(page, port, Math.max(1, Math.round(length / 3)));
    if (LOADED) {
      await startLoad(page, session, STREAM_PER_S, TOOL_LINES_PER_S);
      // The stream runs before the first key: a second of it lands first.
      await page.waitForTimeout(1000);
    }
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Performance.enable");
    const metrics = async () => {
      const { metrics: list } = (await cdp.send("Performance.getMetrics")) as {
        metrics: { name: string; value: number }[];
      };
      return Object.fromEntries(
        list.filter((m) => (METRICS as readonly string[]).includes(m.name)).map((m) => [m.name, m.value]),
      );
    };
    await page.locator(PROMPT).first().click();
    // Warm-up: the first keys load the composer's lazy parts (emoji data, the mention index).
    for (const key of "warm") await page.keyboard.press(key);
    await page.waitForTimeout(500);
    for (let i = 0; i < 4; i += 1) await page.keyboard.press("Backspace");
    await page.waitForTimeout(500);
    await page.evaluate(() => {
      const debug = (window as any).cmuxAcpmuxDebug;
      debug.resetTyping();
      debug.renders();
    });
    if (PROFILE) {
      await cdp.send("Profiler.enable");
      await cdp.send("Profiler.setSamplingInterval", { interval: 100 });
      await cdp.send("Profiler.start");
    }
    const before = await metrics();
    const since = await page.evaluate(() => performance.now());
    const letters = "abcdefghijklmnopqrstuvwxyz";
    for (let i = 0; i < KEYS; i += 1) {
      await page.keyboard.press(letters[i % letters.length]!);
      await page.waitForTimeout(GAP_MS);
    }
    await page.waitForTimeout(500);
    const after = await metrics();
    const until = await page.evaluate(() => performance.now());
    const load = LOADED
      ? ((await page.evaluate(() => {
          const state = (window as unknown as { __streamLoad: Record<string, number | boolean> }).__streamLoad;
          state.stopped = true;
          return state;
        })) as Record<string, number>)
      : undefined;
    const probe = (await page.evaluate(() => (window as unknown as { __typingProbe: Probe }).__typingProbe)) as Probe;
    if (PROFILE) {
      const { profile } = (await cdp.send("Profiler.stop")) as { profile: CpuProfile };
      printProfile(length, profile);
      {
        // Per-line samples inside pullRequestRowKey, with the bundle's lines (diagnosis only).
        const nodes = (profile as any).nodes as any[];
        const hits = new Map<string, number>();
        let url = "";
        for (const node of nodes)
          if (node.callFrame.functionName === "pullRequestRowKey" || node.callFrame.functionName === "grewWithoutReferences") {
            url = node.callFrame.url;
            for (const tick of node.positionTicks ?? [])
              hits.set(`${node.callFrame.functionName}:${tick.line}`, (hits.get(`${node.callFrame.functionName}:${tick.line}`) ?? 0) + tick.ticks);
          }
        const source = url ? ((await page.evaluate((u) => fetch(u).then((r) => r.text()), url)) as string).split("\n") : [];
        for (const [key, ticks] of [...hits].sort((a, b) => b[1] - a[1]).slice(0, 12)) {
          const line = Number(key.split(":")[1]);
          console.log(`LINETICKS ${ticks} ${key} | ${(source[line - 1] ?? "").trim().slice(0, 160)}`);
        }
      }
    }
    const { renders, typing } = (await page.evaluate(() => {
      const debug = (window as any).cmuxAcpmuxDebug;
      return { renders: debug.renders(), typing: debug.typingStats() };
    })) as { renders: Record<string, number>; typing: Record<string, any> };
    await page.close();
    const per = (value: number) => Math.round((value / KEYS) * 100) / 100;
    const sum = (prefix: string) =>
      Object.entries(renders)
        .filter(([name]) => name.startsWith(prefix))
        .reduce((total, [, value]) => total + value, 0);
    const delta = (name: string) => (after[name] ?? 0) - (before[name] ?? 0);
    // Each typed key's next frame (the first frame callback after its keydown), on the bench's own clock.
    const keyTimes = probe.keys.filter((at) => at >= since && at <= until);
    const frames = probe.frames.filter((at) => at >= since && at <= until);
    const keyFrame: number[] = [];
    const keysPerFrame = new Map<number, number>();
    for (const at of keyTimes) {
      const next = frames.findIndex((frame) => frame >= at);
      if (next < 0) continue;
      keyFrame.push(frames[next]! - at);
      keysPerFrame.set(next, (keysPerFrame.get(next) ?? 0) + 1);
    }
    const burstKeys = [...keysPerFrame.values()]
      .filter((count) => count > 1)
      .reduce((total, count) => total + count, 0);
    const gaps = frames.slice(1).map((at, index) => at - frames[index]!);
    const long = probe.long.filter((task) => task.at + task.ms >= since && task.at <= until);
    const pct = (values: number[], p: number) => {
      const sorted = [...values].sort((a, b) => a - b);
      return sorted.length ? sorted[Math.min(sorted.length - 1, Math.round((sorted.length - 1) * p))]! : 0;
    };
    const r1 = (value: number) => Math.round(value * 10) / 10;
    table.push({
      rows,
      keys: typing.keys,
      pane: per(renders.pane ?? 0),
      transcript: per(renders.transcript ?? 0),
      composer: per(renders.composer ?? 0),
      rowRenders: per(sum("row:") + sum("content:")),
      rowFrames: per(sum("frame:")),
      layouts: per(delta("LayoutCount")),
      styles: per(delta("RecalcStyleCount")),
      script_ms: per(delta("ScriptDuration") * 1000),
      layout_ms: per(delta("LayoutDuration") * 1000),
      style_ms: per(delta("RecalcStyleDuration") * 1000),
      task_ms: per(delta("TaskDuration") * 1000),
      to_listener_p95: typing.to_listener?.p95_ms,
      to_work_p95: typing.to_work?.p95_ms,
      to_frame_p50: typing.to_frame?.p50_ms,
      to_frame_p95: typing.to_frame?.p95_ms,
      key_frame_p50: r1(pct(keyFrame, 0.5)),
      key_frame_p95: r1(pct(keyFrame, 0.95)),
      key_frame_max: r1(Math.max(0, ...keyFrame)),
      longest_task_ms: r1(Math.max(0, ...long.map((task) => task.ms))),
      long_tasks: long.length,
      frames_over_16ms: gaps.filter((gap) => gap > 20).length,
      frame_gap_max: r1(Math.max(0, ...gaps)),
      burst_keys: burstKeys,
      ...(load && {
        load_pushes: load.pushes,
        load_frames: load.frames,
        load_chunks: load.chunks,
        load_lines: load.lines,
        load_push_ms_max: r1(load.push_ms_max ?? 0),
      }),
      nativePosts: JSON.stringify(typing.native_posts ?? {}),
      busiest: Object.entries(renders)
        .sort((a, b) => b[1] - a[1])
        .slice(0, 8)
        .map(([name, value]) => `${name}=${value}`)
        .join(" "),
    });
  }
  console.table(table.map(({ busiest: _, nativePosts: __, ...row }) => row));
  for (const row of table)
    console.log(`${String(row.rows)} rows: ${String(row.busiest)}; native posts ${String(row.nativePosts)}`);
  console.log(`COMPOSER-TYPING ${JSON.stringify(table)}`);
} finally {
  for (const release of releases.reverse()) await release();
}
