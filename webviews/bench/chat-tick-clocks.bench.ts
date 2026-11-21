// l10n-allow-file: bench fixture prompts, replies and commands, not shipped UI.
// What a chat's ticking clocks cost each second (Leo, 2026-11-18, of his NIGHTLY, a chat at its bottom
// with three clocks counting up while the transcript bounced: "did we fix this scroll bounce at the
// bottom yet?"). His chat drew 100 to 570 ms frames about once a second while three clocks counted
// up: "Waiting for the agent service (1:48)" over the composer, a running command's live line
// ("8m 3s") and a background command in the composer's tray ("12h 57m").
//
// The production pane (a vite build of the pane's entry) joins a stand-in acpmux over its WebSocket
// (the dev slot's `#endpoint=`), which hands it one long chat (`TURNS` finished turns of the papercut
// fixture) whose last turn runs two commands and keeps a third in the background. Then acpmux goes
// slow, as Leo's did (`--scenario=slow`): it still answers its liveness probe but no read. A record arrives past a hole,
// the pane reads the hole, the read waits, and after 25 s the waiting line shows and counts
// (`--scenario=lost`: acpmux goes away under the open socket and the next one never answers, so the
// pane reconnects and says "Reconnecting…"). From
// then, over `SECONDS`, nothing else arrives and nothing scrolls, and the bench reports per second
// (one page-clock tick):
//   cpu_ms_per_tick       the renderer main thread's CPU time (CDP Performance ThreadTime);
//   commits_per_tick      React commits, and `fibers_per_tick` the components they rendered (a
//                         DevTools-hook walk of each commit: only fibers whose render ran);
//   rendered              which components rendered, most first (`--unminified` names them), and
//                         `why`: which of the pane's (AcpmuxPane) hooks changed when it rendered;
//   pane_renders, transcript_renders, row_renders  the pane's own counters (acpmuxPerf.renders);
//   longest_frame_ms      the longest Long Animation Frame (Chromium reports those of 50 ms or more);
//   timeline              a devtools.timeline trace of the window: style recalcs (most elements),
//                         layouts (most dirty objects of the total) and paints.
// Run it at two lengths to see whether a tick's cost grows with the chat:
//   bun bench/chat-tick-clocks.bench.ts [turns=1500] [seconds=20] [--scenario=slow|lost] [--dev] [--unminified]
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium } from "./browsers";
import { newestPage } from "./daemonPage";
import { benchPositionals, devRequested } from "./support/benchPage";
import { PAPERCUT_CHAT, papercutEvents, type PapercutStep } from "../test/support/papercutChat";
import { warmViteServer } from "../test/support/warmDevServer";

const [turnsArg, secondsArg] = benchPositionals();
const TURNS = Number(turnsArg ?? 1500);
const SECONDS = Number(secondsArg ?? 20);
const UNMINIFIED = process.argv.includes("--unminified");
/// `slow`: acpmux answers its liveness probe and no read (a read waits); `lost`: acpmux goes away
/// under the open socket and the next one never answers (the reconnect's handshake waits).
const SCENARIO = process.argv.find((arg) => arg.startsWith("--scenario="))?.slice("--scenario=".length) ?? "slow";
const BACKGROUND = "wt new cmux leo/checkout --topic build";
const update = (body: Record<string, unknown>) => ({
  method: "session/update",
  params: { sessionId: "agent-1", update: body },
});

