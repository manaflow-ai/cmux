import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { runPlay, selectTextWithDriver, syntheticKey } from "../src/gallery/frame/playRunner";
import { isSubpixelLayoutShift } from "../src/gallery/play";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "HTMLInputElement",
  "ShadowRoot",
  "KeyboardEvent",
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
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  });
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
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

describe("gallery layout-shift measurement", () => {
  test("ignores fractional rounding while retaining a half-pixel movement", () => {
    const rect = (x: number) => ({ x, y: 10, width: 100, height: 20 });
    expect(isSubpixelLayoutShift([{ previousRect: rect(10), currentRect: rect(10.49) }])).toBe(true);
    expect(isSubpixelLayoutShift([{ previousRect: rect(10), currentRect: rect(10.5) }])).toBe(false);
    expect(isSubpixelLayoutShift([{ previousRect: rect(10) }])).toBe(false);
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
