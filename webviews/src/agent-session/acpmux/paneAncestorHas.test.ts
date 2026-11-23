// The pane's columns never carry a `:has()` that styles something under them. Chromium keeps one
// invalidation set for every `:has()` in a non-subject position (`X:has(...) Y`) in the stylesheet,
// the union of all their `Y`s. Once one such rule marks `.acpmux-main` (the column that holds both
// the transcript and the composer), each composer edit and many transcript changes restyle every
// element under it that matches any of those `Y`s: every drawn row's buttons, icons and bubbles.
// Three such rules made a send in a 1,000-turn chat restyle about 5x the elements (traced style time
// 122 ms to 25 ms over the 250 ms after Return) and a composer menu open 1,248 elements instead of
// 333 (pane-has-restyle.browser.test.ts). State attributes on the pane (`data-asks`,
// `data-home-lists`, `data-stage-loading`, pane/PaneBody.tsx) carry those states instead, or a sibling
// combinator finds the small element (`.acpmux-main > .nt-style ~ ...`).
import { expect, test } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const SRC = join(import.meta.dir, "..", "..");
/// The columns whose subtree holds the transcript and the composer.
const PANE = /(^|[^\w-])\.acpmux-(main|shell)(?![\w-])/;
/// Known and not yet moved: the background tasks panel's placement beside the artifact panel, on
/// the shell, only while that panel is open. Each entry is file and selector; a new one fails.
const KNOWN = new Set([
  "agent-session/acpmux/backgroundTasks/backgroundTasks.css .acpmux-shell:has(> .acpmux-artifact) > .acpmux-bg",
  "agent-session/acpmux/backgroundTasks/backgroundTasks.css .acpmux-shell:has(> .acpmux-bg) > .acpmux-artifact",
  "agent-session/acpmux/backgroundTasks/backgroundTasks.css .acpmux-shell:has(> .acpmux-artifact) > .acpmux-bg[data-expanded]",
]);

function cssFiles(dir: string, out: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) cssFiles(path, out);
    else if (name.endsWith(".css")) out.push(path);
  }
  return out;
}

/// Splits on `sep` outside parentheses, brackets and quotes.
function splitTop(text: string, sep: (ch: string) => boolean): string[] {
  const parts: string[] = [];
  let depth = 0;
  let quote = "";
  let current = "";
  for (const ch of text) {
    if (quote) {
      if (ch === quote) quote = "";
    } else if (ch === '"' || ch === "'") quote = ch;
    else if (ch === "(" || ch === "[") depth += 1;
    else if (ch === ")" || ch === "]") depth -= 1;
    if (!quote && depth === 0 && sep(ch)) {
      parts.push(current);
      current = "";
    } else current += ch;
  }
  parts.push(current);
  return parts;
}

/// The compound selectors of one complex selector, left to right (split at its combinators).
function compounds(selector: string): string[] {
  return splitTop(selector, (ch) => ch === " " || ch === ">" || ch === "+" || ch === "~")
    .map((part) => part.trim())
    .filter(Boolean);
}

/// Every selector in the file whose `:has()` sits on a pane column with more selector after it.
function paneHas(file: string): string[] {
  const css = readFileSync(file, "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
  const found: string[] = [];
  for (const match of css.matchAll(/([^{};]+)\{/g)) {
    const prelude = match[1]!.trim();
    if (prelude.startsWith("@") || !prelude.includes(":has(")) continue;
    for (const raw of splitTop(prelude, (ch) => ch === ",")) {
      const selector = raw.replace(/\s+/g, " ").trim();
      const parts = compounds(selector);
      if (parts.slice(0, -1).some((part) => PANE.test(part) && part.includes(":has("))) found.push(selector);
    }
  }
  return found;
}

test("no pane column carries a non-subject :has() (paneAncestorHas.test.ts)", () => {
  const found = cssFiles(SRC).flatMap((file) => paneHas(file).map((selector) => `${relative(SRC, file)} ${selector}`));
  expect(found.filter((entry) => !KNOWN.has(entry))).toEqual([]);
});

test("the detector sees the shapes it guards", () => {
  const parts = (selector: string) =>
    compounds(selector)
      .slice(0, -1)
      .some((part) => PANE.test(part) && part.includes(":has("));
  expect(parts('.acpmux-main[data-dock="float"]:has(>.acpmux-stage>.x)>.acpmux-dock')).toBe(true);
  expect(parts(".acpmux-main:has(> .a) .b")).toBe(true);
  expect(parts(".acpmux-shell:has(> .a) > .b")).toBe(true);
  // The subject, a sibling's `:has()`, and other columns are not this shape.
  expect(parts(".acpmux-main[data-dock=float] > .acpmux-dock:has(.acpmux-composer-foot)")).toBe(false);
  expect(parts(".acpmux-main > .nt-style ~ * .nt-screen:has(.nt-foot)")).toBe(false);
  expect(parts(".acpmux-main-column:has(> .a) .b")).toBe(false);
});
