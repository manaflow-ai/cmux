// No stylesheet has a rule whose subject is `*` (or only pseudo-classes) under ancestors Chromium cannot
// look up by class, id, tag or attribute, such as `:where(button, a[href], ...) *` or `:disabled *`.
// Chromium finds no bucket for such a rule, so it tries it on every element it styles, and its ancestor
// Bloom filter has nothing to reject with, so each try walks every ancestor of the element and tests each
// one. desktop.css's `:where(button, ...) * { cursor: inherit }` alone cost about 230 ms of style recalc
// for 24 older pages of a 100,000-row chat (transcript-scroll-up.bench.ts TRACE=3), the most of any rule.
// A rule like `[inert] *` or `fieldset:disabled *` is fine: an ancestor with no `inert` attribute or no
// fieldset rejects it at once.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { Glob } from "bun";

const src = join(import.meta.dir, "../src");

/// `text` split at `separators` outside parentheses and brackets.
function splitTop(text: string, separators: string): string[] {
  const parts: string[] = [];
  let depth = 0;
  let current = "";
  for (const char of text) {
    if (char === "(" || char === "[") depth += 1;
    else if (char === ")" || char === "]") depth -= 1;
    if (depth === 0 && separators.includes(char)) {
      parts.push(current);
      current = "";
      continue;
    }
    current += char;
  }
  parts.push(current);
  return parts;
}

/// A compound's own simple selectors, with every parenthesized argument dropped.
function outside(compound: string): string {
  let depth = 0;
  let out = "";
  for (const char of compound) {
    if (char === "(") depth += 1;
    else if (char === ")") depth -= 1;
    else if (depth === 0) out += char;
  }
  return out;
}

/// Whether Chromium can reject this ancestor compound from its Bloom filter: it names a class, an id, a
/// tag or an attribute at its top level (not only inside `:not()` or a list), or it is a one-argument
/// `:is()` or `:where()` whose argument does: Chromium (selector_filter.cc) and WebKit (SelectorFilter.cpp)
/// collect a single argument's identifiers as if it were written out, and nothing from a list.
function lookedUp(compound: string): boolean {
  if (/[.#[]|^[a-zA-Z]/.test(outside(compound).replace(/::?[\w-]+/g, ""))) return true;
  const only = /^:(?:is|where)\((.*)\)$/.exec(compound.trim());
  if (!only || splitTop(only[1]!, ",").length !== 1) return false;
  return splitTop(only[1]!.trim().replace(/\s*([>+~])\s*/g, " "), " ")
    .filter(Boolean)
    .some(lookedUp);
}

/// Whether a subject compound is `*` or only pseudo-classes, so it lands in Chromium's universal bucket.
const universal = (compound: string) =>
  /^\*?(?::[\w-]+(?:\([^)]*\))?)*$/.test(compound.trim()) && !/:(is|where|not|has)\(/.test(compound);

function descendantUniversalRules(css: string): string[] {
  const found: string[] = [];
  const text = css.replace(/\/\*[\s\S]*?\*\//g, "");
  for (const match of text.matchAll(/([^{}@;]+)\{/g)) {
    for (const raw of splitTop(match[1]!, ",")) {
      const selector = raw.trim().replace(/\s+/g, " ");
      if (!selector || /^(from|to|\d+%)$/.test(selector)) continue;
      const compounds = splitTop(selector.replace(/\s*([>+~])\s*/g, " "), " ").filter(Boolean);
      if (compounds.length < 2) continue;
      if (!universal(compounds.at(-1)!)) continue;
      if (compounds.slice(0, -1).some(lookedUp)) continue;
      found.push(selector);
    }
  }
  return found;
}

test("the detector finds a descendant-universal rule and passes ones Chromium can reject", () => {
  expect(descendantUniversalRules(":where(button, a[href]) * { cursor: inherit; }")).toEqual([
    ":where(button, a[href]) *",
  ]);
  expect(descendantUniversalRules(":disabled:not(fieldset) * { cursor: default; }")).toEqual([
    ":disabled:not(fieldset) *",
  ]);
  expect(
    descendantUniversalRules(
      "[inert] *, button:disabled *, .selectable *, fieldset:disabled > :not(legend) span, :where(button) :where(.selectable) { x: y; }",
    ),
  ).toEqual([]);
  // A one-argument `:where()` ancestor is looked up by what it holds; a list, or only pseudo-classes, is not.
  expect(
    descendantUniversalRules(
      ':where(.selectable) *, :where(a[href]) *, :where([role]:is([role="tab"], [role="option"])) :where(.selectable) *, :where(.a, .b) *, :where(:hover) * { x: y; }',
    ),
  ).toEqual([":where(.a, .b) *", ":where(:hover) *"]);
});

test("no webview stylesheet has a rule whose subject is `*` under ancestors Chromium cannot look up", () => {
  const offenders: string[] = [];
  for (const file of new Glob("**/*.css").scanSync(src))
    for (const selector of descendantUniversalRules(readFileSync(join(src, file), "utf8")))
      offenders.push(`${file}: ${selector}`);
  console.log(`descendant-universal rules: ${offenders.length}`);
  expect(offenders).toEqual([]);
});
