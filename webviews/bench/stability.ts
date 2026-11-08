// l10n-allow-file: benchmark output, not shipped UI.
// Layout stability and idle cost of a web UI surface, for the web UI benches (Leo, 2026-11-03: "things should be
// instant and not shift layouts AND not take many resources"). Three numbers per surface:
//   settled       ms from the interaction's start to the last frame in which an element's box changed. A surface
//                 that draws its final layout in its first frame has settled == first paint.
//   cls           a CLS-style score: in Chromium the layout-shift entries' sum (hadRecentInput ignored); WebKit has
//                 no such entries, so there it is a frame-by-frame box diff (the gallery's shift.ts score).
//   idle wakeups  after settling, IDLE_MS of nothing: the timer, interval, idle and animation-frame callbacks that
//                 still ran, plus the CSS and Web animations still running at the end. A still page wakes 0 times.
//   idle cpu ms   Chromium only: the renderer's task time over the same window (CDP Performance TaskDuration).
// `installStabilityProbe` is a page init script (Playwright `addInitScript`): it wraps the timer and frame APIs
// before the page's own code runs and samples element boxes on every frame until `settled()` stops it. Its own
// frames use the unwrapped requestAnimationFrame, so they never count as the page's wakeups.
/// <reference types="bun" />
import type { BrowserContext, CDPSession, Page } from "playwright";

export const IDLE_MS = 5000;
/// The probe samples at most this many elements per frame, in document order, so a huge page stays measurable.
export const SAMPLE_CAP = 3000;

export type IdleCount = {
  timeouts: number;
  intervals: number;
  frames: number;
  idleCallbacks: number;
  /** CSS and Web animations whose playState is running at the end of the window. */
  animations: number;
  /** The page's own loop count (cmuxDebug.loops(), src/ui/pageLoops.ts: registered clocks running plus infinite
   *  animations) at the end of the window, where the page installs it; null where it does not. */
  pageLoops: number | null;
  /** Where the callbacks came from (a stack frame or two), most first, and the running animations. */
  sources: string[];
};

export type Settled = {
  /** The last frame (page performance.now()) whose boxes changed. */
  lastChange: number;
  /** The first frame `content` matched in, or 0. */
  firstContent: number;
  frames: number;
  /** The gallery play steps' starts (performance.now()), in order. */
  actionStarts: number[];
  /** Optional, bounded frame diagnostics. Does not change which frames count as changed. */
  boxChanges?: { at: number; fonts: string; changes: string[]; animations: string[] }[];
};

type Probe = {
  /** Stops the box sampler; the last frame (performance.now()) whose boxes changed, and the frames sampled. */
  settled(): Settled;
  startIdle(): void;
  stopIdle(): IdleCount;
};

declare global {
  interface Window {
    __cmuxStability?: Probe;
  }
}

