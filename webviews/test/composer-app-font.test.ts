// The composer and its model button draw in the app's UI font (Leo 2026-10-21: "WE ALREADY FIXED THE
// FONTS"). The composer names it once, `.acpmux-composer { font-family: system-ui }` in styles.css
// (SF Pro in the app's WebKit); every control in it inherits that family, so no rule in the
// composer's stylesheets may name another one, and the quiet row under the box (ComposerFoot), which
// sits outside `.acpmux-composer-box`, must inherit it too. test/composer-model-quiet.test.ts checks
// the computed family of the model button, its labels and the mode in Chromium.
//
// A capture made where the UI font is missing (headless Linux Chromium has no SF Pro and falls back to
// Liberation Sans, as #23742's after-shot did) shows a fallback no rule here causes: capture type on
// macOS.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";

const DIR = path.resolve(import.meta.dir, "../src/agent-session/acpmux");
const SHEETS = [
  "styles.css",
  "composerLocation.css",
  "composerControls.css",
  "composerFooterShared.css",
  "composerStates.css",
  "modelPicker.css",
  "dictation.css",
];
/** A selector that styles the composer or a control in it. */
const COMPOSER =
  /acpmux-composer|acpmux-picker-button|acpmux-model|acpmux-chips|acpmux-access|acpmux-context-ring|nt-pickers/;
const APP_FONT = "system-ui";

function rules(file: string): { selector: string; body: string }[] {
  const css = readFileSync(path.join(DIR, file), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
  return [...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)].map(([, selector = "", body = ""]) => ({
    selector: selector.trim().replace(/\s+/g, " "),
    body,
  }));
}

test("the composer names the app's UI font once", () => {
  const composer = rules("styles.css").filter(({ selector }) => selector === ".acpmux-composer");
  const families = composer.flatMap(({ body }) =>
    [...body.matchAll(/font-family\s*:\s*([^;]+)/g)].map((m) => m[1]!.trim()),
  );
  expect(families).toEqual([APP_FONT]);
});

test("no composer rule names another font family", () => {
  const found: string[] = [];
  for (const file of SHEETS)
    for (const { selector, body } of rules(file)) {
      if (!COMPOSER.test(selector) || selector === ".acpmux-composer") continue;
      for (const [declaration, family = ""] of body.matchAll(/(?<![\w-])font(?:-family)?\s*:\s*([^;]+)/g)) {
        const value = family.trim();
        // `font: inherit` / `font-family: inherit` keep the composer's; a size-only shorthand is not a family.
        if (value === "inherit" || value === APP_FONT) continue;
        found.push(`${file}: ${selector} { ${declaration.trim()} }`);
      }
    }
  expect(found).toEqual([]);
});

test("the quiet row's buttons inherit the composer's family, as the box's do", () => {
  const inherits = rules("composerLocation.css").some(
    ({ selector, body }) =>
      selector.split(",").some((part) => part.trim() === ".acpmux-composer-foot button") &&
      /font(?:-family)?\s*:\s*inherit/.test(body),
  );
  expect(inherits).toBe(true);
  const box = rules("styles.css").some(
    ({ selector, body }) => selector === ".acpmux-composer-box button" && /font\s*:\s*inherit/.test(body),
  );
  expect(box).toBe(true);
});
