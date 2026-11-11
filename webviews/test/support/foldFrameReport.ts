// What one chat animation costs, frame by frame, in a real browser: the shared harness behind
// chat-fold-frame-budget-browser.test.ts (Leo, 2026-11-09, on a turn's collapse and expand: "It
// just, like, lags pretty heavily ... I don't know why it's lagging so much").
//
// `installFoldProbe` runs before the page's scripts and counts, while a measurement is on:
// - geometry reads from script (getBoundingClientRect, offset*, client*, scroll* getters), each of
//   which lays the page out again when a write came before it;
// - ResizeObserver callbacks and the entries they carry;
// - React commits (a stub of the DevTools hook, which React calls on every commit);
// - painted frames (one requestAnimationFrame per frame) and long tasks.
// `measureToggle` runs one toggle between a start and the view's rest and adds:
// - the transcript rows React drew again, mounted, or remounted (perf.ts `renders`);
// - on Chromium, from a DevTools trace of the same window, every Layout and style recalculation, the
//   layout objects and elements each touched, and how many of them script forced (a Layout inside a
//   script task rather than the frame's own rendering step).
import type { CDPSession, Page } from "playwright";

export type FoldCost = {
  /// The toggle's name.
  step: string;
  /// Painted frames from the click to rest.
  frames: number;
  /// Frame intervals, ms.
  p50: number;
  p95: number;
  worst: number;
  /// The share of frames that took at most SMOOTH_MS (a frame and a half at 60 Hz).
  smooth: number;
  /// Long tasks (over 50 ms; Chromium only).
  longTasks: number;
  /// React commits.
  commits: number;
  /// Distinct transcript rows React drew again, and all their renders.
  rowsRendered: number;
  rowRenders: number;
  /// Rows mounted, and rows remounted in place.
  mounts: number;
  remounts: number;
  /// Geometry reads from script.
  reads: number;
  /// ResizeObserver callbacks and the entries they carried.
  resizeCallbacks: number;
  resizeEntries: number;
  /// Chromium trace: Layout passes, how many script forced, and per frame.
  layouts?: number;
  forcedLayouts?: number;
  layoutsPerFrame?: number;
  /// The most layout objects one Layout pass touched (`totalObjects`), and their sum.
  layoutObjectsMax?: number;
  /// Style recalculations, and the most elements one restyled.
  styleRecalcs?: number;
  styleElementsMax?: number;
  /// Script, layout and style time on the main thread over the window, ms.
  layoutMs?: number;
  styleMs?: number;
  scriptMs?: number;
  paintMs?: number;
  /// Rows mounted at rest.
  mounted: number;
};

type Probe = {
  on: boolean;
  reads: number;
  ro: number;
  roEntries: number;
  commits: number;
  frames: number[];
  longTasks: number;
  /// Bumped by each measurement, so a frame loop from an earlier one stops.
  run: number;
};

declare global {
  interface Window {
    __foldProbe: Probe;
  }
}

/// The page side, installed before any of the page's scripts: closes over nothing.
function defineFoldProbe() {
  if (window.__foldProbe) return;
  const probe: Probe = { on: false, reads: 0, ro: 0, roEntries: 0, commits: 0, frames: [], longTasks: 0, run: 0 };
  window.__foldProbe = probe;
  const countGetter = (proto: object, name: string) => {
    const own = Object.getOwnPropertyDescriptor(proto, name);
    if (!own?.get) return;
    const get = own.get;
    Object.defineProperty(proto, name, {
      ...own,
      get(this: unknown) {
        if (probe.on) probe.reads += 1;
        return get.call(this);
      },
    });
  };
  const countMethod = (proto: Record<string, unknown>, name: string) => {
    const method = proto[name] as ((...args: unknown[]) => unknown) | undefined;
    if (typeof method !== "function") return;
    proto[name] = function (this: unknown, ...args: unknown[]) {
      if (probe.on) probe.reads += 1;
      return method.apply(this, args);
    };
  };
  for (const name of ["getBoundingClientRect", "getClientRects"])
    countMethod(Element.prototype as unknown as Record<string, unknown>, name);
  for (const name of ["offsetHeight", "offsetWidth", "offsetTop", "offsetLeft"])
    countGetter(HTMLElement.prototype, name);
  for (const name of ["clientHeight", "clientWidth", "scrollHeight", "scrollWidth", "scrollTop"])
    countGetter(Element.prototype, name);
  const Native = window.ResizeObserver;
  if (Native)
    window.ResizeObserver = class extends Native {
      constructor(callback: ResizeObserverCallback) {
        super((entries, observer) => {
          if (probe.on) {
            probe.ro += 1;
            probe.roEntries += entries.length;
          }
          callback(entries, observer);
        });
      }
    };
  // React reports each commit to the DevTools hook; React Refresh wraps this stub when it loads.
  const hooks = window as unknown as { __REACT_DEVTOOLS_GLOBAL_HOOK__?: Record<string, unknown> };
  if (!hooks.__REACT_DEVTOOLS_GLOBAL_HOOK__) {
    const renderers = new Map<number, unknown>();
    hooks.__REACT_DEVTOOLS_GLOBAL_HOOK__ = {
      renderers,
      supportsFiber: true,
      isDisabled: false,
      inject(renderer: unknown) {
        const id = renderers.size + 1;
        renderers.set(id, renderer);
        return id;
      },
      onScheduleFiberRoot() {},
      onCommitFiberRoot() {
        if (probe.on) probe.commits += 1;
      },
      onCommitFiberUnmount() {},
      onPostCommitFiberRoot() {},
      checkDCE() {},
    };
  }
  try {
    new PerformanceObserver((list) => {
      if (probe.on) probe.longTasks += list.getEntries().length;
    }).observe({ type: "longtask", buffered: false });
  } catch {
    // WebKit has no long task entries.
  }
}

