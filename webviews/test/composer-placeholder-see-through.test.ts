// The composer's placeholder over glass. On an opaque window it keeps the Codex-style light ink
// (--acpmux-composer-placeholder, the text at 34% over the page: 2.4:1 on white). Over a see-through
// window the field is clear glass over art or the desktop, and that ink fell to 1.8:1 on the Great Wave
// (fleet capture of 6015e301, text-inputs-glass/states.py, agent chat composer, art light and dark).
// There it takes the secondary tier (--acpmux-composer-dim), as pageBase.css lifts tertiary text over
// a see-through window, and as the native Chief composer's placeholder holds 4.5:1 on its field
// (FixtureTheme.swift, user 2026-10-19).
import { expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";

const SRC = path.resolve(import.meta.dir, "../src/agent-session/acpmux");
const css = ["styles.css", "composerStates.css"]
  .map((name) => fs.readFileSync(path.join(SRC, name), "utf8"))
  .join("\n");

/** The declarations of every rule whose selector list contains `selector` text. */
function rules(predicate: (selector: string) => boolean): string[] {
  const found: string[] = [];
  for (const match of css.replace(/\/\*[\s\S]*?\*\//g, "").matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    if (predicate(match[1].trim())) found.push(match[2]);
  }
  return found;
}

function luminance(grey: number): number {
  const v = grey / 255;
  const linear = v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
  return linear;
}

function contrast(a: number, b: number): number {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

test("over a see-through window the placeholder takes the composer's secondary tier", () => {
  const seeThrough = rules((selector) => selector.includes("[data-cmux-see-through]"));
  const placeholder = seeThrough.flatMap((body) =>
    [...body.matchAll(/--acpmux-composer-placeholder\s*:\s*([^;]+)/g)].map((m) => m[1].trim()),
  );
  expect(placeholder).toContain("var(--acpmux-composer-dim)");
});

test("the secondary tier reads 4.5:1 on the plain field in a light and a dark theme", () => {
  const dim = /--acpmux-composer-dim:[^;]*color-mix\(in srgb,var\(--agent-text\) (\d+)%,var\(--acpmux-base\)\)/.exec(
    css,
  );
  expect(dim).not.toBeNull();
  const share = Number(dim![1]) / 100;
  // Light: black text over a white base; dark: white text over the default dark page (#1e1e1e).
  const light = Math.round(255 * (1 - share));
  const dark = Math.round(30 + (255 - 30) * share);
  expect(contrast(light, 255)).toBeGreaterThanOrEqual(4.5);
  expect(contrast(dark, 30)).toBeGreaterThanOrEqual(4.5);
});
