// The chat page's launch settle (src/agent-session/acpmux/launchSettle.ts): from its first paint, when
// the page last moved and its largest move, reported once as `pane.launchSettle` for the launch marks
// `web.layout.settle`, `web.layout.max_move(.<element>)` and `web.layout.shifts`. These hold:
// - a page where nothing moves settles at its first paint, with no shifts and no move;
// - a move is the largest change of an element's box from where it first showed (layoutWatch.ts), the
//   settle is the last frame that moved, and a 1 px change is no move;
// - Chromium's layout-shift entries count, once per frame, with the element they name;
// - the watch ends after QUIET_MS with nothing moving or at CAP_MS;
// - on the page: one report per document, at the person's first press (ending every listener and the
//   cap timer), none for a hidden page.
import { afterEach, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import {
  CAP_MS,
  LaunchSettle,
  QUIET_MS,
  readSettleBoxes,
  resetLaunchSettleForTest,
  watchLaunchSettle,
  type SettleBox,
} from "../src/agent-session/acpmux/launchSettle";

const T0 = 1_700_000_000_000;
const box = (y: number, h = 40): SettleBox => ({ x: 0, y, w: 600, h });
const frame = (entries: Record<string, SettleBox>) => new Map(Object.entries(entries));

describe("LaunchSettle", () => {
  test("nothing moves: settles at first paint", () => {
    const settle = new LaunchSettle(T0);
    for (let at = 0; at < 600; at += 16)
      settle.frame(T0 + at, frame({ composer: box(900, 80), "transcript-row:a": box(100) }));
    expect(settle.report()).toEqual({ settledEpochMs: T0, maxMovePx: 0, element: "none", shifts: 0 });
  });

  test("the last move is the settle; the largest move names its element", () => {
    const settle = new LaunchSettle(T0);
    settle.frame(T0, frame({ composer: box(900, 80), "transcript-row:a": box(100) }));
    // The composer grows 1 px (no move), then the row drops 30 px, then the composer rises 12 px.
    settle.frame(T0 + 16, frame({ composer: box(900, 81), "transcript-row:a": box(100) }));
    settle.frame(T0 + 300, frame({ composer: box(900, 81), "transcript-row:a": box(130) }));
    settle.frame(T0 + 316, frame({ composer: box(900, 81), "transcript-row:a": box(130) }));
    settle.frame(T0 + 700, frame({ composer: box(888, 81), "transcript-row:a": box(130) }));
    expect(settle.report()).toEqual({
      settledEpochMs: T0 + 700,
      maxMovePx: 30,
      element: "transcript-row",
      shifts: 2,
    });
  });

  test("a move is measured from where the element first showed, over several frames", () => {
    const settle = new LaunchSettle(T0);
    settle.frame(T0, frame({ scroller: box(48, 800) }));
    // A row that shows later starts there; a slide of 10 px a frame adds up.
    for (let step = 1; step <= 5; step += 1)
      settle.frame(T0 + step * 16, frame({ scroller: box(48 + step * 10, 800), "transcript-row:b": box(500) }));
    expect(settle.report()).toMatchObject({ maxMovePx: 50, element: "scroller", shifts: 5 });
  });

  test("layout-shift entries count once per frame", () => {
    const settle = new LaunchSettle(T0);
    settle.frame(T0, frame({ composer: box(900, 80) }));
    settle.frame(T0 + 200, frame({ composer: box(860, 80) }));
    settle.shift(T0 + 205, "header", 8);
    settle.shift(T0 + 400, "other", 64);
    settle.shift(T0 + 500, "other", 1);
    expect(settle.report()).toEqual({ settledEpochMs: T0 + 400, maxMovePx: 64, element: "other", shifts: 2 });
  });

  test("ends quiet after QUIET_MS, or at CAP_MS however it moves", () => {
    const quiet = new LaunchSettle(T0);
    quiet.frame(T0 + 100, frame({ composer: box(900) }));
    expect(quiet.done(T0 + QUIET_MS - 1)).toBe(false);
    expect(quiet.done(T0 + QUIET_MS)).toBe(true);
    const moving = new LaunchSettle(T0);
    for (let at = 0; at <= CAP_MS; at += 100) {
      moving.frame(T0 + at, frame({ composer: box(900 - at / 50) }));
      expect(moving.done(T0 + at)).toBe(at >= CAP_MS);
    }
  });
});

describe("watchLaunchSettle", () => {
  afterEach(() => resetLaunchSettleForTest());

  function page(hidden = false, measured = true) {
    const dom = new JSDOM(
      `<!doctype html><main id="root"><div class="acpmux-scroll"><article class="acpmux-row" data-row-id="r1">a</article></div><div class="acpmux-composer-box"></div></main>`,
      { pretendToBeVisual: true },
    );
    // What the host's `__snapshot/chat.js` sets while a launch harness reads the marks.
    if (measured) Object.assign(dom.window, { __cmuxLaunchMeasured: true });
    if (hidden) Object.defineProperty(dom.window.document, "visibilityState", { value: "hidden" });
    const sent: [string, Record<string, unknown>][] = [];
    const report = (method: string, params: Record<string, unknown>) => {
      sent.push([method, params]);
      return Promise.resolve(null);
    };
    return { dom, sent, report };
  }

  test("reports once, at the first press, and leaves no timer or listener", () => {
    const { dom, sent, report } = page();
    const view = dom.window;
    let timers = 0;
    const setTimeout = view.setTimeout.bind(view);
    const clearTimeout = view.clearTimeout.bind(view);
    view.setTimeout = ((handler: () => void, ms?: number) => {
      timers += 1;
      return setTimeout(handler, ms);
    }) as typeof view.setTimeout;
    view.clearTimeout = ((id?: number) => {
      timers -= 1;
      clearTimeout(id);
    }) as typeof view.clearTimeout;
    watchLaunchSettle(report, "cmux-chat-snapshot", view.document);
    // A second first paint (the live page after its copy) starts nothing.
    watchLaunchSettle(report, "cmux-chat-snapshot", view.document);
    expect(timers).toBe(1);
    view.dispatchEvent(new view.Event("pointerdown"));
    view.dispatchEvent(new view.Event("keydown"));
    expect(timers).toBe(0);
    expect(sent).toHaveLength(1);
    expect(sent[0]![0]).toBe("pane.launchSettle");
    expect(sent[0]![1]).toMatchObject({ maxMovePx: 0, element: "none", shifts: 0 });
    expect(typeof sent[0]![1].settledEpochMs).toBe("number");
    dom.window.close();
  });

  test("a launch no harness measures watches nothing", () => {
    const { dom, sent, report } = page(false, false);
    const view = dom.window;
    let frames = 0;
    const requestAnimationFrame = view.requestAnimationFrame.bind(view);
    view.requestAnimationFrame = ((callback: FrameRequestCallback) => {
      frames += 1;
      return requestAnimationFrame(callback);
    }) as typeof view.requestAnimationFrame;
    watchLaunchSettle(report, "cmux-chat-snapshot", view.document);
    view.dispatchEvent(new view.Event("pointerdown"));
    expect(frames).toBe(0);
    expect(sent).toHaveLength(0);
    dom.window.close();
  });

  test("a hidden page watches nothing", () => {
    const { dom, sent, report } = page(true);
    watchLaunchSettle(report, "cmux-chat-snapshot", dom.window.document);
    dom.window.dispatchEvent(new dom.window.Event("pointerdown"));
    expect(sent).toHaveLength(0);
    dom.window.close();
  });

  test("reads the composer, the scroller and the rows in view by id", () => {
    const { dom } = page();
    const doc = dom.window.document;
    const rects: Record<string, [number, number, number, number]> = {
      "acpmux-scroll": [0, 48, 600, 800],
      "acpmux-row": [0, 100, 600, 40],
      "acpmux-composer-box": [0, 860, 600, 80],
    };
    for (const [name, [x, y, w, h]] of Object.entries(rects))
      (doc.querySelector(`.${name}`) as HTMLElement).getBoundingClientRect = () =>
        ({ x, y, width: w, height: h, top: y, bottom: y + h, left: x, right: x + w }) as DOMRect;
    expect([...readSettleBoxes(doc, "cmux-chat-snapshot").keys()].sort()).toEqual([
      "composer",
      "scroller",
      "transcript-row:r1",
    ]);
    // The live root held clear with no copy over it shows nothing.
    doc.getElementById("root")!.style.opacity = "0";
    expect(readSettleBoxes(doc, "cmux-chat-snapshot").size).toBe(0);
    dom.window.close();
  });
});
