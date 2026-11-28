(() => {
  // Times every main-thread callback by kind: React's scheduler (MessagePort), rAF, timers.
  const sums = {}, counts = {}, perFrame = [];
  let frameSum = 0;
  const now = () => performance.now();
  const add = (k, ms) => { sums[k] = (sums[k] || 0) + ms; counts[k] = (counts[k] || 0) + 1; frameSum += ms; };
  const wrap = (k, fn) => typeof fn !== "function" ? fn : function (...a) { const t = now(); try { return fn.apply(this, a); } finally { add(k, now() - t); } };
  const raf = window.requestAnimationFrame.bind(window);
  window.requestAnimationFrame = (cb) => raf(wrap("raf", cb));
  const st = window.setTimeout.bind(window);
  window.setTimeout = (cb, ...r) => st(wrap("timeout", cb), ...r);
  const si = window.setInterval.bind(window);
  window.setInterval = (cb, ...r) => si(wrap("interval", cb), ...r);
  const desc = Object.getOwnPropertyDescriptor(MessagePort.prototype, "onmessage");
  Object.defineProperty(MessagePort.prototype, "onmessage", { configurable: true, get() { return desc.get.call(this); }, set(fn) { desc.set.call(this, wrap("message", fn)); } });
  const ael = EventTarget.prototype.addEventListener;
  const map = new WeakMap();
  EventTarget.prototype.addEventListener = function (type, fn, o) {
    if (typeof fn === "function" && (this instanceof MessagePort || type === "message")) {
      let w = map.get(fn); if (!w) { w = wrap("message", fn); map.set(fn, w); }
      return ael.call(this, type, w, o);
    }
    return ael.call(this, type, fn, o);
  };
  const rel = EventTarget.prototype.removeEventListener;
  EventTarget.prototype.removeEventListener = function (type, fn, o) { return rel.call(this, type, map.get(fn) || fn, o); };
  // Per-frame total of timed script.
  const tick = () => { perFrame.push(frameSum); frameSum = 0; raf(tick); };
  raf(tick);
  let t0 = now();
  const reset = () => { for (const k in sums) { sums[k] = 0; counts[k] = 0; } perFrame.length = 0; t0 = now(); };
  window.__jsReset = reset;
  let keyed = false; window.addEventListener("keydown", () => { if (!keyed) { keyed = true; reset(); } }, true);
  window.__jstime = () => {
    const s = perFrame.slice().sort((a, b) => a - b);
    const q = (p) => s.length ? +s[Math.min(s.length - 1, Math.floor(p * s.length))].toFixed(1) : null;
    const secs = (now() - t0) / 1000;
    const out = { secs: +secs.toFixed(1), frames: s.length, script_per_frame_p50: q(0.5), p95: q(0.95), p99: q(0.99) };
    for (const k in sums) out[k] = { ms_per_s: +(sums[k] / secs).toFixed(1), n_per_s: +(counts[k] / secs).toFixed(1) };
    return out;
  };
})();
(() => {
  const seen = {}; let samples = 0;
  const sample = () => {
    if (!document.getAnimations) return;
    samples += 1;
    for (const a of document.getAnimations()) {
      const t = a.effect && a.effect.target;
      const cls = t ? (t.tagName + "." + String(t.className && t.className.baseVal !== undefined ? t.className.baseVal : t.className).split(" ").slice(0, 2).join(".")) : "?";
      const k = (a.animationName || a.transitionProperty || a.constructor.name) + "@" + cls;
      seen[k] = (seen[k] || 0) + 1;
    }
  };
  let keyed = false;
  window.addEventListener("keydown", () => { if (!keyed) { keyed = true; setInterval(sample, 250); } }, true);
  window.__census = () => { const o = {}; for (const k of Object.keys(seen).sort((a, b) => seen[b] - seen[a]).slice(0, 25)) o[k] = +(seen[k] / Math.max(1, samples)).toFixed(1); return { samples, per_sample: o }; };
})();
(() => {
  const go = () => { const s = document.createElement("style"); s.textContent = ""; document.head.append(s); };
  if ("") { if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", go); else go(); }
  window.__probe = () => ({ v: "base", js: window.__jstime(), anims: window.__census() });
})();
