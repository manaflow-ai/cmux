import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { runPlay, selectTextWithDriver, syntheticKey, syntheticPointer } from "../src/gallery/frame/playRunner";
import { isSubpixelLayoutShift, longFramePart } from "../src/gallery/play";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "HTMLInputElement",
  "ShadowRoot",
  "KeyboardEvent",
  "MouseEvent",
  "PointerEvent",
  "getComputedStyle",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><main id=root></main>", { pretendToBeVisual: true });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    HTMLInputElement: dom.window.HTMLInputElement,
    ShadowRoot: dom.window.ShadowRoot,
    KeyboardEvent: dom.window.KeyboardEvent,
    MouseEvent: dom.window.MouseEvent,
    PointerEvent: dom.window.PointerEvent ?? dom.window.MouseEvent,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  });
});

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

describe("gallery shell keyboard emulation", () => {
  test("moves focus through tabbable controls in both directions", () => {
    document.getElementById("root")!.innerHTML = `
      <button id="before">Before</button>
      <button id="disabled" disabled>Disabled</button>
      <button id="first">First</button>
      <button id="hidden" hidden>Hidden</button>
      <button id="second">Second</button>
    `;
    const first = document.getElementById("first") as HTMLButtonElement;
    const second = document.getElementById("second") as HTMLButtonElement;
    first.focus();

    syntheticKey("Tab");
    expect(document.activeElement).toBe(second);
    syntheticKey("Shift+Tab");
    expect(document.activeElement).toBe(first);
  });

  test("keeps positive tabindex controls ahead of normal controls", () => {
    document.getElementById("root")!.innerHTML = `
      <button id="normal">Normal</button>
      <button id="second-positive" tabindex="2">Second positive</button>
      <button id="first-positive" tabindex="1">First positive</button>
    `;
    const first = document.getElementById("first-positive") as HTMLButtonElement;
    const second = document.getElementById("second-positive") as HTMLButtonElement;
    first.focus();

    syntheticKey("Tab");
    expect(document.activeElement).toBe(second);
  });

  test("skips controls hidden by ancestors, closed details, or a shadow host", () => {
    document.getElementById("root")!.innerHTML = `
      <button id="first">First</button>
      <div hidden><button id="hidden">Hidden</button></div>
      <div style="display: none"><button id="display-none">Display none</button></div>
      <details><button id="closed-details">Closed details</button></details>
      <button id="second">Second</button>
    `;
    const host = document.createElement("div");
    host.hidden = true;
    host.attachShadow({ mode: "open" }).innerHTML = '<button id="shadow-hidden">Shadow hidden</button>';
    document.getElementById("root")!.append(host);
    const first = document.getElementById("first") as HTMLButtonElement;
    const second = document.getElementById("second") as HTMLButtonElement;
    first.focus();

    syntheticKey("Tab");
    expect(document.activeElement).toBe(second);
  });

  test("dispatches keyup to the element that receives focus", () => {
    document.getElementById("root")!.innerHTML = '<button id="first">First</button><button id="second">Second</button>';
    const first = document.getElementById("first") as HTMLButtonElement;
    const second = document.getElementById("second") as HTMLButtonElement;
    const keyup: string[] = [];
    first.addEventListener("keyup", () => keyup.push("first"));
    second.addEventListener("keyup", () => keyup.push("second"));
    first.focus();

    syntheticKey("Tab");
    expect(keyup).toEqual(["second"]);
  });

  test("leaves focus to a key handler that prevents the default", () => {
    document.getElementById("root")!.innerHTML = '<button id="first">First</button><button id="second">Second</button>';
    const first = document.getElementById("first") as HTMLButtonElement;
    const second = document.getElementById("second") as HTMLButtonElement;
    first.addEventListener("keydown", (event) => event.preventDefault());
    first.focus();

    syntheticKey("Tab");
    expect(document.activeElement).toBe(first);
    expect(document.activeElement).not.toBe(second);
  });

  test("uses the trusted driver to drag across all rendered text lines", async () => {
    const root = document.getElementById("root")!;
    root.innerHTML = '<p id="copy">first line<br />second line</p>';
    const element = document.getElementById("copy")!;
    const rangePrototype = dom.window.Range.prototype;
    const descriptor = Object.getOwnPropertyDescriptor(rangePrototype, "getClientRects");
    Object.defineProperty(rangePrototype, "getClientRects", {
      configurable: true,
      value: () => [
        { left: 10, right: 70, top: 20, width: 60, height: 10 },
        { left: 10, right: 90, top: 40, width: 80, height: 10 },
      ],
    });
    try {
      const actions: { kind: string; x?: number; y?: number }[] = [];
      await selectTextWithDriver(element, async (action) => {
        actions.push(action);
      });
      expect(actions.map(({ kind }) => kind)).toEqual(["down", "move", "up"]);
      expect(actions[0]).toMatchObject({ kind: "down", x: 12, y: 25 });
      expect(actions[1]).toMatchObject({ kind: "move", x: 88, y: 45 });
      expect(actions[2]).toMatchObject({ kind: "up", x: 88, y: 45 });
    } finally {
      if (descriptor) Object.defineProperty(rangePrototype, "getClientRects", descriptor);
      else delete (rangePrototype as { getClientRects?: unknown }).getClientRects;
    }
  });
});

