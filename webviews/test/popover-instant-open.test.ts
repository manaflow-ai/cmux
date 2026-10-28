// Popovers and menus open in one frame and fade only as they close (Leo 2026-10-24: "When you open
// it up, no animation. When you close it, animation for closing. That's it, right? ... No fade in.
// Just boom. It's instant. Fade out, yes. No fade in ever for any of these." He was clicking the
// agent chat header's vertical ellipsis, a Base UI Menu: header/ChatHeaderTools.tsx ChatMenu).
// Panels that slide in from an edge, browser and pane motion, dialogs and tooltips are not popovers
// and keep their own motion.
// - Every lane: no stylesheet under webviews/src starts an animation on a popup or menu surface, or
//   draws a starting style for one to enter from (outside its exit state).
// popover-instant-open-pane.test.ts opens the real agent pane's ... menu in Chromium.
import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";

const WEBVIEWS = path.resolve(import.meta.dir, "..");

/// The classes a popup or menu surface carries: the shared primitives' (ui/Menu, Popover, Select,
/// Combobox, ContextMenu) and the agent pane's own menus and popovers. A rule applies to the surface
/// when its subject (last compound) names one.
const POPUP_CLASSES = [
  "ui-popup",
  "ui-menu",
  "ui-popover",
  "ui-context-menu",
  "ui-combobox-popup",
  "acpmux-menu",
  "acpmux-slash-menu",
  "acpmux-mp",
  "acpmux-chat-menu-popover",
  "acpmux-pr-status",
  "acpmux-needs-you",
  "acpmux-access-menu",
  "acpmux-file-menu-list",
  "acpmux-effort-menu",
];
const POPUP = new RegExp(`\\.(${POPUP_CLASSES.join("|")})(?![\\w-])`);
/// A state the surface leaves through: its fade out is allowed.
const EXIT_STATE = /\[data-ending-style\]|\[data-closed\]|\[data-state="?closed|\[data-presence="?leaving|closing/;

type Rule = { line: number; selector: string; decls: [string, string][] };

/// Style rules with their line. Comments blank out (lines stay true) and keyframe blocks drop out:
/// a keyframe is judged where a rule starts it.
function cssRules(source: string): Rule[] {
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
    return { line: lineAt(match.index + lead), selector: match[1].replace(/\s+/g, " ").trim(), decls };
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

/// The selectors in a rule whose subject is a popup or menu surface (not one of its rows).
function popupSubjects(selector: string): string[] {
  return splitTop(selector, /,/).filter((one) => POPUP.test(splitTop(one, /[\s>+~]/).at(-1) ?? ""));
}

/// What a rule does to a popup or menu as it opens, as `line why`.
function popupEntrances(source: string): string[] {
  const found: string[] = [];
  for (const rule of cssRules(source)) {
    const subjects = popupSubjects(rule.selector).filter((one) => !EXIT_STATE.test(one));
    if (!subjects.length) continue;
    const where = `${rule.line} \`${subjects.join(", ")}\``;
    const values = (...names: string[]) => rule.decls.filter(([name]) => names.includes(name)).map(([, v]) => v);
    const loops = values("animation-iteration-count").some((value) => /infinite/.test(value));
    const animation = values("animation", "animation-name").find(
      (value) => !/^none\b/.test(value) && !/\binfinite\b/.test(value) && !loops,
    );
    if (animation) found.push(`${where} starts \`animation: ${animation}\``);
    if (subjects.some((one) => /\[data-starting-style\]|\[data-open\]|\[data-instant\]/.test(one))) {
      const moves = rule.decls.some(
        ([name, value]) =>
          (name === "opacity" && Number.parseFloat(value) < 1) ||
          (["transform", "translate", "scale"].includes(name) && !/^(none|0(px)?( 0(px)?)?)$/.test(value)),
      );
      if (moves) found.push(`${where} draws a starting style to enter from`);
    }
  }
  return found;
}

function stylesheets(dir: string): string[] {
  const found: string[] = [];
  for (const name of readdirSync(dir)) {
    const full = path.join(dir, name);
    if (statSync(full).isDirectory()) found.push(...stylesheets(full));
    else if (full.endsWith(".css")) found.push(full);
  }
  return found;
}

describe("popovers and menus open in one frame", () => {
  // The effort track is the model menu's slider (EffortPicker), and stands on its own in the gallery:
  // it keeps its entrance there, and opens with the menu, at once, inside a popup.
  test("the effort track enters on its own but not inside a popup", () => {
    const source = readFileSync(path.join(WEBVIEWS, "src/agent-session/acpmux/composerControls.css"), "utf8");
    const rules = cssRules(source);
    const own = rules.find((rule) => rule.selector.trim() === ".acpmux-effort-track");
    const inPopup = rules.find((rule) => rule.selector.trim() === ".ui-popup .acpmux-effort-track");
    expect({
      own: own?.decls.find(([name]) => name === "animation")?.[1].startsWith("acpmux-effort-track-in"),
      inPopup: inPopup?.decls.find(([name]) => name === "animation")?.[1],
    }).toEqual({ own: true, inPopup: "none" });
  });

  test("the scan catches an open animation and a starting style on a popup, and passes its exit fade", () => {
    expect(
      popupEntrances(`
        .ui-popup.acpmux-chat-menu-popover { animation: ui-popup-open 120ms ease-out }
        @media (prefers-reduced-motion: reduce) { :where(.ui-popup) { animation: ui-popup-fade 120ms } }
        .ui-popover[data-starting-style] { opacity: 0 }
        .ui-popup[data-ending-style] { opacity: 0; animation: out 80ms }
        .ui-menu .ui-menu-item { animation: row-in 80ms }
        .acpmux-mp-refresh-spinner { animation: cmux-spin 900ms linear infinite }`),
    ).toEqual([
      "2 `.ui-popup.acpmux-chat-menu-popover` starts `animation: ui-popup-open 120ms ease-out`",
      "3 `:where(.ui-popup)` starts `animation: ui-popup-fade 120ms`",
      "4 `.ui-popover[data-starting-style]` draws a starting style to enter from",
    ]);
  });

  test("no stylesheet animates a popup or menu in", () => {
    const found: string[] = [];
    for (const file of stylesheets(path.join(WEBVIEWS, "src")))
      for (const entrance of popupEntrances(readFileSync(file, "utf8")))
        found.push(`${path.relative(WEBVIEWS, file)}:${entrance}`);
    expect(found).toEqual([]);
  });
});
