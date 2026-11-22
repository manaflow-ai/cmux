// A text field's placeholder over glass. .ui-input (ui/controls.css: Settings' search, and every page
// field built on Input) draws its placeholder in the tertiary tier (--ds-color-faint). Over a
// see-through window the field is clear glass over art or the desktop, and that ink fell to 1.44:1 on
// the Great Wave in dark (2.97:1 in light) while the typed text held 5.41:1 (fleet capture of
// d65e0292, text-inputs-glass/states.py, Settings search, art). There the placeholder takes the
// secondary tier, as pageBase.css lifts tertiary text over a see-through window and as the chat
// composer's placeholder does (composerStates.css); an opaque window takes it too (below).
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
  // The base rule gives it; no see-through rule may put the tertiary tier back.
  const seeThrough = rule(
    (selector) => selector.includes("[data-cmux-see-through]") && selector.includes(".ui-input::placeholder"),
  );
  expect(seeThrough === undefined || /--cmux-text-secondary/.test(seeThrough)).toBe(true);
  expect(rule((selector) => selector === ".ui-input::placeholder")!).toMatch(/color\s*:\s*var\(--cmux-text-secondary/);
});

// Over an opaque window the tertiary tier held 3.52:1 in light and 3.94:1 in dark on the filled field
// (Settings search, default window; fleet capture of b409aec1, text-inputs-glass/states.py,
// settings-plain). A placeholder names what the field takes, so it reads at 4.5:1: the secondary tier
// on every window, as the chat composer's placeholder does.
test("an opaque window's field placeholder takes the secondary tier too", () => {
  const body = rule((selector) => selector === ".ui-input::placeholder");
  expect(body).toBeDefined();
  expect(body!).toMatch(/color\s*:\s*var\(--cmux-text-secondary/);
});

// The placeholder lift alone left Settings search at 2.35:1 on the Great Wave in dark (fleet capture
// of be805d96): the filled field is a faint hover tint over the art. Over a see-through window it
// lays the composer's surface (its solid colour at the chrome glass tint, composerStates.css) under
// that tint, the fill the Chief composer's field takes there too (HomeThemePalette).
test("over a see-through window a filled field lays the composer's surface under its tint", () => {
  const body = rule(
    (selector) => selector.includes("[data-cmux-see-through]") && selector.includes('.ui-input[data-variant="filled"]'),
  );
  expect(body).toBeDefined();
  expect(body!).toMatch(/background\s*:[^;]*var\(--ds-color-hover\)[^;]*var\(--ui-input-glass-underlay\)/);
});

test("Reduce Transparency keeps the plain filled field", () => {
  const selector = /(:root\[data-cmux-see-through\][^{]*)\.ui-input\[data-variant="filled"\]\s*\{/.exec(css)?.[1] ?? "";
  expect(selector).toContain("data-reduce-transparency");
});

// Settings' refined look draws its fields with a background of its own (look.css), later in the cascade,
// so the filled field's surface above never reached Settings search: its placeholder stayed at 2.35:1 on
// the Great Wave in dark (fleet capture of b409aec1, settings-art). The surface is one token on a
// see-through root, and every filled field lays its own tint over it, the refined one too.
const lookCss = fs
  .readFileSync(path.resolve(import.meta.dir, "../src/pages/settings/look.css"), "utf8")
  .replace(/\/\*[\s\S]*?\*\//g, "");

test("over a see-through window the composer's surface is one token", () => {
  const body = rule(
    (selector) =>
      selector.includes("[data-cmux-see-through]") &&
      selector.includes("data-reduce-transparency") &&
      !selector.includes(".ui-input"),
  );
  expect(body).toBeDefined();
  expect(body!).toMatch(/--ui-input-glass-underlay\s*:[^;]*var\(--ds-glass-chrome-tint/);
});

test("Settings' refined field lays its fill over the see-through surface", () => {
  const match = /\[data-settings-look="refined"\] \.settings \.ui-input\[data-variant="filled"\]\s*\{([^}]*)\}/.exec(
    lookCss,
  );
  expect(match).not.toBeNull();
  expect(match![1]).toMatch(/background\s*:[^;]*var\(--look-control-fill\)[^;]*var\(--ui-input-glass-underlay/);
});

// The surface at the chrome glass tint (62 %) left Settings search at 3.86:1 on the Great Wave in dark
// (fleet capture of 41d8c65e, settings-art): the dark art under it is bright, and a placeholder at the
// secondary tier needs a field no lighter than about 63/255. In dark the field's surface is at least
// 85 % opaque; light keeps the chrome tint (5.31:1 there).
test("in dark the field's see-through surface is dense enough for its placeholder", () => {
  const body = rule(
    (selector) =>
      selector.includes("[data-cmux-see-through]") &&
      selector.includes("data-reduce-transparency") &&
      !selector.includes(".ui-input"),
  )!;
  const value = /--ui-input-glass-underlay\s*:([^;]*)/.exec(body)![1];
  const dark = value.slice(value.lastIndexOf("color-mix(in srgb, color-mix("));
  const share = Number(/\)\s*(\d+)%\s*,\s*transparent\s*\)\s*\)\s*$/.exec(dark.trim())?.[1] ?? 0);
  expect(share).toBeGreaterThanOrEqual(85);
});