/// The running turn's background command: started, sent to the background, running (the tray's line).
const background: PapercutStep[] = [
  [
    "in",
    "tool_call",
    update({
      sessionUpdate: "tool_call",
      toolCallId: "bg-1",
      title: BACKGROUND,
      kind: "execute",
      status: "in_progress",
      rawInput: { command: BACKGROUND, run_in_background: true },
      _meta: { claude: { tool: "Bash" } },
    }),
  ],
  [
    "in",
    "tool_call_update",
    update({
      sessionUpdate: "tool_call_update",
      toolCallId: "bg-1",
      status: "completed",
      content: [{ type: "content", content: { type: "text", text: "Command running in background with ID: bg-1" } }],
    }),
  ],
  [
    "in",
    "background_task_update",
    update({
      sessionUpdate: "background_task_update",
      taskId: "task-bg-1",
      toolCallId: "bg-1",
      command: BACKGROUND,
      state: "running",
    }),
  ],
];
/// Page init script: counts React commits and the components each rendered (a DevTools hook, which
/// react-dom calls on every commit), and records Long Animation Frames and rAF gaps.
function installTickProbe() {
  type Fiber = {
    tag: number;
    flags: number;
    type: unknown;
    child: Fiber | null;
    sibling: Fiber | null;
    alternate: Fiber | null;
  };
  const probe = {
    armed: false,
    commits: 0,
    fibers: 0,
    names: new Map<string, number>(),
    frames: [] as number[],
    loaf: [] as { duration: number; blocking: number; scripts: string[] }[],
    why: [] as string[],
  };
  (window as unknown as { __tickProbe: typeof probe }).__tickProbe = probe;
  // Function, class, forwardRef, memo and simple memo components: the fibers whose render runs code.
  const COMPONENT = new Set([0, 1, 11, 14, 15]);
  const PERFORMED_WORK = 1;
  const nameOf = (fiber: Fiber) => {
    const type = fiber.type as {
      displayName?: string;
      name?: string;
      render?: { name?: string };
      type?: { name?: string };
    };
    return type?.displayName || type?.name || type?.render?.name || type?.type?.name || `tag${fiber.tag}`;
  };
  // A subtree React skipped keeps the very child its last commit had (bailoutOnAlreadyFinishedWork
  // clones nothing), so the walk enters only children this commit made, and counts the fibers there
  // whose render ran (PerformedWork).
  const walk = (root: Fiber) => {
    const stack: Fiber[] = [root];
    while (stack.length) {
      const fiber = stack.pop()!;
      if (COMPONENT.has(fiber.tag) && fiber.flags & PERFORMED_WORK && fiber.alternate) {
        probe.fibers += 1;
        const name = nameOf(fiber);
        probe.names.set(name, (probe.names.get(name) ?? 0) + 1);
        // Why the pane rendered: which of its hooks' states changed, and to what.
        if (name === "AcpmuxPane" && probe.why.length < 60) {
          const changed: string[] = [];
          type Hook = { memoizedState: unknown; next: Hook | null; queue: unknown };
          let now = (fiber as unknown as { memoizedState: Hook | null }).memoizedState;
          let was = (fiber.alternate as unknown as { memoizedState: Hook | null }).memoizedState;
          for (let index = 0; now && was; index++, now = now.next, was = was.next) {
            if (now.queue && now.memoizedState !== was.memoizedState) {
              let shown: string;
              try {
                shown = JSON.stringify(now.memoizedState)?.slice(0, 160) ?? String(now.memoizedState);
              } catch {
                shown = typeof now.memoizedState;
              }
              changed.push(`#${index}=${shown}`);
            }
          }
          const props =
            (fiber as unknown as { memoizedProps: unknown }).memoizedProps !==
            (fiber.alternate as unknown as { memoizedProps: unknown }).memoizedProps;
          probe.why.push(`${Math.round(performance.now())}${props ? " props" : ""} ${changed.join(" ")}`);
        }
      }
      if (fiber.child && !(fiber.alternate && fiber.alternate.child === fiber.child)) {
        for (let child: Fiber | null = fiber.child; child; child = child.sibling) stack.push(child);
      }
    }
  };
  let renderers = 0;
  (window as unknown as { __REACT_DEVTOOLS_GLOBAL_HOOK__: unknown }).__REACT_DEVTOOLS_GLOBAL_HOOK__ = {
    isDisabled: false,
    supportsFiber: true,
    renderers: new Map(),
    inject() {
      return ++renderers;
    },
    onScheduleFiberRoot() {},
    onCommitFiberUnmount() {},
    onPostCommitFiberRoot() {},
    onCommitFiberRoot(_id: number, root: { current: Fiber }) {
      if (!probe.armed) return;
      probe.commits += 1;
      walk(root.current);
    },
    checkDCE() {},
  };
  new PerformanceObserver((list) => {
    if (!probe.armed) return;
    for (const entry of list.getEntries() as unknown as {
      duration: number;
      blockingDuration: number;
      scripts: { sourceFunctionName?: string; invoker?: string; duration: number }[];
    }[])
      probe.loaf.push({
        duration: entry.duration,
        blocking: entry.blockingDuration,
        scripts: entry.scripts
          .slice()
          .sort((a, b) => b.duration - a.duration)
          .slice(0, 3)
          .map(
            (script) => `${script.invoker ?? "?"}:${script.sourceFunctionName ?? "?"} ${Math.round(script.duration)}ms`,
          ),
      });
  }).observe({ type: "long-animation-frame", buffered: false });
}

