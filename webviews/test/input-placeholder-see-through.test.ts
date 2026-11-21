// A text field's placeholder over glass. .ui-input (ui/controls.css: Settings' search, and every page
// field built on Input) draws its placeholder in the tertiary tier (--ds-color-faint). Over a
// see-through window the field is clear glass over art or the desktop, and that ink fell to 1.44:1 on
// the Great Wave in dark (2.97:1 in light) while the typed text held 5.41:1 (fleet capture of
// d65e0292, text-inputs-glass/states.py, Settings search, art). There the placeholder takes the
// secondary tier, as pageBase.css lifts tertiary text over a see-through window and as the chat
// composer's placeholder does (composerStates.css). An opaque window keeps the tertiary tier.
import { expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";

const css = fs
  .readFileSync(path.resolve(import.meta.dir, "../src/ui/controls.css"), "utf8")
  .replace(/\/\*[\s\S]*?\*\//g, "");

function rule(predicate: (selector: string) => boolean): string | undefined {
  for (const match of css.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    if (predicate(match[1].trim())) return match[2];
  }
  return undefined;
}

test("over a see-through window a field's placeholder takes the secondary tier", () => {
  const body = rule(
    (selector) => selector.includes("[data-cmux-see-through]") && selector.includes(".ui-input::placeholder"),
  );
  expect(body).toBeDefined();
  expect(body!).toMatch(/color\s*:\s*var\(--cmux-text-secondary/);
});

test("an opaque window keeps the tertiary placeholder", () => {
  const body = rule((selector) => selector === ".ui-input::placeholder");
  expect(body).toBeDefined();
  expect(body!).toMatch(/color\s*:\s*var\(--ds-color-faint\)/);
});
