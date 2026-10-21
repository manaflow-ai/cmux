// Human-like agent mouse (plans/cmux-next/human-mouse-DESIGN.md): the
// planner's path and timing properties, and the event stream Mouse and
// Page._clickAt send to the driver. No browser: the planner is pure and the
// driver is a recording fake on a virtual clock.
//
//   node --test tests/browser-parity/unit/human-mouse.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { loadRuntime } from "../lib/dev-driver.mjs";

const ns = loadRuntime();
const HM = ns.humanMouse;
const { Mouse, Page } = ns.core;

const dist = (a, b) => Math.hypot(b.x - a.x, b.y - a.y);

test("human mouse: the planner is loaded with the runtime", () => {
  assert.equal(typeof HM, "object");
  for (const name of ["config", "rng", "moveDuration", "planMove", "pause"]) assert.equal(typeof HM[name], "function", name);
});

test("human mouse: move time follows Fitts's law and is capped", () => {
  const cfg = HM.config();
  const t = (d, w) => HM.moveDuration(d, w, cfg);
  assert.ok(t(400, 24) > t(100, 24), "longer moves take longer");
  assert.ok(t(200, 80) < t(200, 10), "bigger targets are faster");
  // log2(D/W + 1): doubling D/W+1 adds b.
  const a = HM.moveDuration(24 * 3, 24, { ...cfg, maxMoveMs: 1e9, minMoveMs: 0 });
  const b = HM.moveDuration(24 * 7, 24, { ...cfg, maxMoveMs: 1e9, minMoveMs: 0 });
  assert.ok(Math.abs(b - a - cfg.fittsB) < 1e-9);
  assert.equal(t(5000, 1), cfg.maxMoveMs, "never past the cap");
  assert.ok(cfg.maxMoveMs <= 400, "the default cap keeps agents fast");
  assert.ok(t(3, 24) >= cfg.minMoveMs);
});

test("human mouse: a path starts at the origin, ends exactly on the target, at ~60 Hz", () => {
  const cfg = HM.config();
  for (const seed of [1, 2, 3, 42, 99]) {
    const from = { x: 20, y: 30 };
    const to = { x: 640, y: 410 };
    const path = HM.planMove(from, to, cfg, HM.rng(seed));
    assert.ok(path.length >= 10, `seed ${seed}: many samples, got ${path.length}`);
    const last = path[path.length - 1];
    assert.deepEqual({ x: last.x, y: last.y }, to, "the last sample is the target");
    assert.ok(dist(from, path[0]) < 40, "the first sample is near the origin");
    for (let i = 1; i < path.length; i++) {
      const gap = path[i].t - path[i - 1].t;
      assert.ok(gap > 10 && gap < 24, `seed ${seed}: sample gap ${gap} ms is about one 60 Hz frame`);
    }
    assert.ok(last.t <= cfg.maxMoveMs + 1e-9);
    for (const p of path) assert.ok(Number.isInteger(p.x) && Number.isInteger(p.y), "whole CSS px");
  }
});

test("human mouse: speed is bell-shaped and the path is curved but bounded", () => {
  const cfg = HM.config();
  const from = { x: 0, y: 0 };
  const to = { x: 800, y: 0 };
  let curved = 0;
  for (let seed = 1; seed <= 20; seed++) {
    const path = [{ t: 0, ...from }, ...HM.planMove(from, to, cfg, HM.rng(seed))];
    const speeds = [];
    for (let i = 1; i < path.length; i++) speeds.push(dist(path[i - 1], path[i]) / (path[i].t - path[i - 1].t));
    const n = speeds.length;
    const peak = Math.max(...speeds);
    const head = speeds.slice(0, Math.max(1, Math.floor(n * 0.1)));
    assert.ok(Math.max(...head) < peak * 0.7, `seed ${seed}: slow start`);
    assert.ok(speeds[n - 1] < peak * 0.5, `seed ${seed}: slow arrival`);
    const deviation = Math.max(...path.map((p) => Math.abs(p.y)));
    assert.ok(deviation <= 800 * 0.15 + 2, `seed ${seed}: deviation ${deviation} px is bounded`);
    if (deviation >= 2) curved++;
  }
  assert.ok(curved >= 15, `most paths are visibly curved (${curved}/20)`);
});

test("human mouse: a long move has a correction sub-movement before the end", () => {
  const cfg = HM.config();
  const from = { x: 0, y: 0 };
  const to = { x: 900, y: 300 };
  let corrected = 0;
  for (let seed = 1; seed <= 20; seed++) {
    const path = [{ t: 0, ...from }, ...HM.planMove(from, to, cfg, HM.rng(seed))];
    const speeds = [];
    for (let i = 1; i < path.length; i++) speeds.push(dist(path[i - 1], path[i]) / (path[i].t - path[i - 1].t));
    // A local speed minimum in the last 40 % that is followed by a rise.
    const start = Math.floor(speeds.length * 0.6);
    for (let i = start; i < speeds.length - 1; i++) {
      if (speeds[i] < speeds[i - 1] && speeds[i + 1] > speeds[i] * 1.2) {
        corrected++;
        break;
      }
    }
  }
  assert.ok(corrected >= 15, `long moves are corrected (${corrected}/20)`);
  // A short move is one smooth movement.
  const short = HM.planMove({ x: 0, y: 0 }, { x: 40, y: 0 }, cfg, HM.rng(5));
  assert.ok(short.length >= 3);
});

test("human mouse: the same seed gives the same path", () => {
  const cfg = HM.config();
  const a = HM.planMove({ x: 1, y: 2 }, { x: 300, y: 500 }, cfg, HM.rng(7));
  const b = HM.planMove({ x: 1, y: 2 }, { x: 300, y: 500 }, cfg, HM.rng(7));
  assert.deepEqual(a, b);
  const r = HM.rng(3);
  for (let i = 0; i < 100; i++) {
    const p = HM.pause([40, 110], r);
    assert.ok(p >= 40 && p <= 110);
  }
});