describe("gallery shell pointer emulation", () => {
  test("a press holds the button through its moves and carries screen coordinates, as a person's does", () => {
    const root = document.getElementById("root")!;
    root.innerHTML = '<div id="card"></div><div id="row"></div>';
    const card = document.getElementById("card")!;
    const row = document.getElementById("row")!;
    card.getBoundingClientRect = () => ({ x: 0, y: 400, width: 200, height: 40 }) as DOMRect;
    row.getBoundingClientRect = () => ({ x: 0, y: 100, width: 200, height: 20 }) as DOMRect;
    const seen: string[] = [];
    const log = (event: Event) => {
      const pointer = event as PointerEvent;
      seen.push(
        `${event.type} ${pointer.buttons} ${pointer.screenX - pointer.clientX},${pointer.screenY - pointer.clientY} ${pointer.screenY}`,
      );
    };
    for (const type of ["pointerdown", "pointermove", "pointerup"]) root.addEventListener(type, log);
    try {
      syntheticPointer(row, "hover");
      syntheticPointer(card, "down");
      syntheticPointer(row, "move");
      syntheticPointer(row, "up");
      syntheticPointer(row, "move");
      const origin = `${window.screenX},${window.screenY}`;
      expect(seen).toEqual([
        `pointermove 0 ${origin} ${110 + window.screenY}`,
        `pointerdown 1 ${origin} ${420 + window.screenY}`,
        `pointermove 1 ${origin} ${110 + window.screenY}`,
        `pointerup 0 ${origin} ${110 + window.screenY}`,
        `pointermove 0 ${origin} ${110 + window.screenY}`,
      ]);
    } finally {
      for (const type of ["pointerdown", "pointermove", "pointerup"]) root.removeEventListener(type, log);
    }
  });
});

describe("gallery layout-shift measurement", () => {
  test("ignores fractional rounding while retaining a half-pixel movement", () => {
    const rect = (x: number) => ({ x, y: 10, width: 100, height: 20 });
    expect(isSubpixelLayoutShift([{ previousRect: rect(10), currentRect: rect(10.49) }])).toBe(true);
    expect(isSubpixelLayoutShift([{ previousRect: rect(10), currentRect: rect(10.5) }])).toBe(false);
    expect(isSubpixelLayoutShift([{ previousRect: rect(10) }])).toBe(false);
  });
});

