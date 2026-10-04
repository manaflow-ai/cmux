import { expect, test } from "bun:test";
import {
  createFilesPanelMotion,
  MOTION_SPRINGS,
  springCurve,
  springSlideKeyframes,
  springStepResponse,
  springVisibleEnd,
} from "../src/files-panel-motion";

test("the panel uses the app's sidebar springs (speed fast): ~160 ms visible to open, faster to close", () => {
  const open = springCurve(MOTION_SPRINGS.appear);
  const close = springCurve(MOTION_SPRINGS.disappear);
  // cmux-motion's visible_end for appear (0.18, 0.9) and disappear (0.15, 0.9).
  expect(open.durationMs).toBe(157);
  expect(close.durationMs).toBe(131);
  expect(close.durationMs).toBeLessThan(open.durationMs);
  // A step reaches its target and never visibly overshoots (damping 0.9).
  expect(springStepResponse(MOTION_SPRINGS.appear, 10)).toBeCloseTo(1, 6);
  for (let t = 0; t < 1; t += 0.005) {
    expect(springStepResponse(MOTION_SPRINGS.appear, t)).toBeLessThan(1.002);
  }
  expect(springStepResponse(MOTION_SPRINGS.appear, springVisibleEnd(MOTION_SPRINGS.appear))).toBeGreaterThan(0.994);
  // The curve starts at 0, rises quickly (ease-out) and ends exactly at 1.
  const points = open.progress;
  expect(points[0]).toBe(0);
  expect(points.at(-1)).toBe(1);
  expect(points[Math.floor(points.length / 4)]).toBeGreaterThan(0.4);
  expect(points[Math.floor(points.length / 2)]).toBeGreaterThan(0.8);
});

function fakeHost(options: { reduced?: boolean; offset?: number } = {}) {
  const log: string[] = [];
  const frames: (() => void)[] = [];
  const animations: { keyframes: any[]; options: any; cancelled: boolean; resolve: () => void }[] = [];
  const panel = {
    dataset: {} as DOMStringMap,
    getBoundingClientRect: () => ({ width: 252 }) as DOMRect,
    animate(keyframes: any[], animationOptions: any) {
      let resolve = () => {};
      const finished = new Promise<void>((done) => (resolve = done));
      const record = { keyframes, options: animationOptions, cancelled: false, resolve };
      animations.push(record);
      log.push(`animate ${keyframes.map((frame) => frame.transform).join(" -> ")}`);
      return {
        cancel: () => {
          record.cancelled = true;
        },
        finished,
      } as any;
    },
  };
  const body = { dataset: {} as DOMStringMap };
  const motion = createFilesPanelMotion({
    panel: () => panel as any,
    body,
    currentOffset: () => options.offset ?? 0,
    requestFrame: (callback) => frames.push(callback),
    reducedMotion: () => options.reduced ?? false,
  });
  const flushFrames = () => {
    while (frames.length > 0) {
      frames.shift()!();
    }
  };
  return { animations, body, flushFrames, log, motion, panel };
}

test("a toggle changes the layout first, then slides the panel two frames later", () => {
  const { animations, body, flushFrames, log, motion, panel } = fakeHost();
  motion.set(true);
  // Boot: the resting state, no motion.
  expect(body.dataset.filesHidden).toBe("false");
  expect(log).toEqual([]);

  motion.set(false);
  // This frame: the diff takes its final width; the panel holds where it is.
  expect(body.dataset.filesHidden).toBe("true");
  expect(panel.dataset.filesMotion).toBe("running");
  expect(log).toEqual(["animate translate3d(0px, 0, 0) -> translate3d(0px, 0, 0)"]);
  flushFrames();
  const slide = animations[1];
  expect(slide.keyframes[0].transform).toBe("translate3d(0px, 0, 0)");
  expect(slide.keyframes.at(-1).transform).toBe("translate3d(252px, 0, 0)");
  expect(animations[0].cancelled).toBe(true);
  expect(slide.options).toEqual({ duration: springCurve(MOTION_SPRINGS.disappear).durationMs, easing: "linear" });
  expect(slide.keyframes).toEqual(springSlideKeyframes(MOTION_SPRINGS.disappear, 0, 252).keyframes);
});

test("toggling mid-slide reverses from the panel's current position", () => {
  const { animations, flushFrames, log, motion } = fakeHost({ offset: 120 });
  motion.set(true);
  motion.set(false);
  flushFrames();
  // Half-way out (120px), the user opens it again.
  motion.set(true);
  expect(animations[1].cancelled).toBe(true);
  expect(log.at(-1)).toBe("animate translate3d(120px, 0, 0) -> translate3d(120px, 0, 0)");
  flushFrames();
  const reverse = animations.at(-1)!;
  expect(reverse.keyframes[0].transform).toBe("translate3d(120px, 0, 0)");
  expect(reverse.keyframes.at(-1).transform).toBe("translate3d(0px, 0, 0)");
  expect(reverse.options.duration).toBe(springCurve(MOTION_SPRINGS.appear).durationMs);
});

test("with reduced motion the panel switches in one frame", () => {
  const { body, flushFrames, log, motion, panel } = fakeHost({ reduced: true });
  motion.set(true);
  motion.set(false);
  flushFrames();
  expect(body.dataset.filesHidden).toBe("true");
  expect(panel.dataset.filesMotion).toBeUndefined();
  expect(log).toEqual([]);
});