type Probe = {
  commits: number;
  fibers: number;
  names: [string, number][];
  frames: number[];
  loaf: { duration: number; blocking: number; scripts: string[] }[];
  why: string[];
};

/// The pane's own entry (vite.config.acpmux-pane.mjs, whose root is the pane's): a production build
/// served statically, as bench/chat-open.bench.ts serves it, or its dev server with `--dev`.
async function servePane(dev: boolean): Promise<{ origin: string; close(): Promise<void> }> {
  const webviews = path.resolve(import.meta.dir, "..");
  const configFile = path.join(webviews, "vite.config.acpmux-pane.mjs");
  const vite = await import("vite");
  if (dev) {
    const server = await vite.createServer({
      configFile,
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await server.listen();
    await warmViteServer(server, "/");
    const { port } = server.httpServer!.address() as { port: number };
    return { origin: `http://127.0.0.1:${port}/`, close: () => server.close() };
  }
  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "chat-tick-clocks-"));
  await vite.build({
    configFile,
    build: { outDir: out, emptyOutDir: true, ...(UNMINIFIED ? { minify: false } : {}) },
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
  return {
    origin: `http://127.0.0.1:${statics.port}/`,
    close: async () => {
      await statics.stop(true);
      fs.rmSync(out, { recursive: true, force: true });
    },
  };
}

/// The stand-in acpmux: answers the chat's open at once until `slow`, then only its liveness probe
/// (`_acpmux/peers`), as a busy daemon does; `skip` sends a live record past a hole the pane reads.
function standInDaemon(turns: number) {
  const chat = papercutEvents({ turns, running: true, extra: background });
  const state = { slow: false, gone: false };
  const sockets = new Set<{ send(data: string): void }>();
  const answer = (method: string, params: Record<string, unknown> = {}): unknown => {
    const lastSeq = chat.events.at(-1)?.seq ?? 0;
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [chat.session] };
      case "_acpmux/attach": {
        const { page, hasMore } = newestPage(chat.events, {
          limit: Number(params.limit ?? 400),
          maxBytes: params.maxBytes,
        });
        return { session: chat.session, lastSeq, events: page, hasMore };
      }
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq };
      default:
        return null;
    }
  };
  const server = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch(request, upgrade) {
      return upgrade.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
    },
    websocket: {
      open(ws) {
        sockets.add(ws);
      },
      close(ws) {
        sockets.delete(ws);
      },
      message(ws, raw) {
        const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, unknown> };
        if (message.id === undefined) return;
        if (state.gone) return;
        if (state.slow && message.method !== "_acpmux/peers") return;
        ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params) }));
      },
    },
  });
  return {
    port: server.port,
    state,
    /// A record of the running command, three past the last the pane has: the pane reads the two
    /// between (a gap read, one of the chat-open reads that count as waiting).
    skip() {
      const last = chat.events.at(-1)!;
      const event = {
        ...last,
        seq: last.seq + 3,
        at: Date.now(),
        dir: "in",
        kind: "tool_call_update",
        msg: update({ sessionUpdate: "tool_call_update", toolCallId: "r1", status: "in_progress" }),
      };
      const text = JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event });
      for (const socket of sockets) socket.send(text);
    },
    rows: chat.events.length,
    /// acpmux goes away under the open socket and a new one never answers: the pane reconnects and
    /// its handshake waits.
    lose() {
      for (const socket of sockets) (socket as unknown as { close(code: number): void }).close(1012);
    },
    stop: () => server.stop(true),
  };
}

