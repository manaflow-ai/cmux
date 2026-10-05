import { expect, test } from "bun:test";
import {
  createFilesPanelMotion,
  curtainKeyframes,
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

function fakeHost(options: { reduced?: boolean; offset?: number; timeline?: number } = {}) {
  const log: string[] = [];
  const frames: (() => void)[] = [];
  type Record = {
    target: string;
    keyframes: any[];
    options: any;
    cancelled: boolean;
    resolve: () => void;
    startTime: number | null;
  };
  const animations: Record[] = [];
  const animate = (target: string) => (keyframes: any[], animationOptions: any) => {
    let resolve = () => {};
    const finished = new Promise<void>((done) => (resolve = done));
    const record = {
      target,
      keyframes,
      options: animationOptions,
      cancelled: false,
      resolve,
      startTime: null as number | null,
    };
    animations.push(record);
    log.push(`${target} ${keyframes[0].transform} -> ${keyframes.at(-1).transform}`);
    return {
      cancel: () => {
        record.cancelled = true;
      },
      finished,
      set startTime(time: number | null) {
        record.startTime = time;
      },
      get startTime() {
        return record.startTime;
      },
    } as any;
  };
  const panel = {
    dataset: {} as DOMStringMap,
    getBoundingClientRect: () => ({ width: 252 }) as DOMRect,
    animate: animate("panel"),
  };
  const curtain = { animate: animate("curtain") };
  const body = { dataset: {} as DOMStringMap };
  const motion = createFilesPanelMotion({
    panel: () => panel as any,
    curtain: () => curtain as any,
    body,
    currentOffset: () => options.offset ?? 0,
    requestFrame: (callback) => frames.push(callback),
    reducedMotion: () => options.reduced ?? false,
    timelineTime: options.timeline === undefined ? undefined : () => options.timeline!,
  });
  const live = (target: string) => animations.filter((a) => a.target === target && !a.cancelled);
  const finish = async (record: Record) => {
    record.resolve();
    await Promise.resolve();
    await Promise.resolve();
  };
  return { animations, body, finish, frames, live, log, motion, panel };
}

test("closing slides the panel at once and widens the diff only when the slide ends", async () => {
  const { animations, body, finish, frames, log, motion, panel } = fakeHost();
  motion.set(true);
  // Boot: the resting state, no motion.
  expect(body.dataset.filesHidden).toBe("false");
  expect(log).toEqual([]);

  motion.set(false);
  // The toggle's frame: the slide and the curtain start; the diff keeps its layout.
  expect(body.dataset.filesHidden).toBe("false");
  expect(panel.dataset.filesMotion).toBe("running");
  expect(panel.dataset.filesMotionTarget).toBe("closed");
  expect(frames).toEqual([]);
  expect(log).toEqual(["panel translate3d(0px, 0, 0) -> translate3d(252px, 0, 0)", "curtain scaleX(0) -> scaleX(1)"]);
  const [slide, curtain] = animations;
  expect(slide.options).toEqual({
    duration: springCurve(MOTION_SPRINGS.disappear).durationMs,
    easing: "linear",
    fill: "forwards",
  });
  expect(slide.keyframes).toEqual(springSlideKeyframes(MOTION_SPRINGS.disappear, 0, 252).keyframes);
  // The curtain follows the panel's offset on the same curve, frame for frame.
  expect(curtain.keyframes).toEqual(curtainKeyframes(MOTION_SPRINGS.disappear, 0, 252, 252));
  expect(curtain.options).toEqual(slide.options);
  await finish(slide);
  // The one reflow, when the slide ends; the curtain goes with it.
  expect(body.dataset.filesHidden).toBe("true");
  expect(panel.dataset.filesMotion).toBeUndefined();
  expect(curtain.cancelled).toBe(true);
});

test("opening slides over the full-width diff (no curtain) and narrows it when the slide ends", async () => {
  const { animations, body, finish, log, motion } = fakeHost();
  motion.set(false);
  motion.set(true);
  expect(body.dataset.filesHidden).toBe("true");
  expect(log).toEqual(["panel translate3d(252px, 0, 0) -> translate3d(0px, 0, 0)"]);
  await finish(animations[0]);
  expect(body.dataset.filesHidden).toBe("false");
});

test("toggling mid-slide reverses from the panel's current position; the diff keeps its width", async () => {
  // Closing, half-way out (120px), the user opens it again.
  const closing = fakeHost({ offset: 120 });
  closing.motion.set(true);
  closing.motion.set(false);
  const [slide, curtain] = closing.animations;
  closing.motion.set(true);
  expect(slide.cancelled && curtain.cancelled).toBe(true);
  // The diff never left its narrow layout, so the curtain reverses with the panel.
  expect(closing.log.slice(-2)).toEqual([
    "panel translate3d(120px, 0, 0) -> translate3d(0px, 0, 0)",
    "curtain scaleX(0.4762) -> scaleX(0)",
  ]);
  expect(closing.panel.dataset.filesMotionTarget).toBe("open");
  expect(closing.body.dataset.filesHidden).toBe("false");
  // The cancelled slide ending late changes nothing.
  await closing.finish(slide);
  expect(closing.body.dataset.filesHidden).toBe("false");
  const reverse = closing.live("panel")[0];
  expect(reverse.options.duration).toBe(springCurve(MOTION_SPRINGS.appear).durationMs);
  await closing.finish(reverse);
  expect(closing.body.dataset.filesHidden).toBe("false");

  // Opening, half-way in, the user closes it again: the diff is still full width under the panel.
  const opening = fakeHost({ offset: 120 });
  opening.motion.set(false);
  opening.motion.set(true);
  opening.motion.set(false);
  expect(opening.log.at(-1)).toBe("panel translate3d(120px, 0, 0) -> translate3d(252px, 0, 0)");
  expect(opening.live("curtain")).toEqual([]);
  await opening.finish(opening.live("panel")[0]);
  expect(opening.body.dataset.filesHidden).toBe("true");
});

test("with reduced motion the panel switches in one frame", () => {
  const { body, log, motion, panel } = fakeHost({ reduced: true });
  motion.set(true);
  motion.set(false);
  expect(body.dataset.filesHidden).toBe("true");
  expect(panel.dataset.filesMotion).toBeUndefined();
  expect(log).toEqual([]);
});

test("the panel and the curtain start at the same timeline time", () => {
  const { animations, motion } = fakeHost({ timeline: 1234.5 });
  motion.set(true);
  motion.set(false);
  expect(animations.map((animation) => [animation.target, animation.startTime])).toEqual([
    ["panel", 1234.5],
    ["curtain", 1234.5],
  ]);
});