/** The init script. Self-contained: Playwright serializes it into the page. */
export function installStabilityProbe(options: {
  sampleCap: number;
  boxes: boolean;
  content?: string;
  traceBoxes?: boolean;
}): void {
  const w = window;
  if (w.__cmuxStability) return;
  const raf = w.requestAnimationFrame.bind(w);
  const realTimeout = w.setTimeout.bind(w);
  const realInterval = w.setInterval.bind(w);
  const realIdle = w.requestIdleCallback?.bind(w);
  let counting = false;
  const counts = { timeouts: 0, intervals: 0, frames: 0, idleCallbacks: 0 };
  const sites = new Map<string, number>();
  // The registering stack, kept as an Error: V8 formats `stack` only when it is read (in the idle window).
  const where = (error: Error | undefined) =>
    error?.stack
      ?.split("\n")
      .map((line) => line.trim())
      .filter(
        (line) =>
          line && line !== "Error" && !line.includes("installStabilityProbe") && !/^at (w\.|window\.)/.test(line),
      )
      .slice(1, 3)
      .join(" < ") || "unknown";
  const note = (kind: keyof typeof counts, error: Error | undefined) => {
    counts[kind] += 1;
    const key = `${kind}: ${where(error)}`;
    sites.set(key, (sites.get(key) ?? 0) + 1);
  };
  type Handler = (...args: unknown[]) => unknown;
  w.setTimeout = ((handler: TimerHandler, ms?: number, ...args: unknown[]) => {
    if (typeof handler !== "function") return realTimeout(handler, ms, ...args);
    const error = new Error();
    return realTimeout(
      function (this: unknown, ...rest: unknown[]) {
        if (counting) note("timeouts", error);
        return (handler as Handler).apply(this, rest);
      },
      ms,
      ...args,
    );
  }) as typeof w.setTimeout;
  w.setInterval = ((handler: TimerHandler, ms?: number, ...args: unknown[]) => {
    if (typeof handler !== "function") return realInterval(handler, ms, ...args);
    const error = new Error();
    return realInterval(
      function (this: unknown, ...rest: unknown[]) {
        if (counting) note("intervals", error);
        return (handler as Handler).apply(this, rest);
      },
      ms,
      ...args,
    );
  }) as typeof w.setInterval;
  w.requestAnimationFrame = (callback: FrameRequestCallback) => {
    // A stack per frame request only inside the window: outside it, frames are the page's load and not counted.
    const error = counting ? new Error() : undefined;
    return raf((time) => {
      if (counting) note("frames", error);
      callback(time);
    });
  };
  if (realIdle)
    w.requestIdleCallback = (callback: IdleRequestCallback, options?: IdleRequestOptions) => {
      const error = new Error();
      return realIdle((deadline) => {
        if (counting) note("idleCallbacks", error);
        callback(deadline);
      }, options);
    };

  // The box sampler: every frame, the boxes of the first `sampleCap` elements; a frame differs from the one before
  // when an element appeared, went away or moved or resized by more than half a CSS px. A looping animation's
  // element (a spinner) and what it contains are left out: they never settle by design and count as wakeups.
  // Off for a bench whose own timings must not pay for it (chat-switch.bench.ts uses the idle window only).
  let sampling = options.boxes;
  let lastChange = 0;
  // The first frame in which `options.content` matched: the surface's first paint, past any loading placeholder.
  let firstContent = 0;
  let frames = 0;
  let previous = new Map<Element, [number, number, number, number]>();
  const boxChanges: NonNullable<Settled["boxChanges"]> = [];
  const label = (element: Element) => {
    const row = element.closest("[data-row-id]")?.getAttribute("data-row-id");
    return (
      `${element.tagName.toLowerCase()}${element.id ? `#${element.id}` : ""}` +
      `${typeof element.className === "string" && element.className ? `.${element.className.trim().split(/\s+/).join(".")}` : ""}` +
      (row ? ` [row=${row}]` : "")
    );
  };
  const sample = () => {
    if (!sampling) return;
    frames += 1;
    if (!firstContent && options.content && document.querySelector(options.content)) firstContent = performance.now();
    const looping = (document.getAnimations?.() ?? [])
      .filter((a) => a.playState === "running" && a.effect?.getTiming().iterations === Infinity)
      .map((a) => (a.effect as KeyframeEffect | null)?.target)
      .filter((target): target is Element => target instanceof Element);
    const next = new Map<Element, [number, number, number, number]>();
    let changed = false;
    const changes: string[] = [];
    const all = document.body?.getElementsByTagName("*") ?? [];
    for (let index = 0; index < all.length && index < options.sampleCap; index++) {
      const element = all[index]!;
      if (looping.length && looping.some((target) => target === element || target.contains(element))) continue;
      const rect = element.getBoundingClientRect();
      const box: [number, number, number, number] = [rect.x, rect.y, rect.width, rect.height];
      next.set(element, box);
      if (changed && !options.traceBoxes) continue;
      const was = previous.get(element);
      if (!was || was.some((value, at) => Math.abs(value - box[at]!) > 0.5)) {
        changed = true;
        if (options.traceBoxes && changes.length < 12)
          changes.push(`${label(element)} ${was ? JSON.stringify(was) : "added"} -> ${JSON.stringify(box)}`);
      }
    }
    if (changed || next.size !== previous.size) {
      lastChange = performance.now();
      if (options.traceBoxes) {
        for (const element of previous.keys())
          if (!next.has(element) && changes.length < 12) changes.push(`${label(element)} removed`);
        boxChanges.push({
          at: lastChange,
          fonts: document.fonts?.status ?? "unknown",
          changes,
          animations: (document.getAnimations?.() ?? [])
            .filter((animation) => animation.playState === "running")
            .slice(0, 12)
            .map((animation) => {
              const target = (animation.effect as KeyframeEffect | null)?.target;
              return `${(animation as CSSAnimation).animationName ?? animation.id} ${target instanceof Element ? label(target) : "?"}`;
            }),
        });
        if (boxChanges.length > 120) boxChanges.shift();
      }
    }
    previous = next;
    raf(sample);
  };
  if (sampling) raf(sample);
  // The gallery play runner marks each step's start (`cmux-gallery-action-N-start`) and clears it after; an
  // observer still sees it, so an interaction's settle time can start where its step did.
  const actionStarts: number[] = [];
  try {
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries())
        if (/^cmux-gallery-action-\d+-start$/.test(entry.name)) actionStarts.push(entry.startTime);
    }).observe({ type: "mark" });
  } catch {
    // No mark entries here: a play surface falls back to its step's own settle time.
  }

  w.__cmuxStability = {
    settled() {
      sampling = false;
      previous = new Map();
      return {
        lastChange,
        firstContent,
        frames,
        actionStarts: [...actionStarts],
        ...(options.traceBoxes ? { boxChanges } : {}),
      };
    },
    startIdle() {
      for (const key of Object.keys(counts) as (keyof typeof counts)[]) counts[key] = 0;
      sites.clear();
      counting = true;
    },
    stopIdle() {
      counting = false;
      const running = (document.getAnimations?.() ?? []).filter((a) => a.playState === "running");
      const label = (a: Animation) => {
        const target = (a.effect as KeyframeEffect | null)?.target;
        const name =
          (a as Animation & { animationName?: string; transitionProperty?: string }).animationName ??
          (a as Animation & { transitionProperty?: string }).transitionProperty ??
          a.id ??
          "animation";
        const owner =
          target instanceof Element
            ? `${target.tagName.toLowerCase()}${typeof target.className === "string" && target.className ? `.${target.className.split(" ")[0]}` : ""}`
            : "?";
        return `animation: ${name} on ${owner}`;
      };
      for (const animation of running) {
        const key = label(animation);
        sites.set(key, (sites.get(key) ?? 0) + 1);
      }
      // The page's own loop registry, beside the wrappers: it names the clock behind a timer.
      type Loops = { loops: number; clocks?: { items?: { name: string; running: boolean }[] } };
      const loops = (w as Window & { cmuxDebug?: { loops?: () => Loops } }).cmuxDebug?.loops?.();
      for (const clock of loops?.clocks?.items ?? []) if (clock.running) sites.set(`page clock: ${clock.name}`, 1);
      return {
        ...counts,
        pageLoops: loops ? loops.loops : null,
        animations: running.length,
        sources: [...sites.entries()].sort((a, b) => b[1] - a[1]).map(([key, n]) => `${n}x ${key}`),
      };
    },
  };
}