export async function installFoldProbe(page: Page): Promise<void> {
  await page.addInitScript(defineFoldProbe);
}

type TraceEvent = {
  name: string;
  ph: string;
  ts: number;
  dur?: number;
  tid: number;
  pid: number;
  args?: { beginData?: { totalObjects?: number; dirtyObjects?: number }; elementCount?: number };
};

/// Script tasks a Layout inside of was forced by script, not run by the frame's rendering step.
const SCRIPT = new Set(["FunctionCall", "EventDispatch", "TimerFire", "RunMicrotasks", "v8.callFunction"]);
/// Script tasks whose time counts as script (outermost only), and the paint steps.
const TASKS = new Set([...SCRIPT, "FireAnimationFrame", "ResizeObserverCallback", "HitTest"]);
const PAINT = new Set(["PrePaint", "Paint", "Layerize", "UpdateLayer", "Commit"]);

async function startTrace(cdp: CDPSession): Promise<void> {
  await cdp.send("Tracing.start", {
    traceConfig: {
      recordMode: "recordAsMuchAsPossible",
      includedCategories: ["devtools.timeline", "disabled-by-default-devtools.timeline", "blink.user_timing"],
    },
    transferMode: "ReportEvents",
  });
}

async function stopTrace(cdp: CDPSession): Promise<TraceEvent[]> {
  const events: TraceEvent[] = [];
  // The protocol types a trace event's fields loosely; these are the ones read here.
  const onData = (data: { value: object[] }) => events.push(...(data.value as TraceEvent[]));
  cdp.on("Tracing.dataCollected", onData);
  const done = new Promise<void>((resolve) => cdp.once("Tracing.tracingComplete", () => resolve()));
  await cdp.send("Tracing.end");
  await done;
  cdp.off("Tracing.dataCollected", onData);
  return events;
}

/// Layout and style work in a trace, on the renderer's main thread.
function traceCost(events: TraceEvent[]) {
  const main = events.find((event) => event.name === "Layout" || event.name === "UpdateLayoutTree");
  const onMain = main ? events.filter((event) => event.pid === main.pid && event.tid === main.tid) : [];
  const scripts = onMain.filter((event) => event.ph === "X" && SCRIPT.has(event.name));
  const layouts = onMain.filter((event) => event.name === "Layout" && event.ph === "X");
  const styles = onMain.filter((event) => event.name === "UpdateLayoutTree" && event.ph === "X");
  const tasks = onMain.filter((event) => event.ph === "X" && TASKS.has(event.name));
  const topTasks = tasks.filter(
    (event) =>
      !tasks.some(
        (outer) =>
          outer !== event && outer.ts <= event.ts && event.ts + (event.dur ?? 0) <= outer.ts + (outer.dur ?? 0),
      ),
  );
  const paints = onMain.filter((event) => event.ph === "X" && PAINT.has(event.name));
  const inScript = (event: TraceEvent) =>
    scripts.some((script) => script.ts <= event.ts && event.ts + (event.dur ?? 0) <= script.ts + (script.dur ?? 0));
  return {
    layouts: layouts.length,
    forcedLayouts: layouts.filter(inScript).length,
    layoutObjectsMax: Math.max(0, ...layouts.map((event) => event.args?.beginData?.totalObjects ?? 0)),
    styleRecalcs: styles.length,
    styleElementsMax: Math.max(0, ...styles.map((event) => event.args?.elementCount ?? 0)),
    layoutMs: layouts.reduce((sum, event) => sum + (event.dur ?? 0), 0) / 1000,
    styleMs: styles.reduce((sum, event) => sum + (event.dur ?? 0), 0) / 1000,
    scriptMs: topTasks.reduce((sum, event) => sum + (event.dur ?? 0), 0) / 1000,
    paintMs: paints.reduce((sum, event) => sum + (event.dur ?? 0), 0) / 1000,
  };
}

