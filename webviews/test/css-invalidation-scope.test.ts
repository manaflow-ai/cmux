// Selectors that make Chromium restyle whole subtrees (Leo, 2026-11-11, ask-17cca003dd: "It's still okay,
// if only it's fast. But it's not fast. It doesn't move at 120 hertz. That's our problem."). A send from
// the latest row restyled the whole pane several times in its first frames (bench/send-motion-frames.bench.ts:
// style 340 ms and layout 178 ms of an 840 ms window at 4x CPU, before), from three kinds of rule:
// - a `:has()` rule whose subject after it is a bare tag or any element (`X:has(Y) > :last-child`,
//   `X:has(Y) button`): Chromium keeps one restyle list for every `:has()` rule in the page, so each
//   `:has()` change anywhere restyled every such element, or the element's whole subtree;
// - a sibling rule (`+`, `~`) whose subject is any element (`* + *`, `:not(.a) ~ :not(.a)`): every row
//   inserted restyled the whole thread;
// - a rule on an ancestor's `style` attribute (`.ol[style*=...] > li`): every inline style write (the send
//   motion's, the follow glide's, each frame) restyled the elements it names under the written element.
// - a sibling rule with, on its left, an `:is()` or `:where()` that has a branch naming no class, id,
//   attribute or tag (`:is(:hover, :focus-visible)`, or the focus-ring gate `:where(:not(:root[...] *))`
//   after a `:focus-visible` there): Chromium then treats that part as any element, so every node a
//   streaming reply inserted restyled its later siblings and searched their subtrees (2026-11-17:
//   25-40% of the chat page's style time while a reply streamed). Write one selector per state.
// Each subject names a class, an id or an attribute instead (or `:nth-child(of)` / `:not(:first-child)`).
// The selectors checked are the built ones: after the focus-ring gate (scripts/postcss/focusRingGate.mjs).
import { expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { gateFocusVisible } from "../scripts/postcss/focusRingGate.mjs";

const src = path.resolve(import.meta.dir, "../src");

/// Pages outside the agent pane's document whose broad subject costs a handful of elements, with why.
const ALLOWED = new Map<string, string>([
  // The Markdown viewer's diagram fallback: one `pre` per diagram, in its own page.
  ['pages/markdown/styles.css .md-code-diagram:has(.md-diagram[data-state="error"]) pre', "one pre per diagram"],
  // Home's stage beside an open sheet: the stage's children are components with no shared class yet.
  // Follow-up: key them on a stage attribute the page sets when a sheet is open.
  ["pages/home-channels/ledger.css .lg-stage:has(> .lg-sheet) > :not(.lg-sheet)", "Home page, stage children"],
  [
    "pages/home-channels/chiefWork.css .lg-stage:has(> .hc-chief-work-scope) > :not(.hc-chief-work-scope)",
    "Home page, stage children",
  ],
]);

function cssFiles(dir: string): string[] {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return entry.name === "node_modules" ? [] : cssFiles(full);
    return entry.name.endsWith(".css") ? [full] : [];
  });
}