/** Adds the probe to every page the context opens; `boxes: false` leaves the box sampler (settled) off, and
 *  `content` is the selector whose first match marks the surface's first paint. */
export async function addStabilityProbe(
  context: BrowserContext,
  { boxes = true, content, traceBoxes = false }: { boxes?: boolean; content?: string; traceBoxes?: boolean } = {},
): Promise<void> {
  await context.addInitScript(installStabilityProbe, { sampleCap: SAMPLE_CAP, boxes, content, traceBoxes });
}

/** Where the page settled (the probe's box sampler); stops the sampler. */
export async function settledAt(page: Page): Promise<Settled> {
  return await page.evaluate(() => window.__cmuxStability!.settled());
}

export type Idle = IdleCount & { wakeups: number; cpuMs: number | null };

/** The task time (ms) the page's renderer has spent so far, or null without CDP (WebKit). */
async function taskMs(cdp: CDPSession | null): Promise<number | null> {
  if (!cdp) return null;
  const { metrics } = (await cdp.send("Performance.getMetrics")) as { metrics: { name: string; value: number }[] };
  const task = metrics.find((metric) => metric.name === "TaskDuration");
  return task ? task.value * 1000 : null;
}

/** The CDP session for a Chromium page's task time, with its metrics on; null in WebKit. */
export async function cpuSession(page: Page, chromium: boolean): Promise<CDPSession | null> {
  if (!chromium) return null;
  const cdp = await page.context().newCDPSession(page);
  await cdp.send("Performance.enable");
  return cdp;
}

/**
 * IDLE_MS of idleness on every page at once (each page counts its own callbacks; Chromium's task time is per
 * page's renderer), so N surfaces cost one window. Call `settledAt` first, so the sampler's own frames are gone.
 */
export async function measureIdle(pages: { page: Page; cdp: CDPSession | null }[], ms = IDLE_MS): Promise<Idle[]> {
  const before = await Promise.all(
    pages.map(async ({ page, cdp }) => {
      const cpu = await taskMs(cdp);
      await page.evaluate(() => window.__cmuxStability!.startIdle());
      return cpu;
    }),
  );
  await new Promise((resolve) => setTimeout(resolve, ms));
  return await Promise.all(
    pages.map(async ({ page, cdp }, index) => {
      const count = await page.evaluate(() => window.__cmuxStability!.stopIdle());
      const cpu = await taskMs(cdp);
      const start = before[index];
      return {
        ...count,
        wakeups: count.timeouts + count.intervals + count.frames + count.idleCallbacks + count.animations,
        cpuMs: cpu !== null && start !== null && start !== undefined ? cpu - start : null,
      };
    }),
  );
}

export const median = (values: readonly number[]) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)]!;
