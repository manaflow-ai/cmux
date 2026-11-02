// Injected with addInitScript: keep installLatencyProbe self-contained. Every active resource is
// owned by arm/calibrate and released by stop, completion or dispose; installation itself is idle.
export interface LatencySample {
  work: number;
  /** Input to the task after the response's rendering opportunity; not Event Timing INP. */
  paint: number;
  frames: number;
  longTasks: number[];
  maxFrameGap: number;
  input: string;
  frameGaps: number[];
  eventTiming: Array<{ name: string; durationMs: number; interactionId: number }> | null;
  reactCommits: number | null;
  instrumentation: { longTasks: boolean; eventTiming: boolean };
}

export interface LatencyProbe {
  frameInterval(): number;
  calibrate(): Promise<number>;
  arm(predicate: string, inputEvent?: string): void;
  /** For an in-page host command with no DOM input; call immediately before its effect. */
  markInput(kind?: string): void;
  stop(): void;
  dispose(): void;
  readonly state: "idle" | "armed" | "input" | "done";
  result(): LatencySample | null;
  error: string | null;
}

declare global {
  interface Window {
    __latency?: LatencyProbe;
    __latencyCheck?: () => unknown;
    /** Fixture's React Profiler onRender increments this monotonic counter. */
    __latencyReactCommits?: number;
  }
}

