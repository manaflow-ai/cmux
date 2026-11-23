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
// Each subject names a class, an id or an attribute instead (or `:nth-child(of)` / `:not(:first-child)`).
import { expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";

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
  // Base's rules from after this check was written (not this check's PR); follow-up: key each subject
  // on a class its owner sets, as the composer's dock now does (App.tsx `markDockEdge`, `dockFoot`).
  [
    "ui/popupSurface.css .ui-popup[data-menu-states] .ui-menu-item:is([data-disabled], :disabled):has(.ui-menu-reason) > :not(.ui-menu-text)",
    "a disabled menu item's own children",
  ],
  [
    'agent-session/acpmux/conversation/conversation.css :root[data-transcript-timestamps="always"] .cv-user:not(:hover, :focus-within, :has([data-popup-open])) .cv-user__actions:not(.cv-user__actions--versions) .cv-message-footer-row > :not(.cv-user__time)',
    "a prompt's footer row children",
  ],
  [
    'agent-session/acpmux/conversation/conversation.css :root[data-transcript-timestamps="always"] .acpmux-assistant:not(:hover, :focus-visible, :has([data-popup-open])) .cv-reply-actions:not(:focus-within) .cv-message-footer-row > :not(.cv-turn-time)',
    "a reply's footer row children",
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
  return out.filter(() => !ALLOWED.has(`${file} ${selector.replace(/\s+/g, " ")}`));
}

test("no selector restyles a whole subtree on a :has(), sibling or inline-style change", () => {
  const found: string[] = [];
  for (const full of cssFiles(src)) {
    const file = path.relative(src, full);
    for (const group of selectorTexts(fs.readFileSync(full, "utf8")))
      for (const selector of splitTop(group, (ch) => ch === ","))
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
});

// Wide `:has()` whose subject is a whole part (the composer form, its card, the dock, `body`) and whose
// argument is focus or a descendant: Chromium checked it again for every node a keystroke or a streamed
// chunk inserted under the part (transcript-motion-model step 7, invariant I8). The part's owner writes
// the state as an attribute instead: `data-focused` (ComposerBox, Composer, App's dock, NewTabScreen),
// `data-queue` (ComposerQueue), `data-strip` (Composer's location strip), `data-foot` (the forms, App's
// dock). These forms may not come back in the agent pane's CSS.
const WIDE_HAS: [RegExp, string][] = [
  [/:has\(\s*>\s*\.acpmux-composer-box\s+:focus-visible/, "the form's card focus: [data-focused]"],
  [/\.acpmux-composer-box:has\(\s*:focus-visible/, "the card's focus: [data-focused]"],
  [/\.nt-box:has\(\s*:focus-visible/, "the New Tab box's focus: [data-focused]"],
  [/\.nt-composer:has\([^)]*:focus-visible/, "the New Tab composer's focus: [data-focused]"],
  [/\bbody:has\(/, "a body-wide :has(): the owner's class or attribute"],
  [/\.acpmux-dock:has\(/, "the dock's focus or foot: [data-focused] / [data-foot]"],
  [/:has\(\s*>\s*\.acpmux-composer-queue\s*\)/, "the form's queue: [data-queue]"],
  [/:has\(\s*>\s*\.acpmux-composer-strip\s*\)/, "the form's strip: [data-strip]"],
  [/:has\(\s*\.acpmux-composer-foot\b/, "the form's foot: [data-foot]"],
];

function wideHas(css: string): string[] {
  const out: string[] = [];
  for (const group of selectorTexts(css))
    for (const selector of splitTop(group, (ch) => ch === ","))
      for (const [pattern, instead] of WIDE_HAS) if (pattern.test(selector)) out.push(`${selector} (${instead})`);
  return out;
}

test("the composer and dock read owner-set attributes, not a wide :has()", () => {
  const found: string[] = [];
  for (const full of cssFiles(path.join(src, "agent-session")))
    for (const hit of wideHas(fs.readFileSync(full, "utf8"))) found.push(`${path.relative(src, full)}: ${hit}`);
  expect(found).toEqual([]);
});

test("the wide :has() ban catches each replaced form", () => {
  for (const css of [
    ".acpmux-composer:has(> .acpmux-composer-box :focus-visible) { color: red }",
    ".acpmux-composer-box:has(:focus-visible) { color: red }",
    ".nt-box:has(:focus-visible) { color: red }",
    "body:has(.nt-popover-open) .nt-popover { color: red }",
    ".acpmux-dock:has(:focus-visible) { color: red }",
    ".acpmux-composer:has(.acpmux-composer-foot) .x { color: red }",
    ".acpmux-composer:has(> .acpmux-composer-queue) .x { color: red }",
    ".acpmux-composer:not(:has(> .acpmux-composer-strip)) { color: red }",
  ])
    expect(wideHas(css)).toHaveLength(1);
  expect(wideHas(".acpmux-composer[data-queue] .x { color: red }")).toEqual([]);
  expect(wideHas("/* .acpmux-dock:has(x) */ .a { color: red }")).toEqual([]);
  expect(wideHas(".acpmux-queue-row:has(+ .acpmux-queue-row) { color: red }")).toEqual([]);
  // A mixed argument (any of several children) still needs `:has()`; the strip on New Tab is not streamed.
  expect(
    wideHas(".a + .acpmux-composer:not(:has(> .acpmux-composer-queue, > .acpmux-composer-strip)) { color: red }"),
  ).toEqual([]);
  expect(wideHas(".nt-composer:has(.acpmux-composer-strip) .nt-box { color: red }")).toEqual([]);
});