describe("where a long frame's time went", () => {
  test("a frame that the step's own handler made says the handler, and the layout it forced", () => {
    // A click at 1000 ms: its handler runs 40 ms, 12 of them a forced layout; the render is 22 ms more.
    const part = longFramePart(
      {
        startTime: 1002,
        duration: 62,
        renderStart: 1042,
        styleAndLayoutStart: 1045,
        scripts: [
          { invoker: "DOMWindow.requestAnimationFrame", duration: 3, sourceURL: "" },
          {
            invoker: "BUTTON.onclick",
            sourceFunctionName: "stop",
            sourceURL: "http://127.0.0.1:4173/assets/Composer-abc.js?v=1#x",
            duration: 37,
            forcedStyleAndLayoutDuration: 12,
          },
        ],
      },
      1000,
    );
    expect(part).toBe(
      "62.0 ms: 40.0 ms before its render, 3.0 ms frame callbacks, 19.0 ms from style and layout on; " +
        "began 2.0 ms after the step's start; " +
        "scripts 40.0 ms: BUTTON.onclick (stop in Composer-abc.js) 37.0 ms, 12.0 ms of it forced style and layout, " +
        "DOMWindow.requestAnimationFrame 3.0 ms",
    );
  });

  test("a frame that began before the step, with no script, says both", () => {
    // Nothing of the page ran: the time is the wait for the frame, which is not the step's work.
    expect(longFramePart({ startTime: 990, duration: 55, renderStart: 1044, styleAndLayoutStart: 1044.5 }, 1000)).toBe(
      "55.0 ms: 54.0 ms before its render, 0.5 ms frame callbacks, 0.5 ms from style and layout on; " +
        "began 10.0 ms before the step's start; no script of 5 ms or more",
    );
  });

  test("a frame that rendered nothing gives all its time to the part before a render", () => {
    expect(longFramePart({ startTime: 0, duration: 51, renderStart: 0, styleAndLayoutStart: 0 }, 0)).toBe(
      "51.0 ms: 51.0 ms before its render, 0.0 ms frame callbacks, 0.0 ms from style and layout on; " +
        "began 0.0 ms after the step's start; no script of 5 ms or more",
    );
  });

  test("names the three longest scripts of many, sums them all, and keeps a caller short", () => {
    // The engine names a whole script by its URL and a listener by its element's `src`: no path of
    // the machine and no image's bytes go into a CI line.
    const part = longFramePart(
      {
        startTime: 100,
        duration: 80,
        renderStart: 178,
        styleAndLayoutStart: 179,
        scripts: [
          { duration: 6 },
          { invoker: "http://127.0.0.1:5173/@fs/home/runner/work/cmux/webviews/src/main.tsx?t=17", duration: 30 },
          { invoker: `IMG[src=data:image/png;base64,${"iVBOR/w0+".repeat(4000)}].onload`, duration: 20 },
          { invoker: "IMG[src=https://example.test/shots/one.png?size=2].onload", duration: 10 },
          { invoker: `${"Deep.".repeat(40)}then`, duration: 5 },
        ],
      },
      100,
    );
    expect(part).toBe(
      "80.0 ms: 78.0 ms before its render, 1.0 ms frame callbacks, 1.0 ms from style and layout on; " +
        "began 0.0 ms after the step's start; " +
        "scripts 71.0 ms: main.tsx 30.0 ms, IMG[src=data:…].onload 20.0 ms, IMG[src=one.png].onload 10.0 ms",
    );
    // A caller with no URL in it is cut at its bound.
    const long = longFramePart(
      { startTime: 0, duration: 60, scripts: [{ invoker: "x".repeat(200), duration: 60 }] },
      0,
    );
    expect(long).toContain(`scripts 60.0 ms: ${"x".repeat(80)}… 60.0 ms`);
  });
});

