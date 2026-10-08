// The play checks' rules (src/gallery/play.ts): strict defaults, loosening only with a reason, and
// targets resolved by role and name, test id, text or selector. The measurement itself needs a real
// engine (layout, frames) and runs in the matrix runner, never in a local browser.
import { afterAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import {
  checkReasons,
  judgeStep,
  overall,
  rectDelta,
  resolveTarget,
  roleOf,
  accessibleName,
} from "../src/gallery/play";

const dom = new JSDOM(`<!doctype html><main>
  <button aria-label="Send prompt">↑</button>
  <button>Stop</button>
  <a href="#x">Open file</a>
  <input type="search" placeholder="Filter">
  <div role="menu"><div role="menuitem">Compact</div><div role="menuitem" data-testid="init">Init</div></div>
  <span id="l">Model</span><div role="combobox" aria-labelledby="l"></div>
</main>`);
const saved = (globalThis as Record<string, unknown>).CSS;
(globalThis as Record<string, unknown>).CSS = { escape: (value: string) => value };
afterAll(() => {
  (globalThis as Record<string, unknown>).CSS = saved;
  dom.window.close();
});
const doc = dom.window.document;

const step = (fields: Partial<Parameters<typeof judgeStep>[0]> = {}) => ({
  step: "click",
  anchorMoves: [],
  layoutShift: 0,
  shifts: [],
  longFrames: [],
  frameSource: "raf" as const,
  ...fields,
});

describe("gallery play checks", () => {
  test("strict defaults: any anchor movement, any layout shift and a frame over 33 ms fail", () => {
    expect(judgeStep(step()).status).toBe("pass");
    expect(judgeStep(step({ anchorMoves: [{ anchor: "header", before: null, after: null, delta: 0.5 }] })).status).toBe(
      "fail",
    );
    expect(judgeStep(step({ layoutShift: 0.001 })).status).toBe("fail");
    expect(judgeStep(step({ frameSource: "long-animation-frame", longFrames: [33.5] })).problems[0]).toContain(
      "over 33 ms",
    );
  });

  test("rAF-timed frames (software-rendered WebKit) never fail on time, they warn", () => {
    expect(judgeStep(step({ frameSource: "raf", longFrames: [806] }))).toEqual({ status: "warn", problems: [] });
    expect(judgeStep(step({ frameSource: "raf", layoutShift: 0.01 })).status).toBe("fail");
  });

  test("frames over 16.7 ms only warn", () => {
    const verdict = judgeStep(step({ longFrames: [20, 30] }));
    expect(verdict).toEqual({ status: "warn", problems: [] });
  });

  test("an entry loosens a check with a value and a written reason", () => {
    const checks = { longFrameFailMs: { value: 50, reason: "The first Shiki highlight compiles its grammar." } };
    expect(judgeStep(step({ frameSource: "long-animation-frame", longFrames: [40] }), checks).status).toBe("warn");
    expect(checkReasons(checks)).toEqual([]);
    expect(checkReasons({ anchorMovePx: { value: 2, reason: "" } })).toHaveLength(1);
  });

  test("a report is as bad as its worst step", () => {
    const pass = { ...step(), status: "pass" as const, problems: [] };
    expect(overall([])).toBe("none");
    expect(overall([pass, { ...pass, status: "warn" }])).toBe("warn");
    expect(overall([pass, { ...pass, status: "fail" }])).toBe("fail");
  });

  test("a box that appears, vanishes or moves is a delta", () => {
    const box = { x: 0, y: 0, width: 10, height: 10 };
    expect(rectDelta(box, { ...box })).toBe(0);
    expect(rectDelta(box, { ...box, y: 3 })).toBe(3);
    expect(rectDelta(box, null)).toBe(Number.POSITIVE_INFINITY);
    expect(rectDelta(null, null)).toBe(0);
  });

  test("targets resolve by role and name, test id, text and selector", () => {
    expect(resolveTarget(doc, { role: "button", name: "Send prompt" })?.textContent).toBe("↑");
    expect(resolveTarget(doc, { role: "button", name: /^St/ })?.textContent).toBe("Stop");
    expect(resolveTarget(doc, { role: "link", name: "Open file" })).not.toBeNull();
    expect(roleOf(doc.querySelector("input")!)).toBe("searchbox");
    expect(accessibleName(doc.querySelector("input")!)).toBe("Filter");
    expect(resolveTarget(doc, { role: "combobox", name: "Model" })).not.toBeNull();
    expect(resolveTarget(doc, { testId: "init" })?.textContent).toBe("Init");
    expect(resolveTarget(doc, { text: "Compact" })?.getAttribute("role")).toBe("menuitem");
    expect(resolveTarget(doc, { selector: "main > a" })).not.toBeNull();
    expect(resolveTarget(doc, { role: "dialog" })).toBeNull();
  });
});