/// Every rule's selector text (at-rule preludes skipped), comments removed.
function selectorTexts(css: string): string[] {
  const text = css.replace(/\/\*[\s\S]*?\*\//g, "");
  const out: string[] = [];
  let buffer = "";
  for (const ch of text) {
    if (ch === "{") {
      const prelude = buffer.trim();
      if (prelude && !prelude.startsWith("@")) out.push(prelude);
      buffer = "";
    } else if (ch === "}" || ch === ";") buffer = "";
    else buffer += ch;
  }
  return out;
}

/// Splits at `separator` outside parentheses and brackets.
function splitTop(text: string, separator: (ch: string) => boolean): string[] {
  const parts: string[] = [];
  let depth = 0;
  let current = "";
  for (const ch of text) {
    if (ch === "(" || ch === "[") depth++;
    if (ch === ")" || ch === "]") depth--;
    if (depth === 0 && separator(ch)) {
      parts.push(current);
      current = "";
    } else current += ch;
  }
  parts.push(current);
  return parts.map((part) => part.trim()).filter(Boolean);
}

/// The selector's compounds and the combinators between them (" ", ">", "+", "~").
function compounds(selector: string): { parts: string[]; combinators: string[] } {
  const spaced = selector.replace(/\s*([>+~])\s*/g, " $1 ");
  const tokens = splitTop(spaced, (ch) => ch === " ");
  const parts: string[] = [];
  const combinators: string[] = [];
  let pending = " ";
  for (const token of tokens) {
    if (token === ">" || token === "+" || token === "~") pending = token;
    else {
      if (parts.length) combinators.push(pending);
      parts.push(token);
      pending = " ";
    }
  }
  return { parts, combinators };
}

/// What a compound keeps once functional pseudo-classes' arguments are dropped (`:not(.a)` names nothing).
const ownPart = (compound: string) => compound.replace(/\((?:[^()]|\([^()]*\))*\)/g, "()");
/// It names a class, an id or an attribute of its own, or is an `:is()`/`:where()` every branch of which does.
const named = (compound: string): boolean => {
  if (/[.#[]/.test(ownPart(compound))) return true;
  const list = /:(?:is|where)\(((?:[^()]|\([^()]*\))*)\)/.exec(compound)?.[1];
  return !!list && splitTop(list, (ch) => ch === ",").every((branch) => named(compounds(branch).parts.at(-1) ?? ""));
};
/// It names nothing at all: any element (`*`, `:last-child`, `:not(.a)`).
const anyElement = (compound: string) => !named(compound) && !/^[a-z]/i.test(ownPart(compound));

/// The argument of each `:is(...)` and `:where(...)` in `compound`, nested ones too.
function listArguments(compound: string): string[] {
  const out: string[] = [];
  for (const match of compound.matchAll(/:(?:is|where)\(/g)) {
    let depth = 1;
    let end = match.index! + match[0].length;
    for (; end < compound.length && depth; end++) {
      if (compound[end] === "(") depth++;
      else if (compound[end] === ")") depth--;
    }
    out.push(compound.slice(match.index! + match[0].length, end - 1));
  }
  return out;
}
/// It holds an `:is()` or `:where()` with a branch that names no class, id, attribute or tag.
const namelessList = (compound: string): boolean =>
  listArguments(compound).some((list) =>
    splitTop(list, (ch) => ch === ",").some((branch) => {
      const last = compounds(branch).parts.at(-1) ?? "";
      return !named(last) && !/^[a-z]/i.test(ownPart(last));
    }),
  );

function findings(file: string, selector: string): string[] {
  const out: string[] = [];
  const { parts, combinators } = compounds(selector);
  const subject = parts.at(-1);
  if (!subject || parts.length < 2) return out;
  if (parts.slice(0, -1).some((part) => /\[\s*style\b/.test(part))) out.push("a rule on an ancestor's style attribute");
  const hasAt = parts.findIndex((part) => part.includes(":has("));
  if (hasAt >= 0 && hasAt < parts.length - 1 && !named(subject))
    out.push(`a :has() rule whose subject (${subject}) names no class, id or attribute`);
  if (combinators.some((combinator) => combinator === "+" || combinator === "~") && anyElement(subject))
    out.push(`a sibling rule whose subject (${subject}) is any element`);
  const lastSibling = Math.max(combinators.lastIndexOf("+"), combinators.lastIndexOf("~"));
  if (parts.slice(0, lastSibling + 1).some(namelessList))
    out.push("a sibling rule with an :is() or :where() of states on its left");
  return out.filter(() => !ALLOWED.has(`${file} ${selector}`));
}

test("no selector restyles a whole subtree on a :has(), sibling or inline-style change", () => {
  const found: string[] = [];
  for (const full of cssFiles(src)) {
    const file = path.relative(src, full);
    for (const group of selectorTexts(fs.readFileSync(full, "utf8")))
      for (const selector of splitTop(gateFocusVisible(group), (ch) => ch === ","))
        for (const finding of findings(file, selector)) found.push(`${file}: ${selector} (${finding})`);
  }
  expect(found).toEqual([]);
});

test("the detector catches each kind", () => {
  expect(findings("x.css", ".a:has(.b) > :last-child")).toHaveLength(1);
  expect(findings("x.css", ".a:has(.b) button")).toHaveLength(1);
  expect(findings("x.css", ".md > * + *")).toHaveLength(1);
  expect(findings("x.css", ".c > :not(.d) ~ :not(.d)")).toHaveLength(1);
  expect(findings("x.css", '.ol[style*="--x"] > li')).toHaveLength(1);
  expect(findings("x.css", ".a:has(.b) > svg[data-icon]")).toEqual([]);
  expect(findings("x.css", ".md > :not(:first-child)")).toEqual([]);
  expect(findings("x.css", ".c > :nth-child(n + 2 of :not(.d))")).toEqual([]);
  expect(findings("x.css", ".a:has(.b)")).toEqual([]);
  expect(findings("x.css", '.icon[style*="background-image"]')).toEqual([]);
  expect(findings("x.css", ".tag > .x ~ svg[data-icon]")).toEqual([]);
  expect(findings("x.css", '.tag:where(:not(:root[data-m="p"] *)) ~ svg[data-icon]')).toHaveLength(1);
  expect(findings("x.css", ".tag.is-open:is(:hover, :focus-visible) ~ svg[data-icon]")).toHaveLength(1);
  expect(findings("x.css", ".tag.is-open:is(:hover) + .x")).toHaveLength(1);
  expect(findings("x.css", '.tag ~ svg[data-icon]:where(:not(:root[data-m="p"] *))')).toEqual([]);
  expect(findings("x.css", ".tag.is-open:hover ~ svg[data-icon]")).toEqual([]);
  expect(findings("x.css", '.goal:is([data-look="head"], li) + .x')).toEqual([]);
  expect(findings("x.css", ".a:not(.b) + .d")).toEqual([]);
  expect(findings("x.css", ":root:not([data-a], [data-b]) .x + .d")).toEqual([]);
  expect(findings("x.css", ":root:not([data-a], [data-b]) .x + .d")).toEqual([]);
});
