// The main thread's script time, task by task, for streaming-text.harness.tsx. The harness imports
// this first, so it wraps the task sources before React's scheduler takes its MessageChannel: every
// scheduler task (React's renders, commits, layout and passive effects, and the layout an effect
// forces), every animation frame callback (the reveal's, direct.ts `nextFrame`), every resize
// observer callback (the rows' heights, with their `flushSync` commits), every timer and every
// queued microtask. Each outermost callback adds one [start, end] span to `spans`.
export const spans: [number, number][] = [];

let depth = 0;
function timed<A extends unknown[], R>(body: (...args: A) => R, self: unknown, args: A): R {
  if (depth > 0) return body.apply(self, args);
  depth = 1;
  const start = performance.now();
  try {
    return body.apply(self, args);
  } finally {
    depth = 0;
    spans.push([start, performance.now()]);
  }
}

/// The sampler's own frame callback, untimed.
export const untimedFrame = window.requestAnimationFrame.bind(window);

const frame = window.requestAnimationFrame;
window.requestAnimationFrame = function (callback: FrameRequestCallback) {
  return frame.call(window, (t) => timed(callback, undefined, [t]));
};

const timeout = window.setTimeout.bind(window) as (handler: unknown, ms?: number, ...rest: unknown[]) => number;
window.setTimeout = ((handler: TimerHandler, ms?: number, ...rest: unknown[]) => {
  if (typeof handler !== "function") return timeout(handler, ms, ...rest);
  const callback = handler as (...args: unknown[]) => unknown;
  return timeout((...args: unknown[]) => timed(callback, undefined, args), ms, ...rest);
}) as unknown as typeof window.setTimeout;

const microtask = window.queueMicrotask;
window.queueMicrotask = function (callback: VoidFunction) {
  microtask.call(window, () => timed(callback, undefined, []));
};

const onmessage = Object.getOwnPropertyDescriptor(MessagePort.prototype, "onmessage")!;
Object.defineProperty(MessagePort.prototype, "onmessage", {
  ...onmessage,
  set(this: MessagePort, handler: ((event: MessageEvent) => unknown) | null) {
    onmessage.set!.call(this, handler && ((event: MessageEvent) => timed(handler, this, [event])));
  },
});

const Observer = window.ResizeObserver;
window.ResizeObserver = class extends Observer {
  constructor(callback: ResizeObserverCallback) {
    super((entries, observer) => timed(callback, undefined, [entries, observer]));
  }
};
