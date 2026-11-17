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
//   to_frame  the page's own typingStats (keydown to the next frame, p50 / p95 / max), as the Mac bench reads it
//   long_tasks  main-thread tasks of 50 ms or more while the keys are typed (PerformanceObserver longtask), and
//             longest_task_ms the longest (0 when none)
//   stream    with --modes idle,stream: the same keys while the chat streams a reply (60 deltas/s, a tool call every
//             30), and, with no typing, the composer's renders per streamed event (reply text and tool calls, then a
//             tool's output ticking while another chat changes: debug loadRun and loadTick). A stream event the
//             composer does not show should render it 0 times.
// Every length and mode is a fresh browser process and page. With `--arms A=DIR,B=DIR` it measures two webviews
// trees in one run, interleaved A B B A for `--rounds` rounds (default 6) with a base-against-base noise floor, and
// prints each arm's median and spread (composer-arms.ts).
//   bun bench/composer-typing.bench.ts [--lengths 60,1500,6000] [--keys 60] [--gap 80] [--modes idle,stream] [--dev] [--profile]
//     [--arms A=.,B=../webviews-b] [--rounds 6] [--no-floor]
/// <reference types="bun" />
import path from "node:path";
import { chromium } from "./browsers";
import type { Page } from "playwright";
import { parseArms, runArms, servePane } from "./composer-arms";

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : undefined;
};
const LENGTHS = (flag("--lengths") ?? "60,1500,6000").split(",").map(Number);
const KEYS = Number(flag("--keys") ?? 60);
const GAP_MS = Number(flag("--gap") ?? 80);
const MODES = (flag("--modes") ?? "idle").split(",") as ("idle" | "stream" | "heavy")[];
/// With --profile: a CPU profile over the typed keys, and the functions with the most time per key (inclusive and self).
const PROFILE = argv.includes("--profile");
const HEAVY_STREAM = Number(flag("--stream") ?? 60);
const HEAVY_LINES = Number(flag("--tool-lines") ?? 2000);
const DEV = argv.includes("--dev");
const webviews = path.resolve(import.meta.dir, "..");
const ARMS = parseArms(flag("--arms"), webviews);
const PORT_ARM = new Map<number, string>();
const ROUNDS = Number(flag("--rounds") ?? 6);
const FLOOR = !argv.includes("--no-floor");
/// What an A/B of arms summarizes: key to frame, key to listener and the long tasks.
const ARM_METRICS = [
  "to_frame_p50",
  "to_frame_p95",
  "to_frame_max",
  "to_listener_p95",
  "longest_task_ms",
  "long_tasks",
  "held_max",
  "held_final",
  "heap_max_mb",
  "heap_final_mb",
] as const;
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
      const samples: { held: number; heap: number }[] = [];
      (window as any).__heldSamples = samples;
      const diag: Record<string, unknown>[] = [];
      (window as any).__heldDiag = diag;
      (window as any).__heldClient = live;
      const t00 = performance.now();
      const counts = { olders: 0, fills: 0, sheds: 0 };
      (window as any).__heldCounts = counts;
      {
        const c = live as any;
        const loadOlder = c.loadOlder.bind(c);
        c.loadOlder = (through?: number, fill = false, rising = false) => {
          counts.olders += 1;
          if (fill) counts.fills += 1;
          return loadOlder(through, fill, rising);
        };
        const shed = c.shedOlderHeld.bind(c);
        c.shedOlderHeld = () => {
          const first = c.events?.[0]?.seq;
          shed();
          if (c.events?.[0]?.seq !== first) counts.sheds += 1;
        };
      }
      const sample = () => {
        const c = live as any;
        samples.push({ held: (c.events?.length as number) ?? -1, heap: (performance as any).memory?.usedJSHeapSize ?? 0 });
        if (samples.length % 4 !== 1) return;
        let running: unknown;
        try { running = c.turnRunning?.(); } catch (error) { running = String(error); }
        diag.push({
          t: Math.round(performance.now() - t00), held: c.events?.length, first: c.events?.[0]?.seq, last: c.lastSeq,
          following: c.following, loadingOlder: c.loadingOlder, snapshotHold: !!c.snapshotHold,
          replayThrough: c.replayThrough, ip: c.indexedPlaceholders?.size, gaps: c.indexedGaps?.length,
          running, retryAt: c.shedRetryAt, splits: c.splits?.size, turnOpenedSeq: c.turnOpenedSeq,
          ...counts, subRunning: [...(c.subagents?.all?.() ?? [])].filter((a: any) => a.state === "running").length,
        });
      };
      (window as any).__heldTimer = setInterval(sample, 250);
      sample();
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
      // The in-page mock daemon did not start this turn, so its summary still says idle, and the pane closes a turn
      // its host says ended (direct.ts `settleTurnWithHost`): a real acpmux lists the turn it runs as running.
      const host = live.socket as unknown as { touch?: (target: string, fields: Record<string, unknown>) => void };
      host.touch?.call(host, session, {
        status: "running",
        indicator: "working",
        turn: { turnId: "bench-heavy", startedAt: Date.now() },
      });
      (window as any).__hostTouched = typeof host.touch === "function";
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


