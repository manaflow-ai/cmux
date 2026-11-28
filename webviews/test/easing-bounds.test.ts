// No bounce in any motion (Lawrence; plans/cmux-next/motion.md: "a tab, row or pane never passes its
// target"). For a webview this means: no easing may go past its end (1) and come back, or dip under
// its start (0) before it leaves. This test samples every easing the
// webviews declare (the scanner is test/easing-bounds.ts: CSS files, strings in scripts, curves
// written as numbers) and the curves that are code (the thread rail's grow-in table, the script
// springs), and fails when a sample is more than 1e-6 of the travel outside 0...1. It reads source
// and samples curves; it starts no browser.
import { describe, expect, test } from "bun:test";
import { MOTION_SPRINGS, springCurve, springStepResponse } from "../src/files-panel-motion";
import { WAVE_IN_MS, waveAmplitude } from "../src/agent-session/acpmux/threadMinimap/model";
import { MOTION_EASE_OUT, MOTION_SETTLE, MOTION_SPRING } from "../src/motion/scale.generated";
import {
  BOUND_TOLERANCE,
  KEYWORD_EASINGS,
  SAMPLES,
  describeOutOfBounds,
  easingFunctions,
  rangeOf,
  scanEasings,
  scanUnreadCss,
  scriptEasings,
  unreadEasingFunctions,
  withinBounds,
} from "./easing-bounds";
import { SCALE } from "./motion-scale";

// One read of the tree for the tests below (about two seconds of parsing).
let scanned: ReturnType<typeof scanEasings> | undefined;
const allEasings = () => (scanned ??= scanEasings());
const SCAN_TIMEOUT_MS = 60_000;

// Overshoots Leo asked for by name, against the house rule above. Each is one curve (the file and how far
// it goes), so a new bounce in the same file still fails. The motion scale's sendPop says the same:
// "It overshoots and outlasts the large step on Leo's word".
const ON_LEOS_WORD: readonly { file: RegExp; high: number; why: string }[] = [
  {
    file: /^(agent-session\/acpmux\/(composerStates\.css|conversation\/(conversation\.css|SendPop\.gallery\.tsx)|sendRise\.gallery\.ts)|motion\/scale\.generated\.ts|pages\/shared\/desktop\.css)$/,
    high: 1.0299,
    why: 'the sent prompt\'s pop, cubic-bezier(.34, 1.3, .64, 1) (Leo 2026-11-22: "it does a little pop and settle")',
  },
  {
    file: /^agent-session\/acpmux\/conversation\/conversation\.css$/,
    high: 1.04,
    why: 'the send pop\'s spring variant (data-send-pop="spring"), the pop above as a spring',
  },
  {
    file: /^agent-session\/acpmux\/newChatEntrance\.ts$/,
    high: 1.0022,
    why: "the new chat's entrance spring, the iOS new chat's (damping 0.82), within 2% of its end",
  },
  {
    file: /^agent-session\/acpmux\/newChatEntrance\.ts$/,
    high: 1.01,
    why: "the new chat's entrance spring (SwiftUI .spring(response: 0.42, dampingFraction: 0.82)): passes its end by 1% at most",
  },
  {
    file: /^agent-session\/acpmux\/subagents\/hatHeader\.css$/,
    high: 1.066,
    why: "the composer hat deck's mark pop (Leo 2026-11-20: \"there's a slight pop\")",
  },
];
const onLeosWord = (easing: { file: string; samples: readonly number[] }) => {
  const { high } = rangeOf(easing.samples as number[]);
  return ON_LEOS_WORD.some((allowed) => allowed.file.test(easing.file) && Math.abs(allowed.high - high) < 5e-4);
};

const outOfBounds = (css: string) => easingFunctions(css).filter((easing) => !withinBounds(easing.samples));

