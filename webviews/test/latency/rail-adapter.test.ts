import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { measureRailDrag, railDragTargetPainted } from "../../bench/thread-rail-drag.adapter";
import { RAIL_DRAG_PAGE } from "./actions";
import { aggregateAdapterAction } from "./adapter-measure";
type Page = Parameters<typeof railDragTargetPainted>[0];

const dom = new JSDOM(
  '<!doctype html><main class="acpmux-scroll"><div class="acpmux-row" data-row-id="user-42"><p class="cv-user__bubble">Target prompt</p></div></main>',
);
const scope = globalThis as Record<string, unknown>;
const saved = {
  window: scope.window,
  document: scope.document,
  hadWindow: "window" in scope,
  hadDocument: "document" in scope,
};
const page = {
  evaluate: async (fn: (arg: unknown) => unknown, arg: unknown) => fn(arg),
} as unknown as Page;
const transcript = dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
const bubble = dom.window.document.querySelector<HTMLElement>(".cv-user__bubble")!;
const rect = (x: number, y: number, width: number, height: number) => new dom.window.DOMRect(x, y, width, height);
let bubbleBox = rect(180, 150, 240, 40);
beforeAll(() => {
  Object.assign(globalThis, { window: dom.window, document: dom.window.document });
  transcript.getBoundingClientRect = () => rect(100, 50, 700, 500);
  bubble.getBoundingClientRect = () => bubbleBox;
});
afterAll(() => {
  for (const [key, existed] of [
    ["window", saved.hadWindow],
    ["document", saved.hadDocument],
  ] as const) {
    if (existed) scope[key] = saved[key];
    else delete scope[key];
  }
  dom.window.close();
});

test("rail target requires the requested connected row and a nonzero bubble in view", async () => {
  bubbleBox = rect(180, 150, 240, 40);
  expect(await railDragTargetPainted(page, "user-42")).toBe(true);
  expect(await railDragTargetPainted(page, "user-43")).toBe(false);
  bubbleBox = rect(180, 150, 0, 40);
  expect(await railDragTargetPainted(page, "user-42")).toBe(false);
  bubbleBox = rect(180, 900, 240, 40);
  expect(await railDragTargetPainted(page, "user-42")).toBe(false);
});

test("rail target must intersect both viewport axes", async () => {
  bubbleBox = rect(1100, 150, 240, 40);
  expect(await railDragTargetPainted(page, "user-42")).toBe(false);
  bubbleBox = rect(820, 150, 100, 40);
  expect(await railDragTargetPainted(page, "user-42")).toBe(false);
});

test("unmounted ticks retain an unsupported null sample instead of a zero latency", async () => {
  const tick = { scrollIntoViewIfNeeded: async () => {}, boundingBox: async () => null };
  const unavailable = { locator: () => ({ locator: () => tick }) } as unknown as Page;
  const result = await measureRailDrag(unavailable, { startIndex: 1, targetIndex: 2, targetRowId: "user-42" });
  expect(result.samples).toEqual([]);
  expect(result.release).toEqual({
    inputAt: null,
    firstPaintAt: null,
    latencyMs: null,
    alreadyPaintedBeforeRelease: false,
  });
  expect(result.droppedFrames).toBeNull();
  expect(result.unsupported.length).toBeGreaterThan(0);
});

test("rail cadence excludes a pre-input frame timestamp older than sampler installation", async () => {
  const list = dom.window.document.createElement("ol");
  list.className = "acpmux-minimap__list";
  list.innerHTML = '<li aria-setsize="8"><button data-tick="1"></button><button data-tick="2"></button></li>';
  list.getBoundingClientRect = () => rect(0, 0, 36, 80);
  dom.window.document.body.append(list);
  bubbleBox = rect(180, 150, 240, 40);
  let paint: ((frame: number) => unknown) | undefined;
  let buttons = 0;
  let firstMove = true;
  const windowScope = dom.window as unknown as { cmuxAfterPaint: (read: (frame: number) => unknown) => () => void };
  windowScope.cmuxAfterPaint = (read) => {
    paint = read;
    return () => {
      paint = undefined;
    };
  };
  const source = {
    scrollIntoViewIfNeeded: async () => {},
    boundingBox: async () => ({ x: 0, y: 10, width: 36, height: 10 }),
  };
  const target = { ...source, boundingBox: async () => ({ x: 0, y: 20, width: 36, height: 10 }) };
  const simulated = {
    locator: () => ({ locator: (selector: string) => (selector.includes('"1"') ? source : target) }),
    evaluate: async (fn: (arg: unknown) => unknown, arg: unknown) => {
      const result = fn(arg);
      if (result instanceof Promise) paint?.(performance.now());
      return result;
    },
    mouse: {
      async move(_x: number, y: number) {
        // rAF timestamps belong to a frame's start and may precede the sampler installation.
        if (firstMove) {
          firstMove = false;
          paint?.(0);
        }
        dom.window.dispatchEvent(new dom.window.MouseEvent("pointermove", { clientY: y, buttons }));
      },
      async down() {
        buttons = 1;
      },
      async up() {
        buttons = 0;
        dom.window.dispatchEvent(new dom.window.MouseEvent("pointerup"));
      },
    },
  } as unknown as Page;
  try {
    const result = await measureRailDrag(simulated, { startIndex: 1, targetIndex: 2, targetRowId: "user-42" });
    expect(result.samples.some((sample) => sample.status === "painted")).toBe(true);
    expect(result.frameGaps.every((gap) => gap >= 0)).toBe(true);
  } finally {
    list.remove();
  }
});

