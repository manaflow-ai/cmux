import { afterEach, expect, test } from "bun:test";
import { startScrollCoverage, type ScrollCoverage } from "../bench/scrollCoverage";

type PaintedSample = {
  read: (time: number) => boolean | void;
  cancelled: boolean;
};
type RowRect = { index: number; top: number; bottom: number; size?: number };

const restores: (() => void)[] = [];
afterEach(() => {
  for (const restore of restores.splice(0).reverse()) restore();
});

function replaceGlobal(name: string, value: unknown) {
  const original = Object.getOwnPropertyDescriptor(globalThis, name);
  Object.defineProperty(globalThis, name, { configurable: true, writable: true, value });
  restores.push(() => {
    if (original) Object.defineProperty(globalThis, name, original);
    else Reflect.deleteProperty(globalThis, name);
  });
}

/** Geometry is in viewport coordinates, as browser row rects are; no DOM renderer is needed. */
function page({ paddingTop = 0, initialTop = 100, timeoutMs = 1_000 } = {}) {
  let clock = 0;
  let rows: RowRect[] = [{ index: 1, top: 0, bottom: 100 }];
  const samples: PaintedSample[] = [];
  const thread = {};
  const scroller = {
    scrollTop: initialTop,
    clientTop: 0,
    clientHeight: 100,
    scrollHeight: 10_000,
    getBoundingClientRect: () => ({ top: 0, bottom: 100 }),
    querySelector: (selector: string) => (selector === ".acpmux-thread" ? thread : null),
    querySelectorAll: (selector: string) =>
      selector === ".acpmux-row"
        ? rows.map(({ index, top, bottom, size }) => ({
            getAttribute: (name: string) =>
              name === "aria-posinset" ? String(index) : name === "aria-setsize" ? String(size ?? 100) : null,
            getBoundingClientRect: () => ({ top, bottom }),
          }))
        : [],
  };
  const browser: {
    __stopScrollCoverage?: () => ScrollCoverage;
    cmuxAfterPaint: (read: PaintedSample["read"]) => () => void;
  } = {
    cmuxAfterPaint(read) {
      const sample = { read, cancelled: false };
      samples.push(sample);
      return () => {
        sample.cancelled = true;
      };
    },
  };
  replaceGlobal("window", browser);
  replaceGlobal("document", {
    querySelector: (selector: string) => (selector === ".acpmux-scroll" ? scroller : null),
  });
  replaceGlobal("getComputedStyle", () => ({ paddingTop: `${paddingTop}px` }));
  replaceGlobal("performance", { now: () => clock });
  const start = () => startScrollCoverage({ timeoutMs });
  restores.push(() => browser.__stopScrollCoverage?.());
  start();
  return {
    start,
    get stop() {
      return browser.__stopScrollCoverage!;
    },
    scroller,
    samples,
    rows(next: RowRect[]) {
      rows = next;
    },
    paint(time: number) {
      clock = time;
      const sample = samples.at(-1)!;
      if (!sample.cancelled && sample.read(time) === false) sample.cancelled = true;
    },
  };
}

test("consecutive rendered rows cover intentional inter-row spacing", () => {
  const view = page();
  view.paint(0); // Initial placement is not a scroll sample.
  view.scroller.scrollTop += 1;
  view.rows([
    { index: 7, top: -10, bottom: 40 },
    { index: 8, top: 56, bottom: 110 },
  ]);
  view.paint(8);
  expect(view.stop()).toMatchObject({
    frames: 1,
    blank_frames: 0,
    blank_ms: 0,
    max_uncovered_px: 0,
  });
});

test("a missing row leaves a measurable blank strip in the viewport", () => {
  const view = page();
  view.scroller.scrollTop += 1;
  view.rows([
    { index: 7, top: -10, bottom: 40 },
    { index: 9, top: 70, bottom: 110 },
  ]);
  view.paint(8);
  expect(view.stop()).toMatchObject({ frames: 1, blank_frames: 1, max_uncovered_px: 30 });
});

test("trailing room is intentional only after a visible mounted final row", () => {
  const view = page();
  view.scroller.scrollTop += 1;
  view.rows([{ index: 9, size: 9, top: -10, bottom: 70 }]);
  view.paint(8);
  expect(view.stop()).toMatchObject({ blank_frames: 0, max_uncovered_px: 0 });
  view.start();
  view.scroller.scrollTop += 1;
  view.rows([{ index: 8, size: 9, top: -10, bottom: 70 }]);
  view.paint(16);
  expect(view.stop()).toMatchObject({ blank_frames: 1, max_uncovered_px: 30 });
  view.start();
  view.scroller.scrollTop += 1;
  view.rows([{ index: 9, size: 9, top: -50, bottom: -10 }]);
  view.paint(24);
  expect(view.stop()).toMatchObject({ blank_frames: 1, max_uncovered_px: 100 });
});

test("blank time belongs to the preceding painted frame, not its clean replacement", () => {
  const view = page();
  view.scroller.scrollTop += 1;
  view.rows([]);
  view.paint(10);
  view.rows([{ index: 3, top: 0, bottom: 100 }]);
  view.paint(30);
  view.paint(70);
  expect(view.stop()).toMatchObject({ frames: 3, blank_frames: 1, blank_ms: 20, duration_ms: 60 });
});

test("the transcript's top padding is intentional space when scrolling back to the start", () => {
  const view = page({ paddingTop: 24 });
  view.scroller.scrollTop = 0;
  view.rows([{ index: 1, top: 24, bottom: 120 }]);
  view.paint(8);
  expect(view.stop()).toMatchObject({ frames: 1, blank_frames: 0, max_uncovered_px: 0 });
});

test("the deadline marks an incomplete observation and ends sampling", () => {
  const view = page({ timeoutMs: 25 });
  view.scroller.scrollTop += 1;
  view.paint(8);
  view.paint(25);
  expect(view.samples[0].cancelled).toBe(true);
  expect(view.stop()).toMatchObject({ frames: 1, timed_out: true });
});

test("stopping and restarting leave no old sampler able to change either result", () => {
  const view = page();
  view.scroller.scrollTop += 1;
  view.paint(8);
  const firstStop = view.stop;
  const firstResult = firstStop();
  const firstSample = view.samples[0];
  expect(firstSample.cancelled).toBe(true);
  view.start();
  view.scroller.scrollTop += 1;
  view.paint(16);
  const secondSample = view.samples[1];
  const secondStop = view.stop;
  view.start(); // Starting over must cancel even a sampler not explicitly stopped.
  expect(secondSample.cancelled).toBe(true);
  view.scroller.scrollTop += 1;
  view.rows([]);
  // Model already-queued callbacks arriving after their cancellation.
  firstSample.read(20);
  secondSample.read(20);
  view.rows([{ index: 5, top: 0, bottom: 100 }]);
  view.paint(24);
  expect(firstStop()).toEqual(firstResult);
  expect(secondStop()).toMatchObject({ frames: 1, blank_frames: 0 });
  expect(view.stop()).toMatchObject({ frames: 1, blank_frames: 0, distance_px: 1 });
});
