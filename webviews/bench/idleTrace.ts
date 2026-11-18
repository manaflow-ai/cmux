// l10n-allow-file: benchmark output, not shipped UI.
// What every renderer of a browser runs over an idle window, from one browser-wide Chrome trace: CPU time per thread
// (main, compositor, the thread pool's workers), the busiest event names on each, and per renderer the main-thread
// frames (BeginMainThreadFrame) beside the frames' own work, so a frame no style, layout or paint asked for and a
// worker's GC or compile read apart. Optionally writes the trace (gzip) for a closer look.
/// <reference types="bun" />
import fs from "node:fs";
import zlib from "node:zlib";
import type { CDPSession } from "playwright";

const CATEGORIES = [
  "__metadata",
  "toplevel",
  "base",
  "cc",
  "blink",
  "v8",
  "devtools.timeline",
  "disabled-by-default-devtools.timeline",
  "disabled-by-default-devtools.timeline.frame",
  "disabled-by-default-v8.gc",
  "disabled-by-default-cc.debug.scheduler",
  "blink.animations",
  "renderer.scheduler",
];

type TraceEvent = {
  name: string;
  cat?: string;
  ph: string;
  pid: number;
  tid: number;
  ts: number;
  dur?: number;
  tdur?: number;
  args?: { name?: string; data?: Record<string, unknown>; [key: string]: unknown };
};

/// Traces `seconds` of the whole browser through `cdp` (Browser.newBrowserCDPSession) and returns a summary.
export async function idleTrace(cdp: CDPSession, seconds: number, file?: string): Promise<string> {
  const stop = await startIdleTrace(cdp);
  // fixed-wait: the window itself.
  await new Promise((resolve) => setTimeout(resolve, seconds * 1000));
  return stop(file);
}

/// Starts a browser-wide trace; the returned stop ends it and summarizes the time between.
export async function startIdleTrace(cdp: CDPSession): Promise<(file?: string) => Promise<string>> {
  const events: TraceEvent[] = [];
  const collect = (payload: { value: object[] }) => {
    for (const event of payload.value) events.push(event as TraceEvent);
  };
  cdp.on("Tracing.dataCollected", collect);
  await cdp.send("Tracing.start", {
    transferMode: "ReportEvents",
    traceConfig: { includedCategories: CATEGORIES, excludedCategories: ["*"] },
  });
  const began = performance.now();
  return async (file?: string) => {
    const seconds = (performance.now() - began) / 1000;
    const done = new Promise<void>((resolve) => cdp.once("Tracing.tracingComplete", () => resolve()));
    await cdp.send("Tracing.end");
    await done;
    cdp.off("Tracing.dataCollected", collect);
    if (file) fs.writeFileSync(file, zlib.gzipSync(JSON.stringify({ traceEvents: events })));
    return summarize(events, seconds);
  };
}