describe("which long frames are a step's", () => {
  // The engine reports a Long Animation Frame after the frame ends, and a step's observer hears each
  // report that comes while the step runs. A frame that ENDED before the step began was counted in
  // the step and failed it: on a CI shard the gallery entry's own module load, a 52.0 ms frame that
  // began 56.8 ms before `click .acpmux-summary-button` and so ended 4.8 ms before it (job
  // 130436819024). The step's own frame begins a little before the step (a step with no driver
  // starts inside the frame callback that ended the last settle) and ends in it: that one is the
  // step's. The frames here end 40 ms before the step, so a slow machine does not change the case.
  //
  // A report can also be late the other way: the engine has queued it and has not delivered it when
  // the step ends. Only `takeRecords()` gives it then, and a step that drops it reads green with a
  // long frame or a layout shift in it.
  type Heard = (list: { getEntries(): unknown[] }) => void;
  /// One focus step on a stage whose engine reports `type` entries. `entry` is made when the step's
  /// observer starts, right after the step's start. "delivered": its report comes in a later task.
  /// "queued": it is still in the observer's queue when the step ends.
  const stepWithReport = async (
    type: "long-animation-frame" | "layout-shift",
    how: "delivered" | "queued",
    entry: (stepStart: number) => unknown,
  ) => {
    const root = document.getElementById("root")!;
    root.innerHTML = '<div id="row">Row</div><button id="plain">Plain</button>';
    const restore = ["requestAnimationFrame", "PerformanceObserver", "Element", "innerWidth", "innerHeight"].map(
      (key) => [key, key in scope, scope[key]] as const,
    );
    Object.assign(scope, {
      requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
      Element: dom.window.Element,
      innerWidth: 800,
      innerHeight: 600,
      PerformanceObserver: class {
        static supportedEntryTypes = [type];
        private readonly heard: Heard;
        private queued: unknown[] = [];
        constructor(heard: Heard) {
          this.heard = heard;
        }
        observe(options: { type?: string }) {
          if (options.type !== type) return;
          const made = entry(performance.now());
          if (how === "queued") this.queued.push(made);
          else setTimeout(() => this.heard({ getEntries: () => [made] }), 0);
        }
        takeRecords() {
          const taken = this.queued;
          this.queued = [];
          return taken;
        }
        disconnect() {}
      },
    });
    Object.defineProperty(dom.window, "innerWidth", { configurable: true, value: 800 });
    Object.defineProperty(dom.window, "innerHeight", { configurable: true, value: 600 });
    try {
      const report = await runPlay((ctx) => ctx.focus({ selector: "#plain" }), {});
      return report.steps[0]!;
    } finally {
      for (const [key, had, value] of restore) {
        if (had) scope[key] = value;
        else delete scope[key];
      }
      delete (dom.window as unknown as Record<string, unknown>).innerWidth;
      delete (dom.window as unknown as Record<string, unknown>).innerHeight;
    }
  };
  const stepWithFrame = (
    frame: (stepStart: number) => { startTime: number; duration: number },
    how: "delivered" | "queued" = "delivered",
  ) => stepWithReport("long-animation-frame", how, frame);

  test("a long frame that ended before the step began is not counted in the step", async () => {
    const step = await stepWithFrame((start) => ({ startTime: start - 92, duration: 52 }));
    expect(step.frameSource).toBe("long-animation-frame");
    expect(step.longFrames).toEqual([]);
    expect(step.longFrameParts).toBeUndefined();
    expect(step.problems.join("\n")).not.toMatch(/frame\(s\) over/);
  });

  test("a long frame that began before the step and ended in it is the step's, and fails it", async () => {
    const step = await stepWithFrame((start) => ({ startTime: start - 1.9, duration: 71.4 }));
    expect(step.longFrames).toEqual([71.4]);
    expect(step.longFrameParts?.length).toBe(1);
    expect(step.status).toBe("fail");
    expect(step.problems.join("\n")).toMatch(/1 frame\(s\) over 33 ms \(longest 71\.4 ms\)/);
  });

  test("a long frame whose report is still queued when the step ends is the step's, and fails it", async () => {
    const step = await stepWithFrame((start) => ({ startTime: start + 2, duration: 71.4 }), "queued");
    expect(step.frameSource).toBe("long-animation-frame");
    expect(step.longFrames).toEqual([71.4]);
    expect(step.longFrameParts?.length).toBe(1);
    expect(step.status).toBe("fail");
    expect(step.problems.join("\n")).toMatch(/1 frame\(s\) over 33 ms \(longest 71\.4 ms\)/);
  });

  test("a queued report of a long frame that ended before the step is not counted in the step", async () => {
    const step = await stepWithFrame((start) => ({ startTime: start - 92, duration: 52 }), "queued");
    expect(step.longFrames).toEqual([]);
    expect(step.problems.join("\n")).not.toMatch(/frame\(s\) over/);
  });

  test("a layout shift whose report is still queued when the step ends is the step's, and fails it", async () => {
    // The row before the button moved 40 px down: not the focused button's own expansion.
    const step = await stepWithReport("layout-shift", "queued", () => ({
      value: 0.2,
      hadRecentInput: false,
      sources: [
        {
          node: document.getElementById("row"),
          previousRect: { x: 0, y: 0, width: 100, height: 20 },
          currentRect: { x: 0, y: 40, width: 100, height: 20 },
        },
      ],
    }));
    expect(step.layoutShift).toBeCloseTo(0.2, 6);
    expect(step.shifts.map((shift) => shift.sources)).toEqual([["div [0 40 0 0]"]]);
    expect(step.status).toBe("fail");
    expect(step.problems.join("\n")).toMatch(/layout shift 0\.2000/);
  });
});