export function installLatencyProbe(): void {
  if (window.__latency) return;
  let state: LatencyProbe["state"] = "idle";
  let sample: LatencySample | null = null;
  let check: (() => boolean) | null = null;
  let frameId = 0;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let channel: MessageChannel | undefined;
  let calibration: (() => void) | undefined;
  let interval = 1000 / 60;
  let inputAt = 0;
  let previous = 0;
  let responseAt: number | null = null;
  let input = "";
  let commits: number | undefined;
  let frameGaps: number[] = [];
  const tasks: PerformanceEntry[] = [];
  const events: PerformanceEntry[] = [];
  const supported = { longTasks: false, eventTiming: false };
  const observers: PerformanceObserver[] = [];
  const kinds = ["pointerdown", "mousedown", "keydown", "beforeinput", "input", "click", "paste", "wheel", "touchmove"];
  let activeKinds = kinds;
  const mutation = new MutationObserver(() => observeResponse());

  const stop = () => {
    cancelAnimationFrame(frameId);
    frameId = 0;
    if (timer !== undefined) clearTimeout(timer);
    timer = undefined;
    channel?.port1.close();
    channel?.port2.close();
    channel = undefined;
    mutation.disconnect();
    for (const observer of observers) observer.disconnect();
    observers.length = 0;
    for (const kind of activeKinds) window.removeEventListener(kind, onInput, true);
    calibration?.();
    calibration = undefined;
    check = null;
    if (state !== "done") state = "idle";
  };
  const observeResponse = () => {
    if (state === "input" && responseAt === null && check?.()) responseAt = performance.now();
  };
  const beginInput = (at: number, kind: string) => {
    if (state !== "armed") return;
    state = "input";
    inputAt = at;
    previous = inputAt;
    input = kind;
    commits = window.__latencyReactCommits;
  };
  const onInput = (event: Event) => beginInput(event.timeStamp, event.type);
  const finish = () => {
    if (state !== "input" || responseAt === null) return;
    const end = performance.now();
    // Include work later in this rendering opportunity, after our rAF callback.
    if (frameGaps.length) frameGaps[frameGaps.length - 1] += end - previous;
    // Drain pending entries before disconnecting (the observer callback may not have run yet).
    for (const observer of observers) {
      for (const entry of observer.takeRecords()) (entry.entryType === "longtask" ? tasks : events).push(entry);
    }
    const counter = window.__latencyReactCommits;
    sample = {
      work: responseAt - inputAt,
      paint: end - inputAt,
      frames: frameGaps.length,
      frameGaps: [...frameGaps],
      maxFrameGap: Math.max(0, ...frameGaps),
      longTasks: tasks.filter((e) => e.startTime < end && e.startTime + e.duration > inputAt).map((e) => e.duration),
      eventTiming: supported.eventTiming
        ? events
            .filter((e) => e.startTime >= inputAt - 1 && e.startTime <= end)
            .map((e) => ({
              name: e.name,
              durationMs: e.duration,
              interactionId: (e as PerformanceEventTiming).interactionId,
            }))
        : null,
      reactCommits: typeof commits === "number" && typeof counter === "number" ? counter - commits : null,
      input,
      instrumentation: { ...supported },
    };
    state = "done";
    stop();
  };
  const frame = () => {
    frameId = 0;
    if (state === "input") {
      const now = performance.now();
      frameGaps.push(now - previous);
      previous = now;
      observeResponse();
      if (responseAt !== null) {
        // rAF precedes layout/paint. A posted task reads after that rendering opportunity.
        if (typeof MessageChannel !== "undefined") {
          channel = new MessageChannel();
          channel.port1.onmessage = finish;
          channel.port2.postMessage(null);
        } else timer = setTimeout(finish, 0);
        return;
      }
    }
    if (state === "armed" || state === "input") frameId = requestAnimationFrame(frame);
  };
  const probe: LatencyProbe = {
    error: null,
    get state() {
      return state;
    },
    result: () => sample,
    frameInterval: () => interval,
    calibrate: () =>
      new Promise((resolve) => {
        stop();
        const times: number[] = [];
        calibration = () => resolve(interval);
        timer = setTimeout(() => {
          interval = Number.NaN;
          stop();
        }, 5000);
        const tick = () => {
          times.push(performance.now());
          if (times.length < 10) frameId = requestAnimationFrame(tick);
          else {
            const gaps = times
              .slice(1)
              .map((time, i) => time - times[i])
              .sort((a, b) => a - b);
            interval = gaps[Math.floor(gaps.length / 2)];
            stop();
          }
        };
        frameId = requestAnimationFrame(tick);
      }),
    arm(predicate, inputEvent) {
      stop();
      sample = null;
      probe.error = null;
      const fn = window.__latencyCheck ?? (() => false);
      const evaluate = () => {
        try {
          return Boolean(fn());
        } catch {
          return false;
        }
      };
      if (evaluate()) {
        probe.error = `predicate already holds before the input: ${predicate}`;
        state = "done";
        return;
      }
      check = evaluate;
      responseAt = null;
      frameGaps = [];
      tasks.length = events.length = 0;
      supported.longTasks = supported.eventTiming = false;
      for (const [type, target, key] of [
        ["longtask", tasks, "longTasks"],
        ["event", events, "eventTiming"],
      ] as const) {
        try {
          if (!PerformanceObserver.supportedEntryTypes?.includes(type)) continue;
          const observer = new PerformanceObserver((list) => target.push(...list.getEntries()));
          observer.observe({ type, buffered: false, ...(type === "event" ? { durationThreshold: 16 } : {}) });
          supported[key] = true;
          observers.push(observer);
        } catch {
          /* Unsupported is reported separately; frame gaps are never called long tasks. */
        }
      }
      const watch = (root: Document | ShadowRoot) => {
        mutation.observe(root, { subtree: true, childList: true, attributes: true, characterData: true });
        for (const element of root.querySelectorAll("*")) if (element.shadowRoot) watch(element.shadowRoot);
      };
      watch(document);
      activeKinds = inputEvent ? [inputEvent] : kinds;
      for (const kind of activeKinds) window.addEventListener(kind, onInput, { capture: true });
      state = "armed";
      frameId = requestAnimationFrame(frame);
    },
    stop,
    markInput: (kind = "command") => beginInput(performance.now(), kind),
    dispose() {
      stop();
      delete window.__latency;
      delete window.__latencyCheck;
    },
  };
  window.__latency = probe;
}