const r1 = (value: number) => Math.round(value * 10) / 10;

/// A frame at most this long reads as smooth: a frame and a half at 60 Hz.
export const SMOOTH_MS = 25;

/// Runs `act` (a click) with the probe on, waits for `rest`, and returns what the window cost.
export async function measureToggle(
  page: Page,
  step: string,
  act: () => Promise<void>,
  rest: () => Promise<void>,
  cdp?: CDPSession,
): Promise<FoldCost> {
  await page.evaluate(() => {
    const perf = (window as unknown as { __acpmuxPerf?: { enabled: boolean; resetRenders(): void } }).__acpmuxPerf;
    if (perf) {
      perf.enabled = true;
      perf.resetRenders();
    }
    const probe = window.__foldProbe;
    Object.assign(probe, { reads: 0, ro: 0, roEntries: 0, commits: 0, frames: [], longTasks: 0, on: true });
    const run = (probe.run += 1);
    const tick = (now: number) => {
      if (!probe.on || probe.run !== run) return;
      probe.frames.push(now);
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  });
  if (cdp) await startTrace(cdp);
  await act();
  await rest();
  const page_ = await page.evaluate(() => {
    const probe = window.__foldProbe;
    probe.on = false;
    const perf = (window as unknown as { __acpmuxPerf?: { enabled: boolean; renders: Map<string, number> } })
      .__acpmuxPerf;
    const renders = [...(perf?.renders ?? new Map<string, number>())];
    if (perf) perf.enabled = false;
    const rows = renders.filter(([name]) => name.startsWith("row:"));
    return {
      frames: probe.frames,
      reads: probe.reads,
      ro: probe.ro,
      roEntries: probe.roEntries,
      commits: probe.commits,
      longTasks: probe.longTasks,
      rowsRendered: rows.length,
      rowRenders: rows.reduce((sum, [, count]) => sum + count, 0),
      mounts: renders.filter(([name]) => name.startsWith("mount:")).length,
      remounts: renders.filter(([name]) => name.startsWith("remount:")).length,
      mounted: document.querySelectorAll(".acpmux-row").length,
    };
  });
  const trace = cdp ? traceCost(await stopTrace(cdp)) : undefined;
  const intervals = page_.frames
    .slice(1)
    .map((at, index) => at - page_.frames[index]!)
    .sort((a, b) => a - b);
  const at = (p: number) => intervals[Math.min(intervals.length - 1, Math.round((intervals.length - 1) * p))] ?? 0;
  const frames = Math.max(1, intervals.length);
  return {
    step,
    frames: intervals.length,
    p50: r1(at(0.5)),
    p95: r1(at(0.95)),
    worst: r1(intervals.at(-1) ?? 0),
    smooth: r1((intervals.filter((each) => each <= SMOOTH_MS).length / frames) * 100) / 100,
    longTasks: page_.longTasks,
    commits: page_.commits,
    rowsRendered: page_.rowsRendered,
    rowRenders: page_.rowRenders,
    mounts: page_.mounts,
    remounts: page_.remounts,
    reads: page_.reads,
    resizeCallbacks: page_.ro,
    resizeEntries: page_.roEntries,
    mounted: page_.mounted,
    ...(trace && {
      ...trace,
      layoutsPerFrame: r1(trace.layouts / frames),
      layoutMs: r1(trace.layoutMs),
      styleMs: r1(trace.styleMs),
      scriptMs: r1(trace.scriptMs),
      paintMs: r1(trace.paintMs),
    }),
  };
}

/// One line per toggle, for the test's log and a PR's table.
export function costLine(label: string, cost: FoldCost): string {
  const trace =
    cost.layouts === undefined
      ? ""
      : ` layouts ${cost.layouts} (${cost.forcedLayouts} forced, ${cost.layoutsPerFrame}/frame, ≤${cost.layoutObjectsMax} objects, ${cost.layoutMs} ms)` +
        ` styles ${cost.styleRecalcs} (≤${cost.styleElementsMax} elements, ${cost.styleMs} ms) script ${cost.scriptMs} ms paint ${cost.paintMs} ms`;
  return (
    `${label} ${cost.step}: ${cost.frames} frames p50 ${cost.p50} p95 ${cost.p95} worst ${cost.worst} ms, ` +
    `${Math.round(cost.smooth * 100)}% smooth; ` +
    `long ${cost.longTasks}; commits ${cost.commits}; rows drawn ${cost.rowsRendered} (${cost.rowRenders} renders, ` +
    `${cost.mounts} mounts, ${cost.remounts} remounts) of ${cost.mounted} mounted; reads ${cost.reads}; ` +
    `RO ${cost.resizeCallbacks}/${cost.resizeEntries}${trace}`
  );
}
