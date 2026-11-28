// A pseudo-element (`::before`, `::after`, ...) inside `:is()` or `:where()` is not a valid
// selector there, and Chrome drops the whole rule with it: the cloud button's reduced-motion rule
// listed `.acpmux-hybrid-glyph::before` in its `:is()`, so under Reduce Motion nothing in it
// applied and the lit cloud still faded in (hybrid-cloud-toggle-journey-browser.test.ts found it).
// Give the pseudo-element its own selector instead.
import { expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";

const SRC = path.resolve(import.meta.dir, "../src");

function cssFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return entry.name === "node_modules" ? [] : cssFiles(full);
    return entry.name.endsWith(".css") ? [full] : [];
  });
}

/// Every `:is(` / `:where(` group (balanced parentheses) that holds a `::`.
export function pseudoElementsInIs(css: string): string[] {
  const text = css.replace(/\/\*[\s\S]*?\*\//g, "");
  const found: string[] = [];
  for (const match of text.matchAll(/:(?:is|where)\(/g)) {
    let depth = 1;
    let end = match.index! + match[0].length;
    while (end < text.length && depth > 0) {
      if (text[end] === "(") depth += 1;
      else if (text[end] === ")") depth -= 1;
      end += 1;
    }
    const group = text.slice(match.index!, end);
    if (group.includes("::")) found.push(group);
  }
  return found;
}

test("the detector finds a pseudo-element inside :is() and passes one outside it", () => {
  expect(pseudoElementsInIs(".a :is(.b, .c::before) { x: y }")).toEqual([":is(.b, .c::before)"]);
  expect(pseudoElementsInIs(".a :is(.b, .c), .a .c::before { x: y }")).toEqual([]);
  expect(pseudoElementsInIs("/* :is(.c::after) */ .a {}")).toEqual([]);
});

test("no stylesheet puts a pseudo-element inside :is() or :where()", () => {
  const bad = cssFiles(SRC).flatMap((file) =>
    pseudoElementsInIs(readFileSync(file, "utf8")).map((group) => `${path.relative(SRC, file)}: ${group}`),
  );
  expect(bad).toEqual([]);
});