test("both registered rail cases invoke the real pointer sampler and preserve raw moves, release and cadence", async () => {
  const list = dom.window.document.createElement("ol");
  list.className = "acpmux-minimap__list";
  list.innerHTML = Array.from(
    { length: 8 },
    (_, index) => `<li aria-setsize="8"><button data-tick="${index}"></button></li>`,
  ).join("");
  list.getBoundingClientRect = () => rect(0, 0, 36, 80);
  for (const tick of list.querySelectorAll<HTMLElement>("[data-tick]"))
    tick.getBoundingClientRect = () => rect(0, Number(tick.dataset.tick) * 10, 36, 10);
  dom.window.document.body.append(list);
  const row = bubble.closest<HTMLElement>(".acpmux-row")!;
  row.dataset.rowId = "synthetic-user-2";
  bubbleBox = rect(180, 150, 240, 40);
  const windowScope = dom.window as unknown as {
    cmuxAfterPaint: (read: (frame: number) => unknown) => () => void;
    cmuxPaintFrame: () => Promise<number>;
    __railDragSampler?: unknown;
  };
  const savedInnerHeight = globalThis.innerHeight;
  Object.assign(globalThis, { innerHeight: dom.window.innerHeight });
  try {
    for (const action of RAIL_DRAG_PAGE.actions) {
      let paint: ((frame: number) => unknown) | undefined;
      let buttons = 0;
      let y = 0;
      let moved = 0;
      windowScope.cmuxPaintFrame = async () => performance.now();
      windowScope.cmuxAfterPaint = (read) => {
        paint = read;
        return () => {
          paint = undefined;
        };
      };
      const simulated = {
        isClosed: () => false,
        locator: () => ({
          locator: (selector: string) => ({
            scrollIntoViewIfNeeded: async () => {},
            boundingBox: async () => {
              const box = list.querySelector<HTMLElement>(selector)!.getBoundingClientRect();
              return { x: box.x, y: box.y, width: box.width, height: box.height };
            },
          }),
        }),
        evaluate: async (fn: (arg: unknown) => unknown, arg: unknown) => {
          const result = fn(arg);
          if (result instanceof Promise && paint) paint(16.7);
          return result;
        },
        mouse: {
          async move(_x: number, to: number, options?: { steps: number }) {
            if (!buttons) paint?.(0);
            const from = y;
            const steps = options?.steps ?? 1;
            for (let step = 1; step <= steps; step++) {
              y = from + ((to - from) * step) / steps;
              moved += buttons ? 1 : 0;
              dom.window.dispatchEvent(new dom.window.MouseEvent("pointermove", { clientY: y, buttons }));
            }
          },
          async down() {
            buttons = 1;
          },
          async up() {
            buttons = 0;
            dom.window.dispatchEvent(new dom.window.MouseEvent("pointerup"));
          },
        },
      } as unknown as Page;
      const cleanup: (() => void | Promise<void>)[] = [];
      const controller = new AbortController();
      const result = await action.measureRun!(simulated, {
        frameMs: 16.7,
        timeoutMs: 10_500,
        signal: controller.signal,
        onCleanup: (dispose) => cleanup.push(dispose),
      });
      expect(moved).toBe(2);
      expect(result.status).toBe("complete");
      expect(result.observations.map((entry) => entry.status)).toEqual(["superseded", "painted"]);
      expect(result.observations[0].latencyMs).toBeNull();
      const painted = result.observations[1];
      expect(painted.latencyMs).toBeGreaterThanOrEqual(0);
      expect(painted.targetPaintAt! - painted.inputAt!).toBe(painted.latencyMs!);
      expect(painted.raw.targetRowId).toBe("synthetic-user-2");
      expect(painted.raw.releaseToPaintMs).toBeGreaterThanOrEqual(0);
      expect(painted.raw.lastMoveToPaintMs).toBe(painted.latencyMs);
      expect(painted.raw.alreadyPaintedBeforeRelease).toBe(false);
      expect(result.frameGaps).toEqual([16.7]);
      const aggregated = aggregateAdapterAction({ page: "chat rail", engine: "chromium" }, action, [result], 1, 16.7);
      expect(aggregated.errors).toEqual([]);
      expect(aggregated.latencyMs?.p50).toBe(action.metricType === "frame_time" ? 16.7 : painted.latencyMs!);
      controller.abort();
      for (const dispose of cleanup) await dispose();
      expect(buttons).toBe(0);
      expect(paint).toBeUndefined();
      expect(windowScope.__railDragSampler).toBeUndefined();
    }
  } finally {
    row.dataset.rowId = "user-42";
    list.remove();
    if (savedInnerHeight === undefined) delete (globalThis as Record<string, unknown>).innerHeight;
    else Object.assign(globalThis, { innerHeight: savedInnerHeight });
  }
});
