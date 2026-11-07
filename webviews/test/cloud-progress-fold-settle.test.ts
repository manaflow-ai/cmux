// The Cloud progress page's steps fold under its status line as one motion on the settle (Leo,
// 2026-11-07: "they dont overshoot but they decelerate at the end. i think that might be the key"):
// Base UI's panel moves its height (--collapsible-panel-height) with its opacity over
// --cmux-motion-settle on --cmux-ease-settle, keeps the steps drawn until the close ends, and under
// Reduce Motion or with the page's motion off the panel has no transition: one frame.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";

const css = readFileSync(path.resolve(import.meta.dir, "../src/pages/cloud-progress/styles.css"), "utf8");
const panel = String.raw`\.cloud-progress__disclosure \.ui-disclosure-panel`;

test("the steps' panel follows its measured height and folds from and to nothing", () => {
  expect(css).toMatch(
    new RegExp(String.raw`${panel}\s*\{[^}]*height:\s*var\(--collapsible-panel-height\);[^}]*overflow:\s*clip`),
  );
  expect(css).toMatch(
    new RegExp(
      String.raw`${panel}:is\(\[data-starting-style\], \[data-ending-style\]\)\s*\{\s*height:\s*0;\s*opacity:\s*0;`,
    ),
  );
});

test("the fold rides the settle, only with motion on", () => {
  const block = css.slice(css.indexOf("@media (prefers-reduced-motion: no-preference)"));
  expect(block.length).toBeLessThan(css.length);
  expect(block).toMatch(
    /:root:not\(\[data-cmux-motion="off"\], \[data-cmux-motion="reduced"\], \[data-agent-motion="off"\], \[data-agent-motion="reduced"\]\)\s*\.cloud-progress__disclosure\s*\.ui-disclosure-panel\s*\{\s*transition:\s*height var\(--cmux-motion-settle, 265ms\) var\(--cmux-ease-settle, cubic-bezier\(0\.16, 1, 0\.3, 1\)\),\s*opacity var\(--cmux-motion-settle, 265ms\) var\(--cmux-ease-settle/,
  );
  // Outside that guard the panel has no transition: Reduce Motion is one frame.
  const outside = css.slice(0, css.indexOf("@media (prefers-reduced-motion: no-preference)"));
  expect(outside).not.toMatch(new RegExp(String.raw`${panel}[^{]*\{[^}]*transition`));
});
