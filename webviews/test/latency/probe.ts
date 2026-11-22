// In-page probe of the interaction-latency harness (plans/cmux-next/zero-latency.md). Playwright
// injects `installLatencyProbe` with `addInitScript`, so it must be self-contained (no imports, no
// closures over module scope).
//
// One measurement: `arm(predicate)` with a predicate source that is false now; the next input
// event (capture phase, any of pointerdown, mousedown, keydown, input, click) records its
// `timeStamp`. A MutationObserver (and each animation frame, for shadow DOM) evaluates the
// predicate; the first time it holds is the response, and the next animation frame after it is the
// paint. Long tasks between the input and the paint come from the Long Tasks API where the engine
// has it (Chromium) and, in every engine, from gaps between animation frames over 50 ms.

export interface LatencySample {
  /** Input event timeStamp to the DOM showing the response (the input path's work), ms. */
  work: number;
  /** Input event timeStamp to the first animation frame after the response, ms. */
  paint: number;
  /** Animation frames that fired between the input and the paint frame (inclusive). */
  frames: number;
  /** Long tasks (over 50 ms) that overlapped the input-to-paint window, ms each. */
  longTasks: number[];
  /** The longest interval between two animation frames in the window (a dropped frame shows here), ms. */
  maxFrameGap: number;
  /** The input event type that started the measurement. */
  input: string;
}

export interface LatencyProbe {
  /** Median animation-frame interval over the last frames, ms (the display refresh). */
  frameInterval(): number;
  arm(predicate: string): void;
  readonly state: "idle" | "armed" | "input" | "done" | "timeout";
  result(): LatencySample | null;
  error: string | null;
}

declare global {
  interface Window {
    __latency?: LatencyProbe;
  }
}

export function installLatencyProbe(): void {
  const w = window as unknown as Window & { __latency?: unknown };
  if (w.__latency) return;
  const frameTimes: number[] = [];
  let state: "idle" | "armed" | "input" | "done" | "timeout" = "idle";
  let check: (() => boolean) | null = null;
  let inputAt = 0;
  let inputType = "";
  let inputFrame = 0;
  let maxGap = 0;
  let frameCount = 0;
  let responseAt = 0;
  let paintAt = 0;
  let paintFrame = 0;
  let sample: LatencySample | null = null;
  const longTasks: Array<{ start: number; end: number }> = [];
  const probe = {
    error: null as string | null,
    get state() {
      return state;
    },
    frameInterval() {
      const deltas: number[] = [];
      for (let i = 1; i < frameTimes.length; i += 1) deltas.push(frameTimes[i] - frameTimes[i - 1]);
      deltas.sort((a, b) => a - b);
      return deltas.length ? deltas[Math.floor(deltas.length / 2)] : 16.7;
    },
    arm(predicate: string) {
      // The harness installs the predicate as `__latencyCheck` (page.evaluate of its source).
      const fn = (window as unknown as { __latencyCheck?: () => unknown }).__latencyCheck ?? (() => false);
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
        sample = null;
        return;
      }
      probe.error = null;
      // Shadow roots (the diff viewer's files, the files tree) are observed too.
      const roots: ShadowRoot[] = [];
      const walk = (root: Document | ShadowRoot) => {
        for (const element of root.querySelectorAll("*")) {
          if (element.shadowRoot) {
            roots.push(element.shadowRoot);
            walk(element.shadowRoot);
          }
        }
      };
      walk(document);
      for (const root of roots) {
        observer.observe(root, { subtree: true, childList: true, attributes: true, characterData: true });
      }
      check = evaluate;
      sample = null;
      responseAt = 0;
      paintAt = 0;
      state = "armed";
    },
    result() {
      return sample;
    },
  };
  w.__latency = probe;

  const onInput = (event: Event) => {
    if (state !== "armed") return;
    state = "input";
    inputAt = event.timeStamp;
    inputType = event.type;
    inputFrame = frameCount;
    maxGap = 0;
    // A response applied inside this very handler chain is caught by the observer's microtask.
  };
  for (const type of ["pointerdown", "mousedown", "keydown", "beforeinput", "input", "click"]) {
    window.addEventListener(type, onInput, { capture: true });
  }

  const observeResponse = () => {
    if (state !== "input" || responseAt !== 0 || !check) return;
    if (check()) responseAt = performance.now();
  };
  const observer = new MutationObserver(observeResponse);
  const startObserving = () =>
    observer.observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
  if (document.documentElement) startObserving();
  else document.addEventListener("DOMContentLoaded", startObserving, { once: true });

  if (typeof PerformanceObserver !== "undefined") {
    try {
      new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) {
          longTasks.push({ start: entry.startTime, end: entry.startTime + entry.duration });
        }
      }).observe({ type: "longtask", buffered: true });
    } catch {
      // No Long Tasks API (WebKit): frame gaps below cover it.
    }
  }

  let previousNow = performance.now();
  const frame = () => {
    frameCount += 1;
    // Callback times, not the frame timestamps: Chromium stamps a frame with its vsync time even
    // when a blocked main thread runs the callback much later.
    const now = performance.now();
    const previous = frameTimes.length ? frameTimes[frameTimes.length - 1] : now;
    frameTimes.push(now);
    if (frameTimes.length > 120) frameTimes.shift();
    // A frame gap over 50 ms is a long task in every engine.
    if (now - previous > 50) longTasks.push({ start: previous, end: now });
    if (state === "input") maxGap = Math.max(maxGap, now - (frameTimes.length > 1 ? previousNow : now));
    previousNow = now;
    if (state === "input") {
      // Shadow DOM changes do not reach the observer: poll once per frame too.
      if (responseAt === 0) observeResponse();
      if (responseAt !== 0 && now >= responseAt && paintAt === 0 && frameCount > 0) {
        // This is the first frame callback after the response: its paint shows it.
        paintAt = Math.max(now, responseAt);
        paintFrame = frameCount;
        const windowStart = inputAt;
        const windowEnd = paintAt;
        sample = {
          work: responseAt - inputAt,
          paint: paintAt - inputAt,
          frames: paintFrame - inputFrame,
          longTasks: longTasks
            .filter((task) => task.end > windowStart && task.start < windowEnd && task.end - task.start > 50)
            .map((task) => Math.round(task.end - task.start)),
          input: inputType,
          maxFrameGap: maxGap,
        };
        state = "done";
      }
    }
    if (longTasks.length > 200) longTasks.splice(0, longTasks.length - 200);
    requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);
}