/// Init script (self-contained): every long task from page load, for the window the keys are typed in.
function longTaskProbe() {
  const w = window as unknown as { __longTasks?: { at: number; ms: number }[] };
  if (w.__longTasks) return;
  const tasks: { at: number; ms: number }[] = [];
  w.__longTasks = tasks;
  try {
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) tasks.push({ at: entry.startTime, ms: entry.duration });
    }).observe({ type: "longtask", buffered: true });
  } catch {
    // An engine without long tasks reads 0.
  }
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
const serveOptions = { dev: DEV, unminified: PROFILE };

/// One length in one mode on the pane served at `port`: a fresh browser process and page, the keys typed, its row.
async function measure(port: number, length: number, mode: "idle" | "stream" | "heavy"): Promise<Record<string, unknown>> {
  const browser = await chromium.launch({ headless: true, args: ["--enable-precise-memory-info"] });
  try {
    const page = await browser.newPage({ viewport: { width: 1100, height: 820 } });
    await page.addInitScript(longTaskProbe);
    const { rows, session } = await openChat(page, port, Math.max(1, Math.round(length / 3)));
    if (mode === "heavy") {
      await startLoad(page, session, HEAVY_STREAM, HEAVY_LINES);
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
    // Stream mode: a reply streams in for the whole typing run (no scrolling), a tool call every 30 deltas.
    const streaming =
      mode === "stream"
        ? page.evaluate(
            (seconds) =>
              (window as any).cmuxAcpmuxDebug.loadRun({ seconds, chunk_ms: 16, tool_every: 30, scroll_speed: 0 }),
            (KEYS * (GAP_MS + 20)) / 1000 + 1,
          )
        : Promise.resolve(undefined);
    if (mode === "stream") {
      await page.waitForTimeout(300);
      await page.evaluate(() => {
        const debug = (window as any).cmuxAcpmuxDebug;
        debug.resetTyping();
        debug.renders();
      });
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
    const long = (
      (await page.evaluate(
        () => (window as unknown as { __longTasks?: { at: number; ms: number }[] }).__longTasks ?? [],
      )) as { at: number; ms: number }[]
    ).filter((task) => task.at + task.ms >= since && task.at <= until);
    if (PROFILE) {
      const { profile } = (await cdp.send("Profiler.stop")) as { profile: CpuProfile };
      printProfile(length, profile);
    }
    const { renders, typing } = (await page.evaluate(() => {
      const debug = (window as any).cmuxAcpmuxDebug;
      return { renders: debug.renders(), typing: debug.typingStats() };
    })) as { renders: Record<string, number>; typing: Record<string, any> };
    await streaming;
    // Per stream event, nobody typing: the composer's renders while a reply and tool calls stream
    // (loadRun), then while a tool's output ticks and another chat changes (loadTick).
    let composerPerEvent: number | undefined;
    let composerPerTick: number | undefined;
    if (mode === "stream") {
      const run = (await page.evaluate(() =>
        (window as any).cmuxAcpmuxDebug.loadRun({ seconds: 3, chunk_ms: 16, tool_every: 10, scroll_speed: 0 }),
      )) as { renders: Record<string, number>; deltas: number; tools: number };
      composerPerEvent = Math.round(((run.renders.composer ?? 0) / Math.max(1, run.deltas + run.tools)) * 1000) / 1000;
      const tick = (await page.evaluate(() =>
        (window as any).cmuxAcpmuxDebug.loadTick({ seconds: 3, tick_ms: 50, sidebar_ms: 100, scroll_speed: 0 }),
      )) as { renders: Record<string, number>; ticks?: number; sidebar?: number };
      composerPerTick =
        Math.round(((tick.renders.composer ?? 0) / Math.max(1, (tick.ticks ?? 0) + (tick.sidebar ?? 0))) * 1000) / 1000;
    }
    const heavy =
      mode === "heavy"
        ? ((await page.evaluate(() => {
            const w = window as any;
            w.__streamLoad.stopped = true;
            clearInterval(w.__heldTimer);
            const c = w.__heldClient;
            let probe: Record<string, unknown> = {};
            try {
              const pick = c.pickShedCut(Infinity);
              const known = (id: string) => c.splittable(id);
              const split = c.pickShedCut(Infinity, known);
              const cutSeq = c.events[split.cut]?.seq ?? c.events[pick.cut]?.seq;
              const rows: unknown[] = [];
              for (const [id, order] of c.rows.spanningRows(c.events[Math.max(0, c.events.length - 2000)].seq)) {
                const row = c.rows.get(id);
                rows.push({ id: String(id).slice(0, 40), order, kind: row?.kind, items: row?.items?.length,
                  itemKinds: row?.items?.map((i: any) => (i.tool ? "tool" : Object.keys(i).join("+"))).join(","),
                  splittable: c.splittable(id), streaming: c.streamingAssistant === id });
              }
              probe = { pick: pick.cut, split: split.cut, cutSeq, plans: split.cut > pick.cut ? !!c.planSplits(split.cut, known) : null, rows };
            } catch (error) { probe = { error: String(error) }; }
            probe.counts = w.__heldCounts;
            probe.hostTouched = w.__hostTouched;
            return { load: w.__streamLoad, samples: w.__heldSamples, diag: w.__heldDiag, probe };
          })) as { load: Record<string, number>; samples: { held: number; heap: number }[]; diag: unknown; probe: unknown })
        : undefined;
    if (heavy) {
      const line = "HELD-DIAG " + JSON.stringify({ arm: PORT_ARM.get(port), diag: heavy.diag, probe: heavy.probe }) + "\n";
      process.stdout.write(line);
      if (process.env.FAST_CHECKS_OUT) (await import("node:fs")).appendFileSync(`${process.env.FAST_CHECKS_OUT}/held-diag.txt`, line);
    }
    let heapFinal: number | undefined;
    if (heavy) {
      await cdp.send("HeapProfiler.collectGarbage");
      heapFinal = ((await cdp.send("Runtime.getHeapUsage")) as { usedSize: number }).usedSize;
    }
    await page.close();
    const per = (value: number) => Math.round((value / KEYS) * 100) / 100;
    const sum = (prefix: string) =>
      Object.entries(renders)
        .filter(([name]) => name.startsWith(prefix))
        .reduce((total, [, value]) => total + value, 0);
    const delta = (name: string) => (after[name] ?? 0) - (before[name] ?? 0);
    return {
      mode,
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
      to_frame_max: typing.to_frame?.max_ms,
      longest_task_ms: Math.round(Math.max(0, ...long.map((task) => task.ms)) * 10) / 10,
      long_tasks: long.length,
      composer_per_stream_event: composerPerEvent,
      composer_per_tick_event: composerPerTick,
      nativePosts: JSON.stringify(typing.native_posts ?? {}),
      ...(heavy
        ? {
            held_max: Math.max(...heavy.samples.map((s) => s.held)),
            held_final: heavy.samples.at(-1)?.held,
            heap_max_mb: Math.round(Math.max(...heavy.samples.map((s) => s.heap)) / 1048576 * 10) / 10,
            heap_final_mb: Math.round((heapFinal ?? 0) / 1048576 * 10) / 10,
            load_lines: heavy.load.lines,
            load_chunks: heavy.load.chunks,
          }
        : {}),
      busiest: Object.entries(renders)
        .sort((a, b) => b[1] - a[1])
        .slice(0, 8)
        .map(([name, value]) => `${name}=${value}`)
        .join(" "),
    };
  } finally {
    await browser.close();
  }
}

try {
  const cases = LENGTHS.flatMap((length) => MODES.map((mode) => ({ length, mode })));
  if (ARMS) {
    // Two source trees in one run: each built and served once, then every case interleaved (composer-arms.ts).
    const ports = new Map<string, number>();
    for (const arm of ARMS) ports.set(arm.name, await servePane(arm.dir, serveOptions, releases));
    for (const [name, port] of ports) PORT_ARM.set(port, name);
    const runs: Record<string, unknown>[] = [];
    for (const { length, mode } of cases)
      runs.push(
        ...(await runArms({
          arms: ARMS,
          rounds: ROUNDS,
          floor: FLOOR,
          label: `${mode} ${length} rows`,
          metrics: ARM_METRICS,
          ports,
          run: (port) => measure(port, length, mode),
        })),
      );
    console.log(`COMPOSER-TYPING ${JSON.stringify(runs)}`);
  } else {
    const port = await servePane(webviews, serveOptions, releases);
    const table: Record<string, unknown>[] = [];
    for (const { length, mode } of cases) table.push(await measure(port, length, mode));
    console.table(table.map(({ busiest: _, nativePosts: __, ...row }) => row));
    for (const row of table)
      console.log(
        `${String(row.mode)} ${String(row.rows)} rows: ${String(row.busiest)}; native posts ${String(row.nativePosts)}`,
      );
    console.log(`COMPOSER-TYPING ${JSON.stringify(table)}`);
  }
} finally {
  for (const release of releases.reverse()) await release();
}