describe("no easing passes its end", () => {
  test(
    "every easing the webviews declare stays between its start and its end",
    () => {
      // Each line names a curve that bounces: file:line, the curve, its lowest and highest value.
      expect(describeOutOfBounds(allEasings().filter((easing) => !onLeosWord(easing)))).toEqual([]);
      // And no CSS easing is written so that this test cannot sample it.
      expect(scanUnreadCss()).toEqual([]);
    },
    SCAN_TIMEOUT_MS,
  );

  test("the thread rail's grow-in never passes full size", () => {
    const samples: number[] = [];
    for (let index = 0; index <= SAMPLES; index += 1) samples.push(waveAmplitude((WAVE_IN_MS * 1.5 * index) / SAMPLES));
    const { low, high } = rangeOf(samples);
    expect(high).toBeLessThanOrEqual(1 + BOUND_TOLERANCE);
    expect(low).toBeGreaterThanOrEqual(-BOUND_TOLERANCE);
    // It still starts at rest and ends at full size.
    expect(waveAmplitude(0)).toBe(0);
    expect(waveAmplitude(WAVE_IN_MS)).toBe(1);
  });

  test("the house spring's stops never pass its end", () => {
    // schemas/motion-scale/motion-scale.json: the source of --cmux-ease-spring and MOTION_SPRING.
    for (const [value, at] of SCALE.spring.points) {
      expect({ at, over: value > 1 + BOUND_TOLERANCE, under: value < -BOUND_TOLERANCE }).toEqual({
        at,
        over: false,
        under: false,
      });
    }
  });

  test("the script springs never pass their end, from rest", () => {
    for (const [name, spring] of Object.entries(MOTION_SPRINGS)) {
      const samples: number[] = [];
      // Two seconds: far past the visible end of the longest one.
      for (let index = 0; index <= SAMPLES; index += 1) samples.push(springStepResponse(spring, (2 * index) / SAMPLES));
      expect({ name, ...rangeOf(samples), within: withinBounds(samples) }).toMatchObject({ name, within: true });
      // The keyframes a slide plays (sampled from the spring).
      expect({ name, within: withinBounds(springCurve(spring).progress) }).toEqual({ name, within: true });
    }
  });

  test("the CSS easing keywords stay between start and end", () => {
    for (const [keyword, samples] of Object.entries(KEYWORD_EASINGS))
      expect({ keyword, within: withinBounds(samples) }).toEqual({ keyword, within: true });
  });
});

