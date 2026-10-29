// Popovers and menus open in one frame and fade only as they close (Leo 2026-10-24: "When you open
// it up, no animation. When you close it, animation for closing. That's it, right? ... No fade in.
// Just boom. It's instant. Fade out, yes. No fade in ever for any of these." He was clicking the
// agent chat header's vertical ellipsis, a Base UI Menu: header/ChatHeaderTools.tsx ChatMenu).
// Panels that slide in from an edge, browser and pane motion, dialogs and tooltips are not popovers
// and keep their own motion.
// - Every lane: no stylesheet under webviews/src starts an animation on a popup or menu surface, or
//   draws a starting style for one to enter from (outside its exit state). A popup surface is one of
//   the listed classes, any class named like one (`-menu`, `-popover`, `-popup`, `-dropdown`,
//   `-picker`, `-listbox`), or an ARIA menu or listbox.
// - No component gives a menu or listbox a `data-enter` entrance, and no script fades a popup in
//   with `.animate()`.
// - Palettes are exempt (Leo: "Command palette gets a pass"): the quick-open and jump palettes keep
//   their entrance, and each is named in PALETTES.
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
/// Any other surface named like a popup: a class ending in one of these words, or an ARIA popup role.
const POPUP_SUFFIXES = ["menu", "popover", "popup", "dropdown", "picker", "listbox"];
const POPUP = new RegExp(
  `\\.(${POPUP_CLASSES.join("|")})(?![\\w-])` +
    `|\\.[\\w-]+-(${POPUP_SUFFIXES.join("|")})(?![\\w-])` +
    `|\\[role=["']?(menu|listbox)["']?\\]`,
);
/// Palettes keep their entrance (Leo 2026-10-24: "Command palette gets a pass"). Each is a
/// keyboard-summoned, centered quick-open surface, not a menu a control drops down.
const PALETTES = [
  "acpmux-file-search", // Search files: the chat's quick-open palette (FileSearch.tsx).
  "lg-palette", // the ledger's command palette (home-channels/ledger.css).
  "jump-palette", // the diff viewer's jump-to-file palette (DiffToolbar.tsx).
];
const PALETTE = new RegExp(`\\.(${PALETTES.join("|")})(?![\\w-])`);
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
  return splitTop(selector, /,/).filter((one) => {
    const subject = splitTop(one, /[\s>+~]/).at(-1) ?? "";
    return POPUP.test(subject) && !PALETTE.test(subject);
  });
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

function sources(dir: string, test: (file: string) => boolean): string[] {
  const found: string[] = [];
  for (const name of readdirSync(dir)) {
    const full = path.join(dir, name);
    if (statSync(full).isDirectory()) found.push(...sources(full, test));
    else if (test(full)) found.push(full);
  }
  return found;
}
const stylesheets = (dir: string) => sources(dir, (file) => file.endsWith(".css"));
/// Component and script sources, without tests, galleries and prototypes.
const scripts = (dir: string) =>
  sources(dir, (file) => /\.tsx?$/.test(file) && !/\.(test|gallery)\.tsx?$/.test(file) && !file.includes("/prototypes/"));

/// A JSX element that is a menu or listbox, by role or by a popup-named class, and asks for a
/// `data-enter` entrance (ui/popupSurface.css), as `line why`.
function scriptEntrances(source: string): string[] {
  const found: string[] = [];
  const lineAt = (index: number) => source.slice(0, index).split("\n").length;
  for (const tag of source.matchAll(/<[A-Za-z][\w.]*\b[^<>]*?\bdata-enter\b[^<>]*>/g)) {
    const role = /\brole=["'{]+(menu|listbox)\b/.exec(tag[0]);
    const named = new RegExp(`\\bclassName=["'{\`][^"'}\`]*\\b[\\w-]+-(${POPUP_SUFFIXES.join("|")})(?![\\w-])`).exec(tag[0]);
    if (role || named) found.push(`${lineAt(tag.index)} a ${role ? `role=${role[1]}` : "popup-named"} element enters with data-enter`);
  }
  return found;
}

/// A file named for a menu, popover or picker that fades something in with `.animate()`.
function scriptFadeIns(file: string, source: string): string[] {
  if (!/(menu|popover|popup|picker|dropdown)/i.test(path.basename(file))) return [];
  const lineAt = (index: number) => source.slice(0, index).split("\n").length;
  return [...source.matchAll(/\.animate\(\s*\[\s*\{\s*opacity:\s*0\b/g)].map(
    (match) => `${lineAt(match.index)} fades in with .animate()`,
  );
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

  test("the scan covers popup-named classes and ARIA menus, and passes palettes", () => {
    expect(
      popupEntrances(`
        .nt-edit-add-menu { animation: ui-enter 120ms both }
        .file-tree-context-menu { animation: ui-enter 120ms both }
        .model-dropdown, .color-picker { animation: ui-enter 120ms both }
        [role=listbox] { animation: ui-enter 120ms both }
        .acpmux-file-search { animation: ui-enter 120ms both }
        .lg-palette { animation: ui-enter 120ms both }
        .nt-edit-add-menu-item { animation: row-in 80ms }`),
    ).toEqual([
      "2 `.nt-edit-add-menu` starts `animation: ui-enter 120ms both`",
      "3 `.file-tree-context-menu` starts `animation: ui-enter 120ms both`",
      "4 `.model-dropdown, .color-picker` starts `animation: ui-enter 120ms both`",
      "5 `[role=listbox]` starts `animation: ui-enter 120ms both`",
    ]);
  });

  test("the script scan catches a menu that enters, and passes a panel that does", () => {
    expect(
      scriptEntrances(`
        <div role="menu" data-enter="top">
        <ul className="nt-add-popover" data-enter="bottom">
        <section className="acpmux-inspector" data-enter="right">`),
    ).toEqual(["2 a role=menu element enters with data-enter", "3 a popup-named element enters with data-enter"]);
    expect(scriptFadeIns("src/ui/ModelMenu.tsx", "el.animate([{ opacity: 0 }, { opacity: 1 }], 80)")).toEqual([
      "1 fades in with .animate()",
    ]);
    expect(scriptFadeIns("src/ui/ModelMenu.tsx", "el.animate([{ opacity: 1 }, { opacity: 0 }], 80)")).toEqual([]);
  });

  test("no component or script animates a popup or menu in", () => {
    const found: string[] = [];
    for (const file of scripts(path.join(WEBVIEWS, "src"))) {
      const source = readFileSync(file, "utf8");
      for (const entrance of [...scriptEntrances(source), ...scriptFadeIns(file, source)])
        found.push(`${path.relative(WEBVIEWS, file)}:${entrance}`);
    }
    expect(found).toEqual([]);
  });

  test("every exempt palette is still drawn by a stylesheet", () => {
    const css = stylesheets(path.join(WEBVIEWS, "src")).map((file) => readFileSync(file, "utf8")).join("\n");
    expect(PALETTES.filter((name) => !new RegExp(`\\.${name}(?![\\w-])`).test(css))).toEqual([]);
  });

  test("no stylesheet animates a popup or menu in", () => {
    const found: string[] = [];
    for (const file of stylesheets(path.join(WEBVIEWS, "src")))
      for (const entrance of popupEntrances(readFileSync(file, "utf8")))
        found.push(`${path.relative(WEBVIEWS, file)}:${entrance}`);
    expect(found).toEqual([]);
  });
});
