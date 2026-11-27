// Human-like agent pointer paths (plans/cmux-next/human-mouse-DESIGN.md).
//
// Pure planning: no clock, no I/O. Mouse.move and Page._clickAt in
// runtime-core.js play a plan against the session clock, so the page gets
// a human event stream (hover along the way, dwell, press hold) and the
// agent cursor overlay, which draws each dispatched move, traces the same
// path. Every random choice comes from a seeded generator, so a seed gives
// one exact path (tests).
(function (root) {
  "use strict";
  const ns = (root.CmuxBrowserRepl = root.CmuxBrowserRepl || {});

  // Defaults; each is a `browser.agentMouse.*` setting (DESIGN "Settings").
  const DEFAULTS = Object.freeze({
    // "human": planned paths and pauses; "instant": one move, no pauses.
    motion: "human",
    // Fitts's law T = a + b·log2(D/W + 1), in ms, clamped to the cap.
    fittsA: 50,
    fittsB: 90,
    // The target size a move aims at when the caller does not know it.
    targetWidth: 24,
    minMoveMs: 60,
    maxMoveMs: 350,
    // Display-rate sampling (a browser coalesces moves per frame).
    hz: 60,
    // Bézier control points sit up to this fraction of D to one side.
    curvature: 0.08,
    // Moves at least this long end with a correction sub-movement.
    correctionMinPx: 120,
    // Perpendicular tremor amplitude in CSS px, zero at both ends.
    jitterPx: 0.5,
    // [min, max] ms: hover before the press, press length, double-click gap.
    dwellMs: [40, 110],
    holdMs: [50, 110],
    doubleClickGapMs: [70, 140],
    // A wheel scroll this long (ms) glides out in decaying parts, like a
    // trackpad fling; shorter than `flingMinPx` stays one event.
    flingMs: 240,
    flingMinPx: 40,
  });

  const RANGES = ["dwellMs", "holdMs", "doubleClickGapMs"];

  // The defaults with `overrides` (a host's settings, a script's
  // page.mouse.configure) applied; values of the wrong type are ignored.
  function config(overrides) {
    const cfg = { ...DEFAULTS };
    if (!overrides || typeof overrides !== "object") return cfg;
    for (const key of Object.keys(DEFAULTS)) {
      const v = overrides[key];
      if (v === undefined) continue;
      if (key === "motion") {
        if (v === "human" || v === "instant") cfg.motion = v;
      } else if (RANGES.includes(key)) {
        if (Array.isArray(v) && v.length === 2 && v.every((n) => Number.isFinite(n) && n >= 0) && v[0] <= v[1]) cfg[key] = [v[0], v[1]];
      } else if (Number.isFinite(v) && v >= 0) {
        cfg[key] = v;
      }
    }
    if (cfg.minMoveMs > cfg.maxMoveMs) cfg.minMoveMs = cfg.maxMoveMs;
    if (!(cfg.hz > 0)) cfg.hz = DEFAULTS.hz;
    return cfg;
  }

  // mulberry32: a small, fast, seeded generator in [0, 1).
  function rng(seed) {
    let a = seed >>> 0;
    return function () {
      a = (a + 0x6d2b79f5) >>> 0;
      let t = a;
      t = Math.imul(t ^ (t >>> 15), t | 1);
      t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }

  // Fitts's law move time in ms for distance `d` to a target `w` wide.
  function moveDuration(d, w, cfg) {
    if (!(d >= 0.5)) return 0;
    const width = w > 0 ? w : cfg.targetWidth;
    const t = cfg.fittsA + cfg.fittsB * Math.log2(d / width + 1);
    return Math.min(cfg.maxMoveMs, Math.max(cfg.minMoveMs, t));
  }

  // A value in [lo, hi], peaked in the middle (two uniforms averaged).
  function pause(range, rand) {
    const [lo, hi] = range;
    return lo + (hi - lo) * ((rand() + rand()) / 2);
  }

  // Minimum-jerk position profile: 0 → 1 with zero speed and acceleration at both ends.
  const minJerk = (u) => u * u * u * (10 - 15 * u + 6 * u * u);

  function bezier(p0, c1, c2, p1, s) {
    const m = 1 - s;
    const a = m * m * m;
    const b = 3 * m * m * s;
    const c = 3 * m * s * s;
    const d = s * s * s;
    return { x: a * p0.x + b * c1.x + c * c2.x + d * p1.x, y: a * p0.y + b * c1.y + c * c2.y + d * p1.y };
  }

  // One sub-movement: a slightly curved cubic Bézier from `a` to `b` with a
  // minimum-jerk progress along it. `bend` is the signed side offset of the
  // control points as a fraction of the length.
  function subMovement(a, b, bend) {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const len = Math.hypot(dx, dy) || 1;
    const nx = -dy / len;
    const ny = dx / len;
    const h = bend * len;
    const c1 = { x: a.x + dx * 0.3 + nx * h, y: a.y + dy * 0.3 + ny * h };
    const c2 = { x: a.x + dx * 0.7 + nx * h, y: a.y + dy * 0.7 + ny * h };
    return (u) => bezier(a, c1, c2, b, minJerk(u));
  }

  // A human path from `from` to `to`: [{ t, x, y }] with t in ms after the
  // start (the first sample one frame in), interior points in whole CSS px
  // and the last sample exactly `to` at the move's Fitts time.
  // `options.width` is the target's size when the caller knows it.
  function planMove(from, to, cfg, rand, options = {}) {
    const d = Math.hypot(to.x - from.x, to.y - from.y);
    const total = moveDuration(d, options.width, cfg);
    if (total <= 0) return [{ t: 0, x: to.x, y: to.y }];
    const frame = 1000 / cfg.hz;
    const n = Math.max(2, Math.round(total / frame));
    const side = rand() < 0.5 ? -1 : 1;
    const bend = side * Math.min(0.12, cfg.curvature * (0.25 + 0.75 * rand()));
    const dir = { x: (to.x - from.x) / d, y: (to.y - from.y) / d };
    // Long moves: a fast primary sub-movement that ends a little short
    // (more often) or a little past, then a slow correction.
    let primary = subMovement(from, to, bend);
    let correction = null;
    let split = 1;
    if (d >= cfg.correctionMinPx) {
      const reach = rand() < 0.6 ? 0.94 + 0.03 * rand() : 1.02 + 0.02 * rand();
      const lateral = (rand() * 2 - 1) * 0.015 * d;
      const end = {
        x: from.x + dir.x * d * reach - dir.y * lateral,
        y: from.y + dir.y * d * reach + dir.x * lateral,
      };
      primary = subMovement(from, end, bend);
      correction = subMovement(end, to, 0);
      split = 0.78 + 0.07 * rand();
    }
    const at = (u) => (u <= split ? primary(u / split) : correction((u - split) / (1 - split)));
    // Tremor: two slow sinusoids across the move, perpendicular to it,
    // shaped by sin(πu) so the ends stay exact.
    const p1 = rand() * Math.PI * 2;
    const p2 = rand() * Math.PI * 2;
    const f1 = 1.5 + rand();
    const f2 = 3 + 2 * rand();
    const tremor = (u) => cfg.jitterPx * Math.sin(Math.PI * u) * (0.6 * Math.sin(2 * Math.PI * f1 * u + p1) + 0.4 * Math.sin(2 * Math.PI * f2 * u + p2));
    const out = [];
    for (let i = 1; i <= n; i++) {
      const u = i / n;
      if (i === n) {
        out.push({ t: total, x: to.x, y: to.y });
        break;
      }
      const p = at(u);
      const j = tremor(u);
      // A little frame-to-frame timing noise, as real input has.
      const t = u * total + (rand() * 2 - 1) * Math.min(1.5, frame * 0.1);
      out.push({ t, x: Math.round(p.x - dir.y * j), y: Math.round(p.y + dir.x * j) });
    }
    return out;
  }

  // A fling: wheel parts at display rate whose sizes decay exponentially
  // and sum exactly to (dx, dy) in whole px. [{ t, dx, dy }], t in ms.
  function planWheel(dx, dy, cfg) {
    const total = Math.max(Math.abs(dx), Math.abs(dy));
    if (cfg.motion === "instant" || total < cfg.flingMinPx || !(cfg.flingMs > 0)) return [{ t: 0, dx, dy }];
    const frame = 1000 / cfg.hz;
    const n = Math.max(2, Math.round(cfg.flingMs / frame));
    const k = 4 / n; // decay per part: the last part is about e^-4 of the first
    const weights = [];
    for (let i = 0; i < n; i++) weights.push(Math.exp(-k * i));
    const sum = weights.reduce((a, b) => a + b, 0);
    const split = (v) => {
      const parts = [];
      let given = 0;
      let acc = 0;
      for (let i = 0; i < n; i++) {
        acc += weights[i];
        const upto = Math.round((v * acc) / sum);
        parts.push(upto - given);
        given = upto;
      }
      return parts;
    };
    const xs = split(dx);
    const ys = split(dy);
    const out = [];
    for (let i = 0; i < n; i++) if (xs[i] || ys[i]) out.push({ t: i * frame, dx: xs[i], dy: ys[i] });
    return out;
  }

  ns.humanMouse = { DEFAULTS, config, rng, moveDuration, planMove, planWheel, pause };
})(typeof globalThis !== "undefined" ? globalThis : this);
