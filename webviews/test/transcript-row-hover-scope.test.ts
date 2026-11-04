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
// - The live line's "· 12m 9s total" reads at one tone: the words around the time are as dim as it.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const DIR = join(import.meta.dir, "../src/agent-session/acpmux/conversation");
const STATE = /:(hover|active|focus|focus-visible|focus-within)\b/;
const INK = /(?<![\w-])(color|opacity|filter)\s*:/;

function rules(file: string): { selector: string; body: string }[] {
  const css = readFileSync(join(DIR, file), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
  return [...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)].flatMap(([, selectors = "", body = ""]) =>
    selectors
      .split(/,(?![^()]*\))/)
      .map((selector) => ({ selector: selector.trim().replace(/\s+/g, " "), body })),
  );
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
      if (/\.cv-worked(?![\w-])/.test(lit) && !/^button\.cv-worked/.test(lit)) found.push(`${file}: ${selector}`);
    }
  expect(found).toEqual([]);
});

test("the live line's total reads at the time's dim tone", () => {
  const css = rules("conversation.css");
  const total = css.find(({ selector }) => selector === ".cv-worked__total");
  expect(total?.body).toMatch(/(?<![\w-])color\s*:\s*var\(--cv-text-dim\)/);
});