export function summarize(events: TraceEvent[], seconds: number): string {
  const threads = new Map<string, string>();
  const renderers = new Set<number>();
  for (const event of events) {
    if (event.ph !== "M") continue;
    if (event.name === "thread_name" && event.args?.name) threads.set(`${event.pid}:${event.tid}`, event.args.name);
    if (event.name === "process_name" && event.args?.name === "Renderer") renderers.add(event.pid);
  }
  const threadOf = (event: TraceEvent) => (threads.get(`${event.pid}:${event.tid}`) ?? "?").replace(/\d+$/, "");
  // Per thread kind (all renderers summed): thread time of the top-level tasks, and each event name's wall time.
  const taskMs = new Map<string, number>();
  const byName = new Map<string, Map<string, { ms: number; n: number }>>();
  // Per renderer: main frames, and what ran on its main thread.
  const perRenderer = new Map<number, { mainFrames: number; draws: number; names: Map<string, number> }>();
  for (const event of events) {
    if (!renderers.has(event.pid) || event.ph !== "X") continue;
    const thread = threadOf(event);
    const ms = (event.dur ?? 0) / 1000;
    if (
      event.name === "ThreadControllerImpl::RunTask" ||
      event.name === "ThreadPool_RunTask" ||
      event.name === "RunTask"
    ) {
      taskMs.set(thread, (taskMs.get(thread) ?? 0) + (event.tdur ?? event.dur ?? 0) / 1000);
    }
    const names = byName.get(thread) ?? new Map<string, { ms: number; n: number }>();
    byName.set(thread, names);
    const one = names.get(event.name) ?? { ms: 0, n: 0 };
    one.ms += ms;
    one.n += 1;
    names.set(event.name, one);
  }
  for (const event of events) {
    if (!renderers.has(event.pid)) continue;
    const row = perRenderer.get(event.pid) ?? { mainFrames: 0, draws: 0, names: new Map<string, number>() };
    perRenderer.set(event.pid, row);
    const thread = threadOf(event);
    if (event.name === "DrawFrame") row.draws += 1;
    if (thread !== "CrRendererMain") continue;
    if (event.name === "BeginMainThreadFrame") row.mainFrames += 1;
    if (event.ph === "X" || event.ph === "I" || event.ph === "i" || event.ph === "n")
      row.names.set(event.name, (row.names.get(event.name) ?? 0) + 1);
  }
  // Task posting sites on the thread pool (the toplevel task's src_file/src_func), the closest a trace comes to who.
  const poolSites = new Map<string, { ms: number; n: number }>();
  for (const event of events) {
    if (!renderers.has(event.pid) || event.ph !== "X" || !threadOf(event).startsWith("ThreadPool")) continue;
    if (event.name !== "ThreadPool_RunTask" && event.name !== "ThreadControllerImpl::RunTask") continue;
    const src = event.args?.src as { file_name?: string; function_name?: string } | undefined;
    const site =
      (event.args?.src_func as string | undefined) ??
      src?.function_name ??
      (event.args?.posted_from as { function_name?: string } | undefined)?.function_name ??
      JSON.stringify(event.args ?? {}).slice(0, 120);
    const one = poolSites.get(site) ?? { ms: 0, n: 0 };
    one.ms += (event.tdur ?? event.dur ?? 0) / 1000;
    one.n += 1;
    poolSites.set(site, one);
  }
  const lines: string[] = [`  trace: ${events.length} events over ${seconds}s, ${renderers.size} renderer(s)`];
  for (const [thread, ms] of [...taskMs].sort((a, b) => b[1] - a[1]))
    lines.push(`    thread ${thread}: tasks ${(ms / seconds).toFixed(2)} ms/s (thread time)`);
  for (const [thread, names] of [...byName].sort((a, b) => (taskMs.get(b[0]) ?? 0) - (taskMs.get(a[0]) ?? 0))) {
    const top = [...names].sort((a, b) => b[1].ms - a[1].ms).slice(0, 14);
    lines.push(
      `    ${thread} top: ${top.map(([name, { ms, n }]) => `${name} ${(ms / seconds).toFixed(2)}ms/s x${(n / seconds).toFixed(1)}/s`).join("; ")}`,
    );
  }
  if (poolSites.size)
    lines.push(
      `    pool tasks by site: ${[...poolSites]
        .sort((a, b) => b[1].ms - a[1].ms)
        .slice(0, 10)
        .map(([site, { ms, n }]) => `${site} ${(ms / seconds).toFixed(2)}ms/s x${(n / seconds).toFixed(1)}/s`)
        .join("; ")}`,
    );
  for (const [pid, row] of perRenderer) {
    const top = [...row.names]
      .sort((a, b) => b[1] - a[1])
      .slice(0, 16)
      .map(([name, n]) => `${name} ${(n / seconds).toFixed(1)}`)
      .join(", ");
    lines.push(
      `    renderer ${pid}: ${(row.mainFrames / seconds).toFixed(1)} main frames/s, ${(row.draws / seconds).toFixed(1)} draws/s; main-thread events/s: ${top}`,
    );
  }
  return lines.join("\n");
}
