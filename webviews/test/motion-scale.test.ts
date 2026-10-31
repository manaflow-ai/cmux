// One motion scale for every webview (Leo, 2026-10-20: "animations all around are a bit slow";
// schemas/motion-scale/motion-scale.json): a timed fade or move takes quick 80, micro 120,
// standard 180 or large 240 ms, or a `var(...)` of the scale. Loops of 600 ms or more (spinners,
// breathing, shimmer) and delays (hover intent) are not transitions. A line marked
// `motion-allow: <reason>` is exempt. The scanner is test/motion-scale.ts; it reads source, no
// browser.
import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { MOTION_EASE_OUT, MOTION_MS } from "../src/motion/scale.generated";
import { SCALE, SRC, scan, scanText } from "./motion-scale";

const finds = (file: string, text: string) => scanText(file, text).map((violation) => violation.line);

describe("motion scale", () => {
  test("no webview CSS, TS or TSX animates off the scale", () => {
    expect(scan().map((violation) => `${violation.file}:${violation.line} ${violation.text}`)).toEqual([]);
  });

  test("the generated TypeScript and CSS copies are the JSON's", () => {
    expect<[string, number][]>(Object.entries(MOTION_MS)).toEqual(
      SCALE.steps.map((step): [string, number] => [step.name, step.ms]),
    );
    expect(MOTION_EASE_OUT).toBe(`cubic-bezier(${SCALE.easeOut.join(", ")})`);
    const desktop = fs.readFileSync(path.join(SRC, "pages/shared/desktop.css"), "utf8");
    for (const step of SCALE.steps) expect(desktop).toContain(`--cmux-motion-${step.name}: ${step.ms}ms;`);
    expect(desktop).toContain(`--cmux-ease-out: cubic-bezier(${SCALE.easeOut.join(", ")});`);
  });

  // What the scan caught on the base before the scale (feat-cmux-next, 2026-10-20).
  test("off-scale CSS durations fail, whatever their unit or place", () => {
    expect(finds("a.css", ".a { transition: opacity 90ms ease-out; }")).toEqual([1]);
    expect(finds("a.css", ".a {\n  transition:\n    opacity 90ms ease,\n    translate 90ms ease;\n}")).toEqual([2, 2]);
    expect(finds("a.css", ".a { animation: lg-sheet-in 160ms cubic-bezier(0.2, 0.8, 0.2, 1); }")).toEqual([1]);
    expect(finds("a.css", ".a { transition: transform 0.15s; }")).toEqual([1]);
    expect(finds("a.css", ".a { transition-duration: 150ms; }")).toEqual([1]);
    expect(finds("a.css", ":root { --agent-motion-move: 190ms; --polish-duration: 140ms; }")).toEqual([1, 1]);
    // A var's literal fallback is the duration a page without the host gets.
    expect(finds("a.css", ".a { animation: swipe var(--agent-motion-move,190ms) ease-out both; }")).toEqual([1]);
    // A --cmux-motion-* must be a step, and its fallback that step.
    expect(finds("a.css", ":root { --motion-focus: var(--cmux-motion-focus, 100ms); }")).toEqual([1]);
    expect(finds("a.css", ":root { --motion-in: var(--cmux-motion-micro, 180ms); }")).toEqual([1]);
  });

  test("off-scale Tailwind classes and script durations fail", () => {
    expect(finds("a.tsx", 'const c = "transition-opacity duration-150 data-scrolling:duration-0";')).toEqual([1]);
    expect(finds("a.tsx", 'const c = "transition-[height] duration-220";')).toEqual([1]);
    expect(finds("a.ts", "export const MONACO = `\n.x {\n  transition: opacity 0.4s;\n}\n`;")).toEqual([3]);
    expect(finds("a.tsx", "export const THOUGHT_FOLD_MS = 200;")).toEqual([1]);
    expect(finds("a.tsx", "export const FADE_MS = 160;")).toEqual([1]);
    expect(finds("a.ts", "const SHIFT_MS = 200;\nel.animate(frames, { duration: SHIFT_MS });")).toEqual([1, 2]);
    expect(finds("a.ts", "el.animate(frames, { duration: 250, easing: 'ease-out' });")).toEqual([1]);
    expect(finds("a.tsx", 'const style = { transition: "opacity 150ms ease" };')).toEqual([1]);
  });

  test("the scale, zero, vars, loops, delays and marked lines pass", () => {
    const pass = [
      ".a { transition: opacity 80ms, transform 120ms, height 180ms, width 240ms; }",
      ".a { transition: opacity 0s; animation-duration: 0.01ms !important; }",
      ".a { transition: opacity var(--cmux-motion-quick) var(--cmux-ease-out); }",
      ".a { transition: opacity var(--cmux-motion-micro, 120ms); }",
      ".a { transition: background-color var(--agent-motion-hover-out,0s) var(--agent-ease-out,ease-out); }",
      ".a { transition: transform var(--motion-in); }",
      // Loops and their periods.
      ".a { animation: cmux-spin var(--cmux-spinner-period, 900ms) linear infinite; }",
      ".a { animation: breathe 1.4s ease-out infinite alternate; animation-duration: 1.3s; }",
      // Delays: the second time of a shorthand, and the delay properties.
      ".a { transition: opacity 80ms ease 350ms; transition-delay: 350ms; animation-delay: -0.8s; }",
      ".a { transition: width 1s linear; } /* motion-allow: playback progress, not a transition */",
      "/* transition: opacity 150ms; a comment is no style */",
    ];
    for (const css of pass) expect(finds("a.css", css)).toEqual([]);
    expect(finds("a.tsx", 'const c = "duration-(--cmux-motion-micro) duration-0 duration-120";')).toEqual([]);
    expect(finds("a.ts", "const FADE_MS = MOTION_MS.micro;\nconst SCROLLING_HIDE_MS = 800;")).toEqual([]);
    expect(finds("a.ts", "el.animate(frames, { duration: 1200, iterations: Infinity });")).toEqual([]);
  });
});