describe("gallery play settle budget", () => {
  // Headless WebKit on the CPU-only CI VM has no Long Animation Frames: the stage times frames by
  // rAF, and one software-painted frame there takes 200-450 ms where Chromium's data shows no frame
  // over 16.7 ms for the same step (new-tab typed-address). Settling waits on those
  // frames, so its latency measures the VM there as the frame timing does.
  const slowFocus = async (frameSource: "long-animation-frame" | "raf") => {
    const root = document.getElementById("root")!;
    root.innerHTML = '<button id="slow">Slow</button>';
    document.getElementById("slow")!.addEventListener("focus", () => {
      const start = performance.now();
      while (performance.now() - start < 60);
    });
    const restore = ["requestAnimationFrame", "PerformanceObserver", "innerWidth", "innerHeight"].map(
      (key) => [key, key in scope, scope[key]] as const,
    );
    Object.assign(scope, {
      requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
      innerWidth: 800,
      innerHeight: 600,
      PerformanceObserver: class {
        static supportedEntryTypes = frameSource === "raf" ? [] : ["long-animation-frame"];
        observe() {}
        takeRecords() {
          return [];
        }
        disconnect() {}
      },
    });
    // The runner reads the viewport both bare and from the window: size both.
    Object.defineProperty(dom.window, "innerWidth", { configurable: true, value: 800 });
    Object.defineProperty(dom.window, "innerHeight", { configurable: true, value: 600 });
    try {
      const report = await runPlay((ctx) => ctx.focus({ selector: "#slow" }), {
        checks: { settleMaxMs: { value: 20, reason: "A focus should settle within a frame here." } },
      });
      return report.steps[0]!;
    } finally {
      for (const [key, had, value] of restore) {
        if (had) scope[key] = value;
        else delete scope[key];
      }
      delete (dom.window as unknown as Record<string, unknown>).innerWidth;
      delete (dom.window as unknown as Record<string, unknown>).innerHeight;
    }
  };

  test("a step over its budget fails where Long Animation Frames time the page", async () => {
    const step = await slowFocus("long-animation-frame");
    expect(step.frameSource).toBe("long-animation-frame");
    expect(step.status).toBe("fail");
    expect(step.problems.join("\n")).toMatch(/settle latency .* \(limit 20 ms\)/);
  });

  test("a step over its budget only warns, with the number, where rAF times a software renderer", async () => {
    const step = await slowFocus("raf");
    expect(step.frameSource).toBe("raf");
    expect(step.settleMs).toBeGreaterThan(20);
    expect(step.status).toBe("warn");
    expect(step.problems.join("\n")).toMatch(/settle latency .* \(limit 20 ms; rAF timing, not a gate\)/);
  });
});

describe("gallery play waitFor", () => {
  // composer-row#fast-off waits for the pick its click posts to the native handler: a plain array,
  // not the DOM. The wait re-checked only on a DOM mutation, so it held or ran out its 5000 ms by
  // whether some unrelated mutation landed after the pick (gallery health, 2026-10-21).
  test("sees a condition that turns true without touching the DOM", async () => {
    const restore = ["requestAnimationFrame", "cancelAnimationFrame", "MutationObserver", "PerformanceObserver"].map(
      (key) => [key, key in scope, scope[key]] as const,
    );
    Object.assign(scope, {
      MutationObserver: dom.window.MutationObserver,
      requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
      cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
      PerformanceObserver: class {
        static supportedEntryTypes = [];
        observe() {}
        takeRecords() {
          return [];
        }
        disconnect() {}
      },
    });
    try {
      let posted = false;
      setTimeout(() => {
        posted = true;
      }, 50);
      const report = await runPlay((ctx) => ctx.waitFor(() => posted, { capMs: 1000 }), {});
      expect(report.error).toBeUndefined();
      expect(report.status).not.toBe("fail");
    } finally {
      for (const [key, had, value] of restore) {
        if (had) scope[key] = value;
        else delete scope[key];
      }
    }
  });
});
