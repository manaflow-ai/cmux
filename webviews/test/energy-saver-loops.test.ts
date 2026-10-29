// Every CSS loop of the web pages holds still under Energy Saver
// (`data-cmux-energy="saver"`) and with animations off (`data-cmux-motion="off"`), the two marks the
// app's WebTheme bootstrap sets on <html> (WebTheme.swift). Chrome's battery saver stops frames
// nobody interacts with (chrome/browser/performance_manager/user_tuning/battery_saver_mode_manager.cc);
// an infinite CSS animation is such a frame source on every refresh.
//
// This counts every `infinite` animation declaration under webviews/src and checks that each one is
// either guarded (its rule's `:root` compound has `:not(...)` of the mark, so the loop never starts)
// or overridden (a rule of the same stylesheet, outside Reduce Motion, sets `animation: none` on the
// same element under `:root:is(...)` of the mark). The overrides also give the static state.
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { expect, test } from "bun:test";

const SRC = path.resolve(import.meta.dir, "../src");
const SAVER = "[data-cmux-energy=saver]";
const MOTION_OFF = "[data-cmux-motion=off]";

/** Loops the saver keeps by design, with why. Animations off still stops them. */
const SAVER_KEEPS: Record<string, string> = {
  // Edit mode follows the person; the native edit mode keeps its wiggle too.
  ".nt-widget-frame:not([data-dragging])": "edit mode's wiggle is person-started motion",
};

type Rule = { file: string; selectors: string[]; body: string; media: string[] };

function stylesheets(dir: string, out: string[] = []): string[] {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name !== "gallery") stylesheets(full, out);
    } else if (entry.name.endsWith(".css")) out.push(full);
  }
  return out.sort();
}

/** The index just past the block that opens at `open`, skipping quoted strings. */
function blockEnd(text: string, open: number): number {
  let depth = 0;
  for (let index = open; index < text.length; index += 1) {
    const char = text[index];
    if (char === '"' || char === "'") {
      index = text.indexOf(char, index + 1);
      if (index < 0) break;
    } else if (char === "{") depth += 1;
    else if (char === "}" && --depth === 0) return index + 1;
  }
  throw new Error("unbalanced braces");
}

/** Splits at commas outside parentheses and brackets. */
function splitTop(list: string): string[] {
  const parts: string[] = [];
  let depth = 0;
  let start = 0;
  for (let index = 0; index < list.length; index += 1) {
    const char = list[index];
    if (char === "(" || char === "[") depth += 1;
    else if (char === ")" || char === "]") depth -= 1;
    else if (char === "," && depth === 0) {
      parts.push(list.slice(start, index));
      start = index + 1;
    }
  }
  parts.push(list.slice(start));
  return parts.map((part) => part.trim()).filter(Boolean);
}

/** One spelling for a selector: unquoted attribute values, no space around commas, single spaces. */
function normalize(selector: string): string {
  return selector
    .replace(/=\s*"([^"]*)"/g, "=$1")
    .replace(/\s*,\s*/g, ",")
    .replace(/\(\s+/g, "(")
    .replace(/\s+\)/g, ")")
    .replace(/\s+/g, " ")
    .trim();
}

function parse(file: string, css: string, media: string[] = [], out: Rule[] = []): Rule[] {
  let index = 0;
  while (index < css.length) {
    const open = css.indexOf("{", index);
    if (open < 0) break;
    const end = blockEnd(css, open);
    // A statement before the rule (`@import ...;`) is not part of its prelude.
    const prelude = css.slice(index, open).split(";").pop()!.trim();
    const inner = css.slice(open + 1, end - 1);
    if (/^@(media|supports|layer|container)\b/.test(prelude)) parse(file, inner, [...media, prelude], out);
    else if (!prelude.startsWith("@")) {
      if (inner.includes("{")) throw new Error(`${file}: nested rule under ${prelude}`);
      out.push({ file, selectors: splitTop(prelude).map(normalize), body: inner, media });
    }
    index = end;
  }
  return out;
}

