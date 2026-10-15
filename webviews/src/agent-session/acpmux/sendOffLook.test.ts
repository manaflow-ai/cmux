// The off Send (an empty draft, or Send turned off while the folder's trust question is open) has one
// look, and its disc stays a visible step off the composer surface in light and dark themes: a 9%
// disc vanished on Latte's near-white field and into Mocha's composer fill.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const styles = readFileSync(join(import.meta.dir, "styles.css"), "utf8");
const states = readFileSync(join(import.meta.dir, "composerStates.css"), "utf8");

const percent = (name: string) => {
  const match = styles.match(new RegExp(`${name}:color-mix\\(in srgb,var\\(--agent-text\\) (\\d+)%,transparent\\)`));
  if (!match) throw new Error(`${name} is not a text mix`);
  return Number(match[1]);
};

/** The declarations of the rule whose selector list is exactly `selector`. */
const rule = (css: string, selector: string) => {
  const flat = css.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\s+/g, " ");
  const at = [`${selector} {`, `${selector}{`].map((head) => flat.indexOf(head)).find((index) => index >= 0);
  if (at === undefined) throw new Error(`no rule ${selector}`);
  const open = flat.indexOf("{", at);
  return flat.slice(open + 1, flat.indexOf("}", open)).trim();
};

test("the off disc is a visible step, never the faint 9% disc, and stays below a filled Send", () => {
  const disc = percent("--acpmux-send-off-bg");
  expect(disc).toBeGreaterThanOrEqual(14);
  expect(disc).toBeLessThanOrEqual(24);
  const arrow = percent("--acpmux-send-off-fg");
  expect(arrow).toBeGreaterThanOrEqual(50);
  expect(arrow).toBeLessThan(100);
  // The empty draft's hover step stays above the resting disc, so pointing at it still shows.
  const hover = rule(styles, ".acpmux-send:not(.acpmux-send-ready):not(.acpmux-cancel):hover");
  const step = hover.match(/background: ?color-mix\(in srgb, ?var\(--agent-text\) (\d+)%, ?transparent\)/);
  expect(step).not.toBeNull();
  expect(Number(step![1])).toBeGreaterThan(disc);
});

test("an empty draft's Send and Send turned off share one look", () => {
  const empty = rule(styles, ".acpmux-send:not(.acpmux-send-ready):not(.acpmux-cancel)");
  const off = rule(states, "button.acpmux-send:disabled:not(.acpmux-cancel):not(.acpmux-send-ready)");
  for (const declarations of [empty, off]) {
    expect(declarations).toMatch(/background: ?var\(--acpmux-send-off-bg\)/);
    expect(declarations).toMatch(/color: ?var\(--acpmux-send-off-fg\)/);
  }
});
