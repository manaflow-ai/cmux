// The quiet row's hover pill is the native selection pill's size (Leo 2026-10-22: "the highlight
// pill is too small"). Under the composer box (ComposerFoot.tsx, `.acpmux-composer-foot`) the mode,
// Plan and the model are text chips; each one's hover, open and press pill (the bar's states in
// composerLocation.css) is padded by the row's --acpmux-row-inset. At 4 px the pill hugged the
// label like a sliver; it is 8 px, the inset of an NSMenu row's highlight and of Codex's and
// ChatGPT's mode chip. The row spans the box without extra side padding (#24216), and neighbouring
// chips tuck the extra padding under each other: only the pill grows.
// test/composer-row-rhythm.test.ts measures the drawn row in Chromium.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const css = readFileSync(join(import.meta.dir, "../src/agent-session/acpmux/composerLocation.css"), "utf8").replace(
  /\/\*[\s\S]*?\*\//g,
  "",
);
const baseStyles = readFileSync(join(import.meta.dir, "../src/agent-session/acpmux/styles.css"), "utf8");

/** The declarations of every rule whose selector is exactly `selector`, in source order. */
function rules(selector: string): string[] {
  const found: string[] = [];
  for (const [, sel = "", body = ""] of css.matchAll(/([^{}]+)\{([^{}]*)\}/g))
    if (sel.trim().replace(/\s+/g, " ") === selector) found.push(body);
  return found;
}

function px(body: string, property: string): number | undefined {
  const match = body.match(new RegExp(`(?:^|;|\\s)${property}\\s*:\\s*(-?[\\d.]+)px`));
  return match ? Number(match[1]) : undefined;
}

test("the quiet row's chips get the native pill inset, 8 px from the text", () => {
  const foot = rules(".acpmux-composer-foot");
  expect(foot.length).toBeGreaterThan(0);
  // The last declaration wins, as in the cascade.
  const insets = foot.map((body) => px(body, "--acpmux-row-inset")).filter((value) => value !== undefined);
  expect(insets[insets.length - 1]).toBe(8);
});

test("each chip's pill is padded by the row's inset", () => {
  const chip = rules(".acpmux-composer-bar .acpmux-chips .acpmux-picker-button").join(";");
  expect(chip).toMatch(/padding-inline\s*:\s*var\(--acpmux-row-inset\)/);
});

test("the quiet row spans the box without adding side padding", () => {
  const foot = rules(".acpmux-composer-foot").join(";");
  expect(foot).toMatch(/padding-inline\s*:\s*0\s*;/);
  // Chips touch (no gap of their own), so neighbouring pills never overlap.
  expect(px(foot, "--acpmux-row-gap")).toBe(0);
});

test("neighbouring chips on the right keep their labels 8 px apart, as with the old 4 px inset", () => {
  // The model, Plan and a harness's Options sit side by side with no gap. Each one after the first
  // tucks its leading padding under the one before it: two insets of 8 px less the 8 px the labels
  // were apart. Without it the model's label moves 8 px per neighbour.
  const neighbour = rules(".acpmux-composer-foot .acpmux-chips > :not(.acpmux-access) ~ :not(.acpmux-access)").join(
    ";",
  );
  expect(neighbour).toMatch(/margin-inline-start\s*:\s*calc\(8px - 2 \* var\(--acpmux-row-inset\)\)/);
  // The effort chip kept 1 px more (its own margin) and still does.
  const effort = rules(".acpmux-composer-foot .acpmux-chips > :not(.acpmux-access) ~ .acpmux-effort").join(";");
  expect(effort).toMatch(/margin-inline-start\s*:\s*calc\(9px - 2 \* var\(--acpmux-row-inset\)\)/);
  expect(px(rules(".acpmux-composer-foot .acpmux-effort").join(";"), "margin-inline-start")).toBe(1);
});

test("the context ring keeps its place past the model's text", () => {
  const ring = rules(".acpmux-composer-foot .acpmux-context-ring").join(";");
  expect(ring).toMatch(/margin-inline-start\s*:\s*4px/);
});

test("the context ring stays compact, with a scale-aligned quiet row control", () => {
  expect(baseStyles).toMatch(/\.acpmux-context-ring\{[^}]*width:22px;height:22px/);
  const ring = rules(".acpmux-composer-foot .acpmux-context-ring").join(";");
  expect(ring).toMatch(/width\s*:\s*24px/);
  expect(ring).toMatch(/height\s*:\s*24px/);
});