const rules = stylesheets(SRC).flatMap((file) =>
  parse(path.relative(SRC, file), readFileSync(file, "utf8").replace(/\/\*[\s\S]*?\*\//g, "")),
);

/** The `:root` compound a selector starts with, or "" (it ends at the first top-level combinator). */
function rootCompound(selector: string): string {
  if (!selector.startsWith(":root")) return "";
  let depth = 0;
  for (let index = 0; index < selector.length; index += 1) {
    const char = selector[index]!;
    if (char === "(" || char === "[") depth += 1;
    else if (char === ")" || char === "]") depth -= 1;
    else if (depth === 0 && /[\s>+~]/.test(char)) return selector.slice(0, index);
  }
  return selector;
}

/** The arguments of each top-level `:<name>(...)` of a compound, flattened. */
function pseudoArgs(compound: string, name: "not" | "is"): string[] {
  const args: string[] = [];
  const marker = `:${name}(`;
  let at = compound.indexOf(marker);
  while (at >= 0) {
    let depth = 0;
    let index = at + marker.length - 1;
    for (; index < compound.length; index += 1) {
      if (compound[index] === "(") depth += 1;
      else if (compound[index] === ")" && --depth === 0) break;
    }
    args.push(...splitTop(compound.slice(at + marker.length, index)));
    at = compound.indexOf(marker, index);
  }
  return args;
}

function guarded(selector: string, mark: string): boolean {
  return pseudoArgs(rootCompound(selector), "not").includes(mark);
}

function overridden(file: string, selector: string, mark: string): boolean {
  return rules.some(
    (rule) =>
      rule.file === file &&
      !rule.media.some((query) => query.includes("reduce")) &&
      /(^|[;\s])animation\s*:\s*none\b/.test(rule.body) &&
      rule.selectors.some((candidate) => {
        const compound = rootCompound(candidate);
        return (
          compound !== "" &&
          pseudoArgs(compound, "is").includes(mark) &&
          candidate.slice(compound.length).trim() === selector
        );
      }),
  );
}

const INFINITE = /(^|[;\s])animation(-iteration-count)?\s*:[^;]*\binfinite\b/;
const loops = rules
  .filter((rule) => INFINITE.test(rule.body))
  .flatMap((rule) => rule.selectors.map((selector) => ({ file: rule.file, selector })));

test("the count sees every infinite declaration (none hides in TS)", () => {
  // 23 declarations today; the 25 lines of the program's Q3 query add two comments
  // (agent-session/shared/pageReveal.ts and pages/shared/desktop.css).
  expect(rules.filter((rule) => INFINITE.test(rule.body)).length).toBeGreaterThanOrEqual(23);
  expect(loops.some((loop) => loop.file === "ui/wave.css")).toBe(true);
  expect(loops.some((loop) => loop.file === "prototypes/subagents/subagents.css")).toBe(true);
});

test("every infinite loop holds still under Energy Saver", () => {
  const missing = loops
    .filter((loop) => !(loop.selector in SAVER_KEEPS))
    .filter((loop) => !guarded(loop.selector, SAVER) && !overridden(loop.file, loop.selector, SAVER))
    .map((loop) => `${loop.file}: ${loop.selector}`);
  expect(missing).toEqual([]);
});

test("every infinite loop holds still with animations off", () => {
  const missing = loops
    .filter((loop) => !guarded(loop.selector, MOTION_OFF) && !overridden(loop.file, loop.selector, MOTION_OFF))
    .map((loop) => `${loop.file}: ${loop.selector}`);
  expect(missing).toEqual([]);
});

test("each loop the saver keeps still exists", () => {
  for (const selector of Object.keys(SAVER_KEEPS)) expect(loops.map((loop) => loop.selector)).toContain(selector);
});
