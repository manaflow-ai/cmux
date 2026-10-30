// The main thread's script time, task by task, for streaming-text.harness.tsx. The harness imports
// this first, so it wraps these callbacks before React's scheduler takes its MessageChannel: the
// scheduler's tasks (React's renders, commits, layout and passive effects, and the layout an effect
// forces), animation frame callbacks (the reveal's, direct.ts `nextFrame`), resize observer
// callbacks (the rows' heights, with their normal batched React commits), event listeners (the
// transcript's scroll handler and the layout its reads force), timers and queued microtasks. Each outermost
// callback adds one [start, end] span to `spans`. Promise continuations, other observers and
// `setInterval` stay untimed.
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
    super((entries, observer) => timed(callback, observer, [entries, observer]));
  }
};

/// Each listener's timed stand-in, so removing the listener removes it.
const listeners = new WeakMap<EventListenerOrEventListenerObject, EventListener>();
const listen = EventTarget.prototype.addEventListener;
const unlisten = EventTarget.prototype.removeEventListener;
const timedListener = (listener: EventListenerOrEventListenerObject) => {
  let wrapped = listeners.get(listener);
  if (!wrapped) {
    wrapped = function (this: EventTarget, event: Event) {
      if (typeof listener === "function") return timed(listener, this, [event]);
      return timed(listener.handleEvent, listener, [event]);
    };
    listeners.set(listener, wrapped);
  }
  return wrapped;
};
EventTarget.prototype.addEventListener = function (
  this: EventTarget,
  type: string,
  listener: EventListenerOrEventListenerObject | null,
  options?: boolean | AddEventListenerOptions,
) {
  listen.call(this, type, listener && timedListener(listener), options);
};
EventTarget.prototype.removeEventListener = function (
  this: EventTarget,
  type: string,
  listener: EventListenerOrEventListenerObject | null,
  options?: boolean | EventListenerOptions,
) {
  unlisten.call(this, type, listener && (listeners.get(listener) ?? listener), options);
};
