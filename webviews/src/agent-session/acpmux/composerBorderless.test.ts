// The chat composer is borderless with a shadow, as the New Tab card (composerStates.css "BORDERLESS
// COMPOSER"): outside Increase Contrast the stack's outline goes (the card's ring and rim, the focus step,
// the strip's rim, the queue's sides, a joined tray's and banner's edge) and the card casts only the
// composer's depth. The edge colour itself stays, so borders inside the stack keep it.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const css = readFileSync(join(import.meta.dir, "composerStates.css"), "utf8");
const start = css.indexOf("/* BORDERLESS COMPOSER");
const media = css.indexOf("@media not (prefers-contrast: more) {", start);
const block = css.slice(start, css.indexOf("\n}\n", media) + 3);

function rule(selectorStart: string): string {
  const at = block.indexOf(selectorStart);
  expect(at).toBeGreaterThan(-1);
  return block.slice(at, block.indexOf("}", at));
}

test("the outline rules sit outside Increase Contrast", () => {
  expect(start).toBeGreaterThan(-1);
  expect(block.indexOf(":root .acpmux-dock .acpmux-composer:not([data-shell]) > .acpmux-composer-box")).toBeGreaterThan(
    block.indexOf("@media not (prefers-contrast: more) {"),
  );
});

test("the card drops its ring and rim and casts the composer's depth only", () => {
  const card = rule(":root .acpmux-dock .acpmux-composer:not([data-shell]) > .acpmux-composer-box");
  expect(card).toContain("--acpmux-card-ring: 0 0 transparent;");
  expect(card).toContain("--acpmux-composer-rim: 0 0 transparent;");
  expect(card).toContain("box-shadow: var(--acpmux-composer-shadow, var(--elevation-1));");
});

test("the focus step, the strip's rim and the queue's sides go", () => {
  expect(rule(":root .acpmux-dock .acpmux-composer.acpmux-composer:not([data-shell]) {")).toContain(
    "--acpmux-composer-edge-focus: transparent;",
  );
  expect(rule("> .acpmux-composer-strip.acpmux-composer-strip")).toContain("--acpmux-strip-edge: transparent;");
  expect(rule("> .acpmux-composer-queue.acpmux-composer-queue")).toContain("box-shadow: none;");
});

test("the edge colour stays on the dock, and a joined tray's rows get it back", () => {
  expect(block).not.toMatch(/\.acpmux-dock(\.acpmux-dock)+\s*\{[^}]*--acpmux-composer-edge: transparent/);
  expect(rule(":root .acpmux-dock {")).toContain("--acpmux-dock-edge: var(--acpmux-composer-edge);");
  expect(rule(":root .acpmux-dock > :is(.acpmux-running-tray[data-card], .acpmux-goal[data-look]) > *")).toContain(
    "--acpmux-composer-edge: var(--acpmux-dock-edge);",
  );
});

test("the dock's shadow is the New Tab card's depth, in every theme", () => {
  expect(rule(":root .acpmux-dock {")).toContain(
    "--acpmux-composer-shadow: var(--cmux-composer-shadow, var(--glass-material-depth-composer, var(--elevation-1)));",
  );
});
