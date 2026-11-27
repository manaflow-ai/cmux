// Where the main thread goes while keys are typed under load (composer-typing.bench.ts --probe): JS by entry
// point (outermost task only), style/layout forced synchronously by layout reads, and busy time from a heartbeat;
// busy minus JS is rendering (style, layout, paint) the page did not force. Works in WebKit, which has no
// DevTools profile here. Recording starts at the first "a" keydown after a Backspace (composer-load.ts typing).
//   bun bench/composer-typing.bench.ts --engine webkit --modes L1 --probe bench/main-thread-split-probe.js
(() => {
  const now = () => performance.now();
  let recording = false;
  let sawBackspace = false;
  let startAt = 0;
  let depth = 0;
  const js = {};
  const forced = {};
  const counts = {};
  const bump = (bag, key, ms) => {
    bag[key] = (bag[key] ?? 0) + ms;
  };
  const timed = (kind, fn) =>
    function (...args) {
      if (depth > 0 || !recording) {
        depth++;
        try {
          return fn.apply(this, args);
        } finally {
          depth--;
        }
      }
      depth++;
      const t = now();
      try {
        return fn.apply(this, args);
      } finally {
        depth--;
        bump(js, kind, now() - t);
        bump(counts, kind, 1);
      }
    };
  const wrapCb = (kind, cb) => (typeof cb === "function" ? timed(kind, cb) : cb);

  const raf = window.requestAnimationFrame.bind(window);
  window.requestAnimationFrame = (cb) => raf(wrapCb("raf", cb));
  const st = window.setTimeout.bind(window);
  window.setTimeout = (cb, ms, ...a) => st(wrapCb("timeout", cb), ms, ...a);
  const si = window.setInterval.bind(window);
  window.setInterval = (cb, ms, ...a) => si(wrapCb("interval", cb), ms, ...a);
  for (const Obs of ["ResizeObserver", "IntersectionObserver", "MutationObserver"]) {
    const Orig = window[Obs];
    if (!Orig) continue;
    window[Obs] = class extends Orig {
      constructor(cb, o) {
        super(wrapCb(Obs, cb), o);
      }
    };
  }
  const portDesc = Object.getOwnPropertyDescriptor(MessagePort.prototype, "onmessage");
  Object.defineProperty(MessagePort.prototype, "onmessage", {
    configurable: true,
    get() {
      return portDesc.get.call(this);
    },
    set(cb) {
      portDesc.set.call(this, wrapCb("port", cb));
    },
  });
  const wsDesc = window.WebSocket && Object.getOwnPropertyDescriptor(WebSocket.prototype, "onmessage");
  if (wsDesc)
    Object.defineProperty(WebSocket.prototype, "onmessage", {
      configurable: true,
      get() {
        return wsDesc.get.call(this);
      },
      set(cb) {
        wsDesc.set.call(this, wrapCb("ws", cb));
      },
    });
  const listenerMap = new WeakMap();
  const add = EventTarget.prototype.addEventListener;
  const remove = EventTarget.prototype.removeEventListener;
  EventTarget.prototype.addEventListener = function (type, cb, o) {
    if (typeof cb !== "function") return add.call(this, type, cb, o);
    let byType = listenerMap.get(cb);
    if (!byType) listenerMap.set(cb, (byType = new Map()));
    let w = byType.get(type);
    if (!w)
      byType.set(
        type,
        (w = timed(
          `ev:${["keydown", "keyup", "keypress", "input", "beforeinput", "message", "scroll", "selectionchange"].includes(type) ? type : "other"}`,
          cb,
        )),
      );
    return add.call(this, type, w, o);
  };
  EventTarget.prototype.removeEventListener = function (type, cb, o) {
    const w = typeof cb === "function" ? listenerMap.get(cb)?.get(type) : undefined;
    return remove.call(this, type, w ?? cb, o);
  };
  // Layout reads: time inside them is style/layout the page forced synchronously.
  const forcedWrap = (proto, name, isGetter) => {
    const d = Object.getOwnPropertyDescriptor(proto, name);
    if (!d) return;
    const orig = isGetter ? d.get : d.value;
    const w = function (...args) {
      if (!recording) return orig.apply(this, args);
      const t = now();
      try {
        return orig.apply(this, args);
      } finally {
        bump(forced, name, now() - t);
        bump(counts, `read:${name}`, 1);
      }
    };
    Object.defineProperty(proto, name, isGetter ? { ...d, get: w } : { ...d, value: w });
  };
  for (const n of ["getBoundingClientRect", "getClientRects"]) forcedWrap(Element.prototype, n, false);
  for (const n of ["offsetHeight", "offsetWidth", "offsetTop", "offsetLeft"])
    forcedWrap(HTMLElement.prototype, n, true);
  for (const n of ["scrollTop", "scrollHeight", "clientHeight", "clientWidth", "scrollWidth", "scrollLeft"])
    forcedWrap(Element.prototype, n, true);
  const gcs = window.getComputedStyle;
  window.getComputedStyle = function (...a) {
    if (!recording) return gcs.apply(this, a);
    const t = now();
    try {
      return gcs.apply(this, a);
    } finally {
      bump(forced, "getComputedStyle", now() - t);
    }
  };
  // Heartbeat: a 0 ms timeout chain (clamped near 4 ms); any gap past 5 ms is the thread busy.
  let busy = 0;
  let last = 0;
  const beat = () => {
    const t = now();
    if (recording && last) {
      const gap = t - last;
      if (gap > 5) busy += gap - 4;
    }
    last = t;
    st(beat, 0);
  };
  st(beat, 0);
  let frames = 0;
  let frameGaps = [];
  let lastFrame = 0;
  const tick = (t) => {
    if (recording) {
      frames++;
      if (lastFrame) frameGaps.push(t - lastFrame);
      lastFrame = t;
    }
    raf(tick);
  };
  raf(tick);
  add.call(
    window,
    "keydown",
    (e) => {
      if (e.key === "Backspace") sawBackspace = true;
      else if (sawBackspace && !recording && e.key === "a") {
        recording = true;
        startAt = now();
      }
    },
    true,
  );
  window.__probe = () => {
    const wall = now() - startAt;
    recording = false;
    const r = (bag) =>
      Object.fromEntries(
        Object.entries(bag)
          .sort((a, b) => b[1] - a[1])
          .map(([k, v]) => [k, Math.round(v)]),
      );
    const jsTotal = Object.values(js).reduce((a, b) => a + b, 0);
    const forcedTotal = Object.values(forced).reduce((a, b) => a + b, 0);
    frameGaps.sort((a, b) => a - b);
    return {
      wall_ms: Math.round(wall),
      busy_ms: Math.round(busy),
      js_ms: Math.round(jsTotal),
      forced_layout_ms: Math.round(forcedTotal),
      busy_minus_js_ms: Math.round(busy - jsTotal),
      frames,
      frame_gap_p50: Math.round(frameGaps[Math.floor(frameGaps.length * 0.5)] ?? 0),
      frame_gap_p95: Math.round(frameGaps[Math.floor(frameGaps.length * 0.95)] ?? 0),
      js: r(js),
      forced: r(forced),
      counts: r(counts),
    };
  };
})();
