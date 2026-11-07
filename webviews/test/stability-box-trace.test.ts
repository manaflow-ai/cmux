// l10n-allow-file: diagnostic labels and synthetic browser data.
import { expect, test } from "bun:test";
import { installStabilityProbe } from "../bench/stability";

test("box diagnostics identify a moving row without changing settle timing and stop with the sampler", () => {
  const scope = globalThis as Record<string, unknown>;
  const keys = ["window", "document", "Element", "performance", "PerformanceObserver"];
  const saved = keys.map((key) => [key, Object.getOwnPropertyDescriptor(scope, key)] as const);
  const run = (traceBoxes: boolean) => {
    let now = 0;
    let callback: FrameRequestCallback | undefined;
    class Box {
      tagName = "DIV";
      id = "";
      className = "acpmux-row";
      y = 10;
      closest() {
        return this;
      }
      getAttribute() {
        return "reply-1";
      }
      getBoundingClientRect() {
        return { x: 0, y: this.y, width: 100, height: 24 };
      }
    }
    const box = new Box();
    const elements: Box[] = [box];
    const document = {
      body: { getElementsByTagName: () => elements },
      querySelector: () => box,
      fonts: { status: "loaded" },
      getAnimations: () => [],
    };
    const window = {
      requestAnimationFrame: (next: FrameRequestCallback) => {
        callback = next;
        return 1;
      },
      setTimeout: () => 1,
      setInterval: () => 1,
      __cmuxStability: undefined as Window["__cmuxStability"],
    };
    const replacements = {
      window,
      document,
      Element: Box,
      performance: { now: () => now },
      PerformanceObserver: class {
        observe() {}
      },
    };
    for (const [key, value] of Object.entries(replacements))
      Object.defineProperty(scope, key, { configurable: true, writable: true, value });
    installStabilityProbe({ sampleCap: 10, boxes: true, content: ".acpmux-row", traceBoxes });
    const frame = () => {
      now += 16;
      callback?.(now);
    };
    frame();
    box.y = 14;
    frame();
    box.y = 14.25; // Below the sampler's existing half-pixel tolerance.
    frame();
    const result = window.__cmuxStability!.settled();
    box.y = 80;
    frame();
    expect(window.__cmuxStability!.settled()).toEqual(result);
    return result;
  };
  try {
    const plain = run(false);
    const traced = run(true);
    expect(plain).toEqual({ lastChange: 32, firstContent: 16, frames: 3, actionStarts: [] });
    const { boxChanges, ...timing } = traced;
    expect(timing).toEqual(plain);
    expect(boxChanges).toHaveLength(2);
    expect(boxChanges?.[1]).toEqual({
      at: 32,
      fonts: "loaded",
      animations: [],
      changes: ["div.acpmux-row [row=reply-1] [0,10,100,24] -> [0,14,100,24]"],
    });
  } finally {
    for (const [key, descriptor] of saved) {
      if (descriptor) Object.defineProperty(scope, key, descriptor);
      else delete scope[key];
    }
  }
});