// A page on a virtual clock whose driver records each input with its time.
function fakePage({ latencyMs = 0, agentMouse } = {}) {
  let clock = 0;
  const calls = [];
  const session = {
    now: () => clock,
    sleep: async (ms) => { clock += Math.max(0, ms); },
    agentMouse: HM.config(agentMouse),
    mouseRandom: HM.rng(11),
  };
  const page = {
    _session: session,
    _targetId: "T",
    _heldDialog: null,
    keyboard: { _modifiers: new Set() },
    async _input(method, params) {
      clock += latencyMs;
      calls.push({ t: clock, method, ...params });
    },
    async _afterAction() {},
  };
  page.mouse = new Mouse(page);
  return { page, calls, now: () => clock };
}

test("human mouse: mouse.click from far away hovers along a path, dwells, then presses for a while", async () => {
  const { page, calls } = fakePage();
  await page.mouse.click(700, 500);
  const moves = calls.filter((c) => c.type === "move");
  assert.ok(moves.length >= 10, `many moves, got ${moves.length}`);
  assert.deepEqual([moves.at(-1).x, moves.at(-1).y], [700, 500]);
  const down = calls.findIndex((c) => c.type === "down");
  const up = calls.findIndex((c) => c.type === "up");
  assert.ok(down > 0 && up === down + 1, "move…, down, up");
  assert.ok(calls[down].t - calls[down - 1].t >= 40, "hover dwell before the press");
  assert.ok(calls[up].t - calls[down].t >= 50, "the press lasts");
});

test("human mouse: a double click pauses between its clicks", async () => {
  const { page, calls } = fakePage();
  await page.mouse.click(10, 10, { clickCount: 2 });
  const ups = calls.filter((c) => c.type === "up");
  const downs = calls.filter((c) => c.type === "down");
  assert.equal(downs.length, 2);
  assert.equal(downs[1].clickCount, 2);
  assert.ok(downs[1].t - ups[0].t >= 70);
});

test("human mouse: explicit steps stay linear, and motion: instant teleports with no pauses", async () => {
  const a = fakePage();
  await a.page.mouse.move(100, 0, { steps: 4 });
  assert.deepEqual(a.calls.map((c) => c.x), [25, 50, 75, 100]);
  const b = fakePage({ agentMouse: { motion: "instant" } });
  await b.page.mouse.click(500, 500);
  assert.deepEqual(b.calls.map((c) => c.type), ["move", "down", "up"]);
  assert.equal(b.now(), 0, "no waiting");
  const c = fakePage();
  await c.page.mouse.move(500, 500, { motion: "instant" });
  assert.equal(c.calls.length, 1);
});

test("human mouse: a slow driver is coalesced: the move takes its planned time and still ends on the target", async () => {
  const { page, calls, now } = fakePage({ latencyMs: 40 });
  await page.mouse.move(900, 600);
  const cfg = page._session.agentMouse;
  assert.ok(now() <= cfg.maxMoveMs + 60, `wall time ${now()} ms stays near the plan, not plan + n·latency`);
  assert.deepEqual([calls.at(-1).x, calls.at(-1).y], [900, 600]);
  assert.ok(calls.length >= 3);
});

test("human mouse: a locator click (Page._clickAt) dwells before the press and holds it", async () => {
  const { page, calls } = fakePage();
  page._input = page._input.bind(page);
  const frame = { _agent: async () => undefined };
  await Page.prototype._clickAt.call(page, { x: 50, y: 60, frame, handle: 1 }, {});
  const types = calls.map((c) => c.type);
  assert.equal(types.at(-2), "down");
  assert.equal(types.at(-1), "up");
  const down = calls.at(-2);
  const up = calls.at(-1);
  assert.ok(down.t - calls.at(-3).t >= 40, "hover dwell");
  assert.ok(up.t - down.t >= 50, "press hold");
});

test("human mouse: a wheel scroll glides out like a trackpad fling: decaying parts that sum to the asked delta", async () => {
  const { page, calls, now } = fakePage();
  await page.mouse.wheel(0, 900);
  const wheels = calls.filter((c) => c.type === "wheel");
  assert.ok(wheels.length >= 5, `several parts, got ${wheels.length}`);
  const sum = wheels.reduce((s, w) => s + w.deltaY, 0);
  assert.equal(sum, 900, "nothing lost to rounding");
  assert.ok(wheels.every((w) => w.deltaX === 0));
  for (let i = 1; i < wheels.length; i++) assert.ok(wheels[i].deltaY <= wheels[i - 1].deltaY, "each part is no bigger than the one before");
  assert.ok(wheels[0].deltaY > wheels.at(-1).deltaY * 2, "it slows down");
  assert.ok(now() >= 120 && now() <= 400, `about a fling's length, got ${now()} ms`);
  // Instant motion and tiny scrolls stay one event.
  const b = fakePage({ agentMouse: { motion: "instant" } });
  await b.page.mouse.wheel(0, 900);
  assert.equal(b.calls.length, 1);
  const c = fakePage();
  await c.page.mouse.wheel(0, 3);
  assert.equal(c.calls.length, 1);
  // Up and sideways too.
  const d = fakePage();
  await d.page.mouse.wheel(-300, -600);
  const dw = d.calls.filter((x) => x.type === "wheel");
  assert.equal(dw.reduce((s, w) => s + w.deltaX, 0), -300);
  assert.equal(dw.reduce((s, w) => s + w.deltaY, 0), -600);
});
