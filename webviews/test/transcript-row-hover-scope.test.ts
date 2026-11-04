// A transcript row never lights up as a whole under the pointer: a hover or focus highlight covers
// only its own control (rulebook; design/chat-transcript.md "Hover lights only the control").
// Leo, 2026-11-03, on the "2 background updates" line brightening edge to edge under the pointer:
// "this thing appears/lights up on hover for no reason!?"
//
// - An activity row (TranscriptActivityRow: background updates, subagent, messaging and inbox
//   lines; DisclosureRow's lines on its shell) keeps its words at their rest tone; only its
//   chevron lifts, and only when the line is a button that opens something.
// - A line with no action behind it (the live "Thinking" line, a `div.cv-worked`) never lifts: only
//   the "Worked for" button's own hover may.
// - The live line's counts ("Ran cat x 0s · 39s · 1K tokens") read in one dim tone, and no word
//   "total" (Leo, 2026-11-03: "same here it's annoying to look at"; the dot gap is #34866's,
//   webviews/test/transcript-live-line-dot-gap-css.test.ts).
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const DIR = join(import.meta.dir, "../src/agent-session/acpmux/conversation");
const STATE = /:(hover|active|focus|focus-visible|focus-within)\b/;
const INK = /(?<![\w-])(color|opacity|filter)\s*:/;

function rules(file: string): { selector: string; body: string }[] {
  const css = readFileSync(join(DIR, file), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
  return [...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)].flatMap(([, selectors = "", body = ""]) =>
    splitList(selectors).map((selector) => ({ selector: selector.trim().replace(/\s+/g, " "), body })),
  );
}

/** A selector list's members, split on commas outside parentheses (nested ones too). */
function splitList(list: string): string[] {
  const out: string[] = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < list.length; i += 1) {
    const ch = list[i];
    if (ch === "(") depth += 1;
    else if (ch === ")") depth -= 1;
    else if (ch === "," && depth === 0) {
      out.push(list.slice(start, i));
      start = i + 1;
    }
  }
  out.push(list.slice(start));
  return out;
}

/** The selector's subject: its last compound (after the last combinator outside parentheses). */
function subject(selector: string): string {
  let depth = 0;
  let start = 0;
  for (let i = 0; i < selector.length; i += 1) {
    const ch = selector[i];
    if (ch === "(") depth += 1;
    else if (ch === ")") depth -= 1;
    else if (depth === 0 && (ch === " " || ch === ">" || ch === "+" || ch === "~")) start = i + 1;
  }
  return selector.slice(start).trim();
}

test("an activity row's hover lights only its chevron, and only on a row that opens", () => {
  const found: string[] = [];
  for (const { selector, body } of rules("TranscriptActivityRow.css")) {
    if (!selector.includes(".cv-agent-activity-row") || !STATE.test(selector) || !INK.test(body)) continue;
    const lit = subject(selector);
    const chevronOfAButton =
      // The chevron inside the line's button, or beside it (SubagentDoneLine.tsx), of a line that opens.
      (/\.cv-agent-activity__chevron\b/.test(lit) && /button\.cv-agent-activity__control\b/.test(selector)) ||
      (/\.cv-rotor\b/.test(lit) && /\.cv-disclosure__toggle\b/.test(selector));
    if (!chevronOfAButton) found.push(selector);
  }
  expect(found).toEqual([]);
});

test("a transcript line with no action behind it never lifts on hover", () => {
  const found: string[] = [];
  for (const file of ["conversation.css", "TranscriptActivityRow.css"])
    for (const { selector, body } of rules(file)) {
      if (!STATE.test(selector) || !INK.test(body)) continue;
      // `.cv-worked` is both the "Worked for" button and the live line's div: a state rule that
      // lights the line itself names the button. Revealing a control inside it is fine.
      const lit = subject(selector);
      if (/\.cv-worked(?![\w-])/.test(lit) && !lit.startsWith("button.cv-worked")) found.push(`${file}: ${selector}`);
    }
  expect(found).toEqual([]);
});

test("a clicked activity row's focus never lights its words", () => {
  // `.cv-tool` is also every activity row's control: a click leaves it focused, so the tool rows'
  // focus lift leaves it out (TranscriptActivityRow.css lights only its chevron).
  const found = rules("conversation.css")
    // A bare `.cv-tool` rule matches an activity row's control; rows inside a step list don't.
    .filter(
      ({ selector, body }) =>
        selector === subject(selector) &&
        /^\.cv-tool(?![\w-])/.test(selector) &&
        /:focus-within\b/.test(selector) &&
        INK.test(body),
    )
    .filter(({ selector }) => !/\.cv-agent-activity__control/.test(selector))
    .map(({ selector }) => selector);
  expect(found).toEqual([]);
});

test("the live line's counts read in one dim tone, and no word says total", () => {
  const css = rules("conversation.css");
  const count = css.find(
    (rule) => rule.selector === ".cv-worked--live > .cv-worked__count:not(:has(.cv-worked__open))",
  );
  expect(count?.body).toMatch(/(?<![\w-])color\s*:\s*var\(--cv-text-dim\)/);
  // The turn's clock follows the step's own time after a dot, with no word (#34866).
  expect(readFileSync(join(DIR, "Thinking.tsx"), "utf8")).not.toContain("turn.live.total");
});