// The scan must find what is there: a scan that reads nothing would pass the test above.
describe("the easing scan", () => {
  test(
    "finds the house curves where they are declared",
    () => {
      const easings = allEasings();
      const at = (file: string, text: string) =>
        easings.filter((easing) => easing.file === file && easing.text === text);
      expect(at("motion/scale.generated.ts", MOTION_SPRING).length).toBe(1);
      expect(at("motion/scale.generated.ts", MOTION_EASE_OUT).length).toBe(1);
      expect(at("pages/shared/desktop.css", MOTION_SPRING).length).toBeGreaterThanOrEqual(1);
      expect(at("pages/shared/desktop.css", MOTION_SETTLE).length).toBeGreaterThanOrEqual(1);
      // A curve written as numbers, and one handed to a scroll.
      expect(at("agent-session/acpmux/threadMinimap/model.ts", "cubic-bezier as numbers [0.3, 0.2, 0, 1]").length).toBe(
        1,
      );
      expect(at("motion/scale.generated.ts", "cubic-bezier as numbers [0.16, 1, 0.3, 1]").length).toBe(1);
      // Every sampled easing has its samples, start to end.
      expect(easings.length).toBeGreaterThan(50);
      for (const easing of easings) expect(easing.samples.length).toBeGreaterThan(1000);
    },
    SCAN_TIMEOUT_MS,
  );

  test("a curve that passes its end, or dips under its start, is out of bounds", () => {
    // A control point over 1: the curve goes past its end and comes back.
    expect(outOfBounds(".a { transition: transform 180ms cubic-bezier(0.3, 1.2, 0.6, 1); }").length).toBe(1); // motion-allow: scanner fixture, a raw literal
    // A control point under 0: it backs up before it leaves.
    expect(outOfBounds(".a { transition: transform 180ms cubic-bezier(0.3, -0.2, 0.6, 1); }").length).toBe(1); // motion-allow: scanner fixture, a raw literal
    // A linear() easing with a stop over 1, however little, and one under 0.
    expect(outOfBounds(":root { --ease: linear(0, 0.9 40%, 1.001 60%, 1); }").length).toBe(1);
    expect(outOfBounds(":root { --ease: linear(0, -0.02 10%, 0.9 60%, 1); }").length).toBe(1);
    // Two layers of one declaration: both are read, the one that bounces is found.
    const layers = easingFunctions(
      ".a {\n  transition:\n    opacity 80ms cubic-bezier(0, 0, 0.58, 1),\n    scale 80ms cubic-bezier(0.34, 1.56, 0.64, 1);\n}", // motion-allow: scanner fixture, a raw literal
    );
    expect(layers.map((easing) => [easing.line, withinBounds(easing.samples)])).toEqual([
      [3, true],
      [4, false],
    ]);
  });

  test("curves that only rise are in bounds, and what is no easing is not read", () => {
    expect(outOfBounds(".a { transition: transform 180ms cubic-bezier(0.16, 1, 0.3, 1); }")).toEqual([]); // motion-allow: scanner fixture, a raw literal
    expect(outOfBounds(":root { --ease: linear(0, 0.5 20%, 0.9 50%, 0.99 80%, 1); }")).toEqual([]);
    // Even stops with no percentages, as CSS spaces them.
    expect(easingFunctions(":root { --ease: linear(0, 0.25, 1); }")[0]!.samples.at(SAMPLES / 2)).toBeCloseTo(0.25, 6);
    // A gradient, a script call and a cubic-bezier with no numbers are not easings.
    expect(easingFunctions(".a { background: linear-gradient(90deg, red 0%, blue 100%); }")).toEqual([]);
    expect(easingFunctions("0.2126 * linear(r) + 0.7152 * linear(g)")).toEqual([]);
    expect(easingFunctions("cubic-bezier(x1, y1, x2, y2)")).toEqual([]);
    // In CSS, an easing function that cannot be sampled is reported, with its line.
    // motion-allow: scanner fixture, a raw literal
    expect(unreadEasingFunctions(".a {\n  transition: scale 80ms cubic-bezier(0.3, var(--pop), 0.6, 1);\n}")).toEqual([
      "2 cubic-bezier(0.3, var(--pop), 0.6, 1);",
    ]);
    // motion-allow: scanner fixture, a raw literal
    expect(unreadEasingFunctions(".a { transition: scale 80ms cubic-bezier(0.3, 1, 0.6, 1), top 1s linear; }")).toEqual(
      [],
    );
  });

  test("a script's strings and number curves are read; names that only hold `ease` are not", () => {
    const found = scriptEasings(
      "a.ts",
      [
        'export const POP = "cubic-bezier(0.34, 1.4, 0.64, 1)";',
        "export const STEP_CURVE = [0.3, 1.3, 0, 1] as const;",
        "glide(node, `transform 120ms linear(0, 1.02 50%, 1)`);", // motion-allow: scanner fixture, a raw literal
        "animateScrollBy(node, 10, 120, [0.2, -0.1, 0.4, 1]);",
        "const released = [0.5, 3, 0.5, 4];",
        "// cubic-bezier(0.34, 1.9, 0.64, 1) in a comment is no easing",
      ].join("\n"),
    );
    expect(found.map((easing) => [easing.line, withinBounds(easing.samples)])).toEqual([
      [1, false],
      [2, false],
      [3, false],
      [4, false],
    ]);
  });
});
