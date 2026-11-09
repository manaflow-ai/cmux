// A control the transcript shows only on hover fades in and out, never blinks (Leo 2026-10-28:
// "there should be, like, a fast fade-in fade-out. Right now they're just appearing and
// disappearing. Like they're just blinking in and out of existence, and it's a bit jarring").
// Every one takes the message hover row's dwell ramp (conversation.css --cv-actions-*, aliases of
// pages/shared/desktop.css --cmux-hover-reveal-*; Leo, 2026-11-07: "it should be, like, having its
// limit based off of how long you've had your cursor actually on it"): out on its ease-in at rest,
// in on its ramp under the pointer with no delay, so a brush past reaches only a faint level.
// test/hover-reveal-dwell.test.ts measures the ramp in Chromium.
// - A hover-revealed control is a class a transcript stylesheet hides (`opacity: 0` or
//   `visibility: hidden`) in a rule without a reveal state, and shows (`opacity` above 0 or
//   `visibility: visible`) in a rule with one (`:hover`, `:focus-within`, `:focus-visible`,
//   `[data-turn-revealed]`). The class is the selector's subject (its last compound, `:is()` lists
//   included).
// - Each one transitions `opacity` on `var(--cv-actions-out` and `var(--cv-actions-out-ease` in a
//   rule without a reveal state, and, when the pointer reveals it, on `var(--cv-actions-in` and
//   `var(--cv-actions-in-ease` in a `:hover` rule. No rule waits on a delay before the ramp.
// - A list row's own hover parts (a finished call's check and time, a row's chevron) follow the
//   list-row sweep rule instead (pages/shared/desktop.css "Hover intent", Leo 2026-10-14): at once
//   on hover, out on the quick step, `var(--cv-row-reveal-out)` in a rule without a reveal state.
//   The dwell ramp trailed the pointer down a live turn's rows (Leo, 2026-11-09: "oh im mostly just
//   saying that it lags"; test/agent-pane-hover-follows-row.test.ts plays it in a browser).
// Menus and popovers are not transcript controls here: they open on the click with no fade
// (popover-instant-open.test.ts).
import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";

const ACPMUX = path.resolve(import.meta.dir, "../src/agent-session/acpmux");
/// The folders whose stylesheets draw transcript rows: the rows themselves, the sub-session and
/// subagent lines inside them, and the chips and media in their text.
const TRANSCRIPT_DIRS = ["conversation", "subagents", "chips"];

const transcriptSheets = () =>
  TRANSCRIPT_DIRS.flatMap((dir) =>
    readdirSync(path.join(ACPMUX, dir))
      .filter((name) => name.endsWith(".css") && !name.endsWith(".gallery.css"))
      .map((name) => path.join(ACPMUX, dir, name)),
  );

type Rule = { file: string; line: number; selector: string; decls: [string, string][] };

