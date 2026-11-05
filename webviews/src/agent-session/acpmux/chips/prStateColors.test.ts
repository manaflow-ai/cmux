// A pull request's state draws in GitHub's colours on every surface that shows it (the transcript's
// reference chip, its hover card, the chat header, the summary's links): open green, merged
// purple, closed red, draft grey. Merged is GitHub's purple in every theme, never the theme's ANSI
// magenta, which some themes make pink or red (Leo 2026-11-02, of a merged pull request's chip:
// "this goes green then RED??? WHY NOT PURPLE????").
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const root = join(import.meta.dir, "..", "..", "..");
const sheet = (path: string) => readFileSync(join(root, path), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");

/** The value `name` is declared with in `css` (its first declaration). */
const token = (css: string, name: string) => new RegExp(`${name}:\\s*([^;]+);`).exec(css)?.[1]?.trim();

/** The declarations of the rule whose selector is exactly `selector`. */
const rule = (css: string, selector: string) => {
  const flat = css.replace(/\s+/g, " ");
  const at = flat.indexOf(`${selector} {`) >= 0 ? flat.indexOf(`${selector} {`) : flat.indexOf(`${selector}{`);
  if (at < 0) return undefined;
  const open = flat.indexOf("{", at);
  return flat
    .slice(open + 1, flat.indexOf("}", open))
    .trim()
    .replace(/;$/, "")
    .replace(/:\s*/, ": ");
};

const INK = {
  open: "var(--agent-status-success)",
  merged: "var(--agent-status-merged)",
  closed: "var(--agent-status-failure)",
  draft: "var(--agent-muted)",
} as const;

const SURFACES: readonly [string, (state: string) => string][] = [
  ["agent-session/acpmux/chips/chips.css", (s) => `.cv-chip.is-ref[data-pr-state="${s}"] .cv-chip__icon--gh`],
  ["agent-session/acpmux/chips/linkCard.css", (s) => `.acpmux-pr-card__glyph[data-state=${s}]`],
  ["agent-session/acpmux/header/header.css", (s) => `.acpmux-header-pr[data-state=${s}]>svg`],
  ["agent-session/acpmux/summary/summary.css", (s) => `.acpmux-summary-link[data-state=${s}]>svg`],
  ["pages/github/styles.css", (s) => `.gh-glyph[data-state=${s}]`],
];

test("merged is GitHub's purple in every theme, never the theme's ANSI magenta", () => {
  for (const path of ["agent-session/shared/styles.css", "pages/changelog/styles.css", "pages/github/styles.css"]) {
    const merged = token(sheet(path), "--agent-status-merged");
    expect(merged).toBe("light-dark(#8250df, #a371f7)");
  }
});

test("every pull request surface draws open green, merged purple, closed red, draft grey", () => {
  for (const [path, selector] of SURFACES) {
    const css = sheet(path);
    for (const [state, ink] of Object.entries(INK)) {
      expect({ path, state, rule: rule(css, selector(state)) }).toEqual({ path, state, rule: `color: ${ink}` });
    }
  }
});