/// The renderer main thread's work in a devtools.timeline trace, by event: count, total ms, the
/// largest style recalc (elements) and layout (dirty of total objects), and the paints.
function summarizeTrace(events: Record<string, any>[]) {
  const mains = new Set(
    events
      .filter((event) => event.ph === "M" && event.name === "thread_name" && event.args?.name === "CrRendererMain")
      .map((event) => `${event.pid}:${event.tid}`),
  );
  const byName = new Map<string, { count: number; ms: number }>();
  let styleElements = 0;
  let layoutDirty = 0;
  let layoutTotal = 0;
  for (const event of events) {
    if (event.ph !== "X" || (mains.size > 0 && !mains.has(`${event.pid}:${event.tid}`))) continue;
    const entry = byName.get(event.name) ?? { count: 0, ms: 0 };
    entry.count += 1;
    entry.ms += (event.dur ?? 0) / 1000;
    byName.set(event.name, entry);
    if (event.name === "UpdateLayoutTree") styleElements = Math.max(styleElements, event.args?.elementCount ?? 0);
    if (event.name === "Layout") {
      const dirty = event.args?.beginData?.dirtyObjects ?? 0;
      if (dirty > layoutDirty) {
        layoutDirty = dirty;
        layoutTotal = event.args?.beginData?.totalObjects ?? 0;
      }
    }
  }
  const named = (name: string) => {
    const entry = byName.get(name);
    return entry ? { count: entry.count, ms: Math.round(entry.ms * 10) / 10 } : { count: 0, ms: 0 };
  };
  return {
    style: { ...named("UpdateLayoutTree"), most_elements: styleElements },
    layout: { ...named("Layout"), most_dirty: layoutDirty, of_total: layoutTotal },
    paint: named("Paint"),
    prepaint: named("PrePaint"),
    layerize: named("Layerize"),
    raster: named("RasterTask"),
    animation_frames: named("FireAnimationFrame"),
    timers: named("TimerFire"),
    busiest: [...byName]
      .sort((a, b) => b[1].ms - a[1].ms)
      .slice(0, 10)
      .map(([name, entry]) => `${name} ${entry.count}x ${Math.round(entry.ms)}ms`),
  };
}