/// Style rules with their line. Comments blank out (lines stay true) and keyframe blocks drop out;
/// a rule inside `@media` is read as a rule (its condition is not kept).
function cssRules(file: string, source: string): Rule[] {
  const blank = (text: string) => text.replace(/[^\n]/g, " ");
  const text = source
    .replace(/\/\*[\s\S]*?\*\//g, blank)
    .replace(/@(-webkit-)?keyframes[^{]*\{(?:[^{}]*\{[^{}]*\})*[^{}]*\}/g, blank);
  const lineAt = (index: number) => text.slice(0, index).split("\n").length;
  return [...text.matchAll(/([^{};]+)\{([^{}]*)\}/g)].map((match) => {
    const decls = match[2]
      .split(/;(?![^(]*\))/)
      .map((part) => part.trim())
      .filter(Boolean)
      .map((part) => {
        const colon = part.indexOf(":");
        return [part.slice(0, colon).trim().toLowerCase(), part.slice(colon + 1).trim()] as [string, string];
      });
    const lead = match[1].length - match[1].trimStart().length;
    return { file, line: lineAt(match.index + lead), selector: match[1].replace(/\s+/g, " ").trim(), decls };
  });
}

/// Splits on `separator` outside parentheses and brackets.
function splitTop(text: string, separator: RegExp): string[] {
  const parts: string[] = [];
  let depth = 0;
  let start = 0;
  for (let index = 0; index < text.length; index++) {
    const char = text[index];
    if (char === "(" || char === "[") depth++;
    else if (char === ")" || char === "]") depth--;
    else if (depth === 0 && separator.test(char)) {
      parts.push(text.slice(start, index));
      start = index + 1;
    }
  }
  parts.push(text.slice(start));
  return parts.map((part) => part.trim()).filter(Boolean);
}

const REVEAL = /:hover|:focus-within|:focus-visible|\[data-turn-revealed\]/;
const OUT = "var(--cv-actions-out";
const IN = "var(--cv-actions-in";
const OUT_EASE = "var(--cv-actions-out-ease";
const IN_EASE = "var(--cv-actions-in-ease";
const HOVER = /:hover/;
const ZERO = /^0(\.0+)?$/;

/// The classes a selector's subject names: its last compound's, `:is()`/`:where()` lists included,
/// `:not()` and `:has()` arguments left out (they name other elements' states).
function subjectClasses(selector: string): string[] {
  const subject = splitTop(selector, /[\s>+~]/).at(-1) ?? "";
  const own = subject.replace(/:(not|has)\((?:[^()]|\([^()]*\))*\)/g, "");
  return [...own.matchAll(/\.([\w-]+)/g)].map((match) => match[1]);
}

type Control = {
  name: string;
  hidden: Rule[];
  shown: Rule[];
  fadesOut: boolean;
  fadesInOnHover: boolean;
  leavesOnRowStep: boolean;
};

// The running subagent Stop is an intentional immediate reveal. Its per-row control is kept
// transparent at rest so a tray does not repeat a lit Stop on every line; subagent-stop-hover.test.tsx
// pins that contract. It is the settled exception in the chat-transcript action rules, not a blink
// in the fade-enabled message and tool controls covered here.
const IMMEDIATE_REVEALS = new Set(["cv-subagent__stop"]);

/// A list row's own hover parts: shown at once, gone on the quick step (conversation.css HOVER
/// FOLLOWS THE POINTER), never on the message dwell.
const LIST_ROW_REVEALS = new Set(["cv-command__ok", "cv-command__time", "cv-tool__chevron"]);
const ROW_OUT = "var(--cv-row-reveal-out";

/// Every hover-revealed control in `sheets` and whether it takes the shared fade.
function hoverControls(sheets: { file: string; source: string }[]): Control[] {
  const controls = new Map<string, Control>();
  const control = (name: string) => {
    let found = controls.get(name);
    if (!found)
      controls.set(
        name,
        (found = { name, hidden: [], shown: [], fadesOut: false, fadesInOnHover: false, leavesOnRowStep: false }),
      );
    return found;
  };
  const hoverShown = new Set<string>();
  const fadesIn = new Set<string>();
  for (const rule of sheets.flatMap(({ file, source }) => cssRules(file, source))) {
    const values = (name: string) => rule.decls.filter(([key]) => key === name).map(([, value]) => value);
    const onOpacity = (value: string) => /\bopacity\b|\ball\b/.test(value);
    const transitions = [...values("transition"), ...values("transition-property")].filter(onOpacity);
    const fadeOut = transitions.some((value) => value.includes(OUT) && value.includes(OUT_EASE));
    const fadeIn = transitions.some((value) => value.includes(IN) && value.includes(IN_EASE));
    const rowOut = values("transition").some((value) => value.includes(ROW_OUT));
    for (const selector of splitTop(rule.selector, /,/)) {
      const revealing = REVEAL.test(selector);
      const hides = values("opacity").some((value) => ZERO.test(value)) || values("visibility").includes("hidden");
      const shows = values("opacity").some((value) => !ZERO.test(value)) || values("visibility").includes("visible");
      for (const name of subjectClasses(selector)) {
        if (hides && !revealing) control(name).hidden.push(rule);
        if (shows && revealing) {
          control(name).shown.push(rule);
          if (HOVER.test(selector)) hoverShown.add(name);
        }
        if (!revealing && fadeOut) control(name).fadesOut = true;
        if (!revealing && rowOut) control(name).leavesOnRowStep = true;
        if (HOVER.test(selector) && fadeIn) fadesIn.add(name);
      }
    }
  }
  return [...controls.values()]
    .filter((one) => one.hidden.length && one.shown.length)
    .map((one) => ({ ...one, fadesInOnHover: !hoverShown.has(one.name) || fadesIn.has(one.name) }));
}

const where = (rule: Rule) => `${path.relative(ACPMUX, rule.file)}:${rule.line}`;

/// The controls that blink, as `.name (hidden at …, shown at …): what is missing`.
function blinking(controls: Control[]): string[] {
  return controls
    .filter((one) => !IMMEDIATE_REVEALS.has(one.name))
    .filter((one) => (LIST_ROW_REVEALS.has(one.name) ? !one.leavesOnRowStep : !one.fadesOut || !one.fadesInOnHover))
    .map((one) => {
      const missing = LIST_ROW_REVEALS.has(one.name)
        ? ["no transition on var(--cv-row-reveal-out) at rest"]
        : [
            !one.fadesOut && "no opacity transition on var(--cv-actions-out) var(--cv-actions-out-ease) at rest",
            !one.fadesInOnHover && "no :hover opacity transition on var(--cv-actions-in) var(--cv-actions-in-ease)",
          ].filter(Boolean);
      const hidden = one.hidden.map(where).join(", ");
      const shown = one.shown.map(where).join(", ");
      return `.${one.name} (hidden at ${hidden}, shown at ${shown}): ${missing.join("; ")}`;
    });
}

describe("transcript hover-revealed controls fade", () => {
  const sheets = transcriptSheets().map((file) => ({ file, source: readFileSync(file, "utf8") }));
  const controls = hoverControls(sheets);

  test("no reveal waits on a delay: the ramp starts with the pointer", () => {
    const delayed = sheets.flatMap(({ file, source }) =>
      source
        .split("\n")
        .map((line, index) => ({ line, at: `${path.relative(ACPMUX, file)}:${index + 1}` }))
        .filter(({ line }) => line.includes("--cv-actions-in-delay"))
        .map(({ at }) => at),
    );
    expect(delayed).toEqual([]);
  });

  test("every fade-enabled hover-revealed transcript control uses the shared tokens", () => {
    expect(blinking(controls)).toEqual([]);
  });

  test("the scan sees the hover rows Leo pointed at", () => {
    // A received message's hover slot, its Reply, a finished call's check and time, and corner actions.
    // Chat-opening controls are always shown, so they have no hover reveal to fade.
    const names = controls.map((one) => one.name);
    for (const name of [
      "cv-user__actions",
      "cv-received-actions",
      "cv-received__reply",
      "cv-received__hover",
      "cv-reply-actions",
      "cv-turn-actions",
      "cv-command__ok",
      "cv-command__time",
      "cv-tool-output__actions",
      "cv-sent-actions",
      "cv-table-tools",
      "cv-media__actions",
      "cv-subagent__stop",
    ])
      expect(names).toContain(name);
  });

  test("a control that shows on hover with no fade is reported", () => {
    const fixture = (css: string) => blinking(hoverControls([{ file: path.join(ACPMUX, "fixture.css"), source: css }]));
    expect(fixture(".row-tools { opacity: 0 } .row:hover .row-tools { opacity: 1 }")).toEqual([
      ".row-tools (hidden at fixture.css:1, shown at fixture.css:1): no opacity transition on var(--cv-actions-out) var(--cv-actions-out-ease) at rest; no :hover opacity transition on var(--cv-actions-in) var(--cv-actions-in-ease)",
    ]);
    // A fade of its own duration is not the shared fade.
    expect(
      fixture(".row-tools { opacity: 0; transition: opacity 120ms ease-out } .row:hover .row-tools { opacity: 1 }"),
    ).toHaveLength(1);
    // visibility swaps blink too.
    expect(fixture(".row-tools { visibility: hidden }\n.row:hover .row-tools { visibility: visible }")).toHaveLength(1);
    expect(
      fixture(`.row-tools { opacity: 0 }
        .row:hover .row-tools, .row-tools:focus-within { opacity: 1 }
        @media (prefers-reduced-motion: no-preference) {
          .row-tools { transition: opacity var(--cv-actions-out) var(--cv-actions-out-ease) }
          .row:hover .row-tools {
            transition: opacity var(--cv-actions-in) var(--cv-actions-in-ease);
          }
        }`),
    ).toEqual([]);
    // Shown only from the keyboard: the fade out is enough.
    expect(
      fixture(
        ".row-tools { opacity: 0; transition: opacity var(--cv-actions-out) var(--cv-actions-out-ease) } .row-tools:focus-within { opacity: 1 }",
      ),
    ).toEqual([]);
  });
});
