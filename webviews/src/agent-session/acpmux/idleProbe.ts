// What a pane does while nobody touches it (`debug.agent_pane idle_probe`, bench_power.py idle-chats).
// For `ms` it counts, by call site, every animation frame, timeout and interval the page asks for,
// every DOM mutation by target, the running animations, and Chromium's long animation frames with
// their script attribution. The wrappers are put back when the window ends, so the page pays
// nothing for this outside the probe. A measurement tool: no product code reads it.

export type IdleProbeOptions = { ms?: number };

type Site = { count: number; sample: string };

const SITE_FRAMES = 3;

/** The first frames of the caller's stack outside this file, as one short key. */
function callSite(): string {
  const lines = (new Error().stack ?? "").split("\n").slice(1);
  const own = lines.filter((line) => !line.includes("idleProbe"));
  return own
    .slice(0, SITE_FRAMES)
    .map((line) => line.trim().replace(/^at /, "").slice(0, 160))
    .join(" < ");
}

function describe(node: Node | null): string {
  if (!node) return "?";
  const element = node instanceof Element ? node : node.parentElement;
  if (!element) return node.nodeName;
  const classes = [...element.classList].slice(0, 3).join(".");
  return `${element.tagName.toLowerCase()}${classes ? `.${classes}` : ""}`;
}

function top(map: Map<string, Site>, limit = 12) {
  return [...map.entries()]
    .sort((a, b) => b[1].count - a[1].count)
    .slice(0, limit)
    .map(([site, { count, sample }]) => ({ site, count, sample }));
}

/** A probe in its window: a second one would save the first one's wrappers and put them back for good. */
let probing = false;

export async function idleProbe(options: IdleProbeOptions = {}): Promise<Record<string, unknown>> {
  if (probing) return { error: "an idle probe is already running" };
  probing = true;
  try {
    return await probe(options);
  } finally {
    probing = false;
  }
}

async function probe(options: IdleProbeOptions): Promise<Record<string, unknown>> {
  const ms = Math.max(100, Math.min(30_000, options.ms ?? 10_000));
  const frames = new Map<string, Site>();
  const timeouts = new Map<string, Site>();
  const intervals = new Map<string, Site>();
  const mutations = new Map<string, Site>();
  const loafs: Record<string, unknown>[] = [];
  const note = (map: Map<string, Site>, key: string, sample: () => string) => {
    const site = map.get(key);
    if (site) site.count++;
    else map.set(key, { count: 1, sample: sample() });
  };
  const original = {
    raf: window.requestAnimationFrame,
    timeout: window.setTimeout,
    interval: window.setInterval,
  };
  const source = (callback: unknown) => (typeof callback === "function" ? String(callback).slice(0, 160) : "");
  window.requestAnimationFrame = function (callback: FrameRequestCallback) {
    note(frames, callSite(), () => source(callback));
    return original.raf.call(window, callback);
  };
  window.setTimeout = function (handler: TimerHandler, timeout?: number, ...rest: unknown[]) {
    note(timeouts, `${timeout ?? 0}ms ${callSite()}`, () => source(handler));
    return Reflect.apply(original.timeout, window, [handler, timeout, ...rest]) as number;
  } as typeof window.setTimeout;
  window.setInterval = function (handler: TimerHandler, timeout?: number, ...rest: unknown[]) {
    note(intervals, `${timeout ?? 0}ms ${callSite()}`, () => source(handler));
    return Reflect.apply(original.interval, window, [handler, timeout, ...rest]) as number;
  } as typeof window.setInterval;
  const observer = new MutationObserver((records) => {
    for (const record of records) note(mutations, `${record.type} ${describe(record.target)}`, () => "");
  });
  observer.observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
  let loafObserver: PerformanceObserver | undefined;
  try {
    loafObserver = new PerformanceObserver((list) => {
      for (const entry of list.getEntries() as (PerformanceEntry & {
        blockingDuration?: number;
        scripts?: {
          invoker?: string;
          invokerType?: string;
          sourceURL?: string;
          sourceFunctionName?: string;
          sourceCharPosition?: number;
          duration: number;
        }[];
      })[]) {
        if (loafs.length >= 40) break;
        loafs.push({
          duration: Math.round(entry.duration),
          blocking: Math.round(entry.blockingDuration ?? 0),
          scripts: (entry.scripts ?? []).slice(0, 5).map((script) => ({
            invoker: script.invoker,
            type: script.invokerType,
            source: `${script.sourceURL ?? ""}:${script.sourceCharPosition ?? ""} ${script.sourceFunctionName ?? ""}`,
            ms: Math.round(script.duration),
          })),
        });
      }
    });
    loafObserver.observe({ type: "long-animation-frame", buffered: false });
  } catch {
    loafObserver = undefined;
  }
  const started = performance.now();
  try {
    await new Promise<void>((resolve) => Reflect.apply(original.timeout, window, [resolve, ms]));
  } finally {
    window.requestAnimationFrame = original.raf;
    window.setTimeout = original.timeout;
    window.setInterval = original.interval;
    observer.disconnect();
    loafObserver?.disconnect();
  }
  const seconds = (performance.now() - started) / 1000;
  const animations = (document.getAnimations?.() ?? [])
    .filter((animation) => animation.playState === "running")
    .map((animation) => {
      const effect = animation.effect as KeyframeEffect | null;
      const properties = new Set<string>();
      for (const frame of effect?.getKeyframes?.() ?? [])
        for (const key of Object.keys(frame))
          if (!["offset", "easing", "composite", "computedOffset"].includes(key)) properties.add(key);
      return {
        name: (animation as CSSAnimation).animationName ?? animation.id ?? animation.constructor.name,
        target: describe(effect?.target ?? null),
        properties: [...properties],
        visible: effect?.target ? ((effect.target as Element).checkVisibility?.() ?? null) : null,
      };
    });
  const sum = (map: Map<string, Site>) => [...map.values()].reduce((total, site) => total + site.count, 0);
  return {
    seconds: Math.round(seconds * 10) / 10,
    visibility: document.visibilityState,
    focus: document.hasFocus(),
    per_second: {
      frames: Math.round((sum(frames) / seconds) * 10) / 10,
      timeouts: Math.round((sum(timeouts) / seconds) * 10) / 10,
      intervals: Math.round((sum(intervals) / seconds) * 10) / 10,
      mutations: Math.round((sum(mutations) / seconds) * 10) / 10,
    },
    frames: top(frames),
    timeouts: top(timeouts),
    intervals: top(intervals),
    mutations: top(mutations),
    animations: animations.slice(0, 20),
    animation_count: animations.length,
    long_frames: loafs,
  };
}