if (import.meta.main) {
  const dev = devRequested();
  const daemon = standInDaemon(TURNS);
  const served = await servePane(dev);
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 900, height: 760 } });
    await page.addInitScript(installTickProbe);
    page.on("pageerror", (error) => console.error(`bench page error: ${error.message}`));
    await page.goto(
      `${served.origin}#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon.port}/`)}&token=t&session=${PAPERCUT_CHAT}`,
    );
    await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 120_000 });
    await page.waitForSelector(".acpmux-row", { timeout: 120_000 });
    await page.waitForSelector(".acpmux-running-tray", { timeout: 30_000 });
    // fixed-wait: the open's own settling (read-ahead, fonts, first paints) is not a tick's.
    await page.waitForTimeout(3000);
    daemon.state.slow = SCENARIO === "slow";
    daemon.state.gone = SCENARIO === "lost";
    if (SCENARIO === "lost") daemon.lose();
    else daemon.skip();
    // The line shows once the read has waited HOST_ERROR_DEADLINE_MS (25 s).
    // The line shows once the read (slow) or the handshake (lost) has waited HOST_ERROR_DEADLINE_MS
    // (25 s); a lost socket may say "Reconnecting…" instead, so `lost` waits the deadline out.
    if (SCENARIO === "lost") await page.waitForTimeout(32_000);
    else await page.waitForSelector(".acpmux-host-line-group[data-host-waiting]", { timeout: 120_000 });
    // fixed-wait: the line's own arrival.
    await page.waitForTimeout(1500);
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Performance.enable", { timeDomain: "threadTicks" });
    const thread = async () => {
      const { metrics } = (await cdp.send("Performance.getMetrics")) as { metrics: { name: string; value: number }[] };
      return (metrics.find((metric) => metric.name === "ThreadTime")?.value ?? 0) * 1000;
    };
    const clockText = () =>
      page.evaluate(
        () =>
          document.querySelector(".acpmux-dock .acpmux-host-line, .acpmux-dock .acpmux-host-line-group, .ui-notice")
            ?.textContent ?? "",
      );
    const before = await clockText();
    await page.evaluate(() => {
      (window as any).cmuxAcpmuxDebug.renders();
      (window as any).__tickProbe.armed = true;
    });
    const metric = async () => {
      const { metrics } = (await cdp.send("Performance.getMetrics")) as { metrics: { name: string; value: number }[] };
      return Object.fromEntries(metrics.map((entry) => [entry.name, entry.value]));
    };
    const metricsStart = await metric();
    const cpuStart = await thread();
    // The renderer's own record of the window (devtools.timeline): each style recalc's element
    // count, each layout's dirty and total objects, each paint, so a tick that restyles or lays out
    // the whole transcript shows as such.
    const traced: Record<string, any>[] = [];
    cdp.on("Tracing.dataCollected", (event: { value: Record<string, any>[] }) => traced.push(...event.value));
    const tracingDone = new Promise<void>((resolve) => cdp.once("Tracing.tracingComplete", () => resolve()));
    await cdp.send("Tracing.start", {
      traceConfig: { includedCategories: ["devtools.timeline", "disabled-by-default-devtools.timeline"] },
      transferMode: "ReportEvents",
    } as never);
    // fixed-wait: the measured window itself.
    await page.waitForTimeout(SECONDS * 1000);
    const cpuEnd = await thread();
    const metricsEnd = await metric();
    await cdp.send("Tracing.end");
    await tracingDone;
    const timeline = summarizeTrace(traced);
    const result = await page.evaluate(() => {
      const probe = (window as any).__tickProbe;
      probe.armed = false;
      return {
        probe: { ...probe, names: [...probe.names].sort((a: any, b: any) => b[1] - a[1]).slice(0, 25) } as unknown,
        renders: (window as any).cmuxAcpmuxDebug.renders() as Record<string, number>,
        rows: document.querySelectorAll(".acpmux-row").length,
        clocks: [
          ...document.querySelectorAll(
            ".acpmux-host-line-message, .cv-activity__time, .cv-worked__time, .acpmux-running-tray__time",
          ),
        ]
          .map((node) => node.textContent?.trim())
          .filter(Boolean),
      };
    });
    const after = await clockText();
    const probe = result.probe as Probe;
    // One page-clock tick a second (pageClock.ts subscribePageSecond).
    const ticks = SECONDS;
    const sum = (prefix: string) =>
      Object.entries(result.renders)
        .filter(([name]) => name.startsWith(prefix))
        .reduce((total, [, value]) => total + value, 0);
    const per = (value: number) => Math.round((value / ticks) * 100) / 100;
    const longestLoaf = probe.loaf.reduce((most, entry) => (entry.duration > most.duration ? entry : most), {
      duration: 0,
      blocking: 0,
      scripts: [] as string[],
    });
    const report = {
      build: dev ? "dev" : "production",
      scenario: SCENARIO,
      turns: TURNS,
      records: daemon.rows,
      mounted_rows: result.rows,
      seconds: SECONDS,
      waiting_line: [before, after],
      cpu_ms_per_tick: Math.round(((cpuEnd - cpuStart) / ticks) * 100) / 100,
      // Per tick: style recalcs and layouts, and their time (CDP Performance).
      style_ms_per_tick: per((metricsEnd.RecalcStyleDuration! - metricsStart.RecalcStyleDuration!) * 1000),
      layout_ms_per_tick: per((metricsEnd.LayoutDuration! - metricsStart.LayoutDuration!) * 1000),
      script_ms_per_tick: per((metricsEnd.ScriptDuration! - metricsStart.ScriptDuration!) * 1000),
      styles_per_tick: per(metricsEnd.RecalcStyleCount! - metricsStart.RecalcStyleCount!),
      layouts_per_tick: per(metricsEnd.LayoutCount! - metricsStart.LayoutCount!),
      timeline,
      commits_per_tick: per(probe.commits),
      fibers_per_tick: per(probe.fibers),
      pane_renders: per(result.renders.pane ?? 0),
      transcript_renders: per(result.renders.transcript ?? 0),
      row_renders: per(sum("row:") + sum("frame:") + sum("content:")),
      composer_renders: per(sum("composer")),
      // The longest Long Animation Frame (Chromium reports frames of 50 ms or more; 0: none).
      longest_frame_ms: Math.round(longestLoaf.duration),
      long_frames: probe.loaf.length,
      longest_loaf: longestLoaf,
      rendered: probe.names,
      why: probe.why,
      counters: Object.entries(result.renders)
        .sort((a, b) => b[1] - a[1])
        .slice(0, 12),
      clocks: result.clocks,
    };
    console.log(`CHAT-TICK-CLOCKS ${JSON.stringify(report)}`);
  } finally {
    await browser.close();
    await served.close();
    daemon.stop();
  }
}
