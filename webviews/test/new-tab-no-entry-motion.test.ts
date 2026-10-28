// The New Tab has no entry animations (Leo 2026-10-22: "we should basically have no entry
// animations a lot of the time, esp here all over the new tab area... exit animations are ok
// tho."): what it shows or opens appears in the frame it lands in; exits keep their fades, and
// loops and hover colors are not entrances. This reads the sources, so it runs in every lane:
// - stylesheets and components under webviews/src/**/newtab/ declare no entrance: no
//   @starting-style, no finite `animation` outside an exit state, no transition into an open
//   state, no Web Animations fade from opacity 0, no motion `initial`, `data-enter` or enter class;
// - noEntry.css zeroes the shared open tokens under the mark, ships, and every template sets it.
// new-tab-no-entry-menus.test.ts checks the shared surfaces the page opens in Chromium.
import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { paneSheets } from "./support/paneSheets";

const WEBVIEWS = path.resolve(import.meta.dir, "..");
const REPO = path.resolve(WEBVIEWS, "..");
const NO_ENTRY_CSS = "webviews/src/agent-session/acpmux/newtab/noEntry.css";

type Rule = { file: string; line: number; selector: string; decls: [string, string][] };

/// Style rules with their line, and `@starting-style` lines, from one sheet. Comments become spaces
/// (lines stay true); keyframes are judged where they are used, so their blocks drop out.
function parseCss(file: string, source: string): { rules: Rule[]; startingStyles: number[] } {
  const blank = (text: string) => text.replace(/[^\n]/g, " ");
  const text = source
    .replace(/\/\*[\s\S]*?\*\//g, blank)
    .replace(/@(-webkit-)?keyframes[^{]*\{(?:[^{}]*\{[^{}]*\})*[^{}]*\}/g, blank);
  const lineAt = (index: number) => text.slice(0, index).split("\n").length;
  const startingStyles = [...text.matchAll(/@starting-style\b/g)].map((match) => lineAt(match.index));
  // An innermost `selector { declarations }`: an at-rule's head never matches, its rules do.
  const rules = [...text.matchAll(/([^{};]+)\{([^{}]*)\}/g)].map((match) => {
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
  return { rules, startingStyles };
}

/// A state a surface leaves through: its fade out is allowed.
const EXIT_STATE =
  /\[data-ending-style\]|\[data-presence="?leaving|\[data-phase="?landing|\[data-state="?closed|leaving|closing/;
/// A state a surface shows or opens in: a transition into it is an entrance.
const OPEN_STATE =
  /\[data-(shown|open|opened|visible|entering|starting-style|appear)\b[^\]]*\]|\[data-presence="?from"?\]|\[data-state="?open"?\]|\[open\]|:popover-open|\.is-(open|shown|visible|entering)\b/;
const ENTER_CLASS =
  /(^|[\s"'`.])((?:[\w-]+-)?(enter|entering|appear|appearing)|fade-?in|slide-?in|scale-?in|stagger)(?=$|[\s"'`])/;

function declared(rule: Rule, ...names: string[]): string[] {
  return rule.decls.filter(([name]) => names.includes(name)).map(([, value]) => value);
}

/// A finite animation the rule starts (not `none`, not a loop).
function finiteAnimation(rule: Rule): string | undefined {
  const values = declared(rule, "animation", "animation-name");
  const loops = declared(rule, "animation-iteration-count").some((value) => /infinite/.test(value));
  return values.find((value) => !/^none\b/.test(value.trim()) && !/\binfinite\b/.test(value) && !loops);
}

/// Whether a transition duration list can run (a nonzero time or a token).
function runs(value: string): boolean {
  if (/var\(/.test(value)) return true;
  return [...value.matchAll(/(\d*\.?\d+)(ms|s)\b/g)].some((match) => Number(match[1]) > 0);
}

function transitionRuns(rule: Rule): boolean {
  return [...declared(rule, "transition"), ...declared(rule, "transition-duration")].some(
    (value) => !/^none\b/.test(value.trim()) && runs(value),
  );
}

function moves(rule: Rule): boolean {
  return rule.decls.some(
    ([name, value]) =>
      (name === "opacity" && Number.parseFloat(value) < 1) ||
      ((name === "transform" || name === "translate" || name === "scale") && !/^(none|0(px)?( 0(px)?)?)$/.test(value)),
  );
}

function walk(dir: string, keep: (file: string) => boolean): string[] {
  const found: string[] = [];
  for (const name of readdirSync(dir)) {
    const full = path.join(dir, name);
    if (statSync(full).isDirectory()) found.push(...walk(full, keep));
    else if (keep(full)) found.push(full);
  }
  return found;
}

const rel = (file: string) => path.relative(REPO, file);
const read = (file: string) => readFileSync(path.join(REPO, file), "utf8");

/// Every file under webviews/src/**/newtab/, gallery fixtures and tests aside.
const newTabFiles = walk(path.join(WEBVIEWS, "src"), (file) => file.split(path.sep).includes("newtab"))
  .filter((file) => !/\.(gallery|test)\.tsx?$/.test(file))
  .map(rel);

/// Entrance declarations in one stylesheet's rules, as `file:line why`.
function cssEntrances(rules: Rule[]): string[] {
  const found: string[] = [];
  for (const rule of rules) {
    const where = `${rule.file}:${rule.line} \`${rule.selector}\``;
    const animation = finiteAnimation(rule);
    if (animation && !EXIT_STATE.test(rule.selector)) found.push(`${where} starts \`animation: ${animation}\``);
    if (OPEN_STATE.test(rule.selector) && !EXIT_STATE.test(rule.selector)) {
      if (transitionRuns(rule)) found.push(`${where} transitions into an open state`);
      if (/\[data-starting-style\]|\[data-presence="?from/.test(rule.selector) && moves(rule))
        found.push(`${where} draws a starting style to enter from`);
      // An open state with no transition of its own runs its base rule's transition on the way in.
      if (!declared(rule, "transition", "transition-duration").length) {
        const base = rule.selector.replace(OPEN_STATE, "").trim();
        const shows = rule.decls.some(([name]) => ["opacity", "transform", "translate", "scale"].includes(name));
        if (shows && rules.some((other) => other.selector === base && transitionRuns(other)))
          found.push(`${where} fades or moves in on its base rule's transition`);
      }
    }
  }
  return found;
}

describe("the New Tab declares no entry animation", () => {
  test("the walk finds the New Tab's stylesheets and components", () => {
    expect(newTabFiles).toContain("webviews/src/agent-session/acpmux/newtab/screen.css");
    expect(newTabFiles).toContain("webviews/src/agent-session/acpmux/newtab/NewTabScreen.tsx");
    expect(newTabFiles).toContain("webviews/src/agent-session/acpmux/newtab/listMotion.ts");
  });

  test("its stylesheets start no animation or transition on entry", () => {
    const found: string[] = [];
    for (const file of newTabFiles.filter((file) => file.endsWith(".css"))) {
      const { rules, startingStyles } = parseCss(file, read(file));
      for (const line of startingStyles) found.push(`${file}:${line} @starting-style`);
      found.push(...cssEntrances(rules));
    }
    expect(found).toEqual([]);
  });

  test("its components start no fade, slide or enter class on mount", () => {
    const found: string[] = [];
    for (const file of newTabFiles.filter((file) => /\.tsx?$/.test(file))) {
      const source = read(file);
      const lines = source.split("\n");
      const at = (index: number) => source.slice(0, index).split("\n").length;
      // Web Animations: a fade from transparent, or a scale or slide from nothing.
      for (const match of source.matchAll(/\.animate\(\s*\[\s*\{([^}]*)\}/g)) {
        if (/opacity:\s*0(?!\.\d*[1-9])\b|scale\(0|scale:\s*0\b/.test(match[1]))
          found.push(`${file}:${at(match.index)} animates in from \`{${match[1].trim()}}\``);
      }
      for (const [index, line] of lines.entries()) {
        const where = `${file}:${index + 1}`;
        if (/from\s+["'](framer-motion|motion\/react|motion)["']/.test(line))
          found.push(`${where} imports a motion library`);
        if (/<motion\.[^>]*\binitial=/.test(line) || /\binitial=\{\{[^}]*opacity/.test(line))
          found.push(`${where} sets a motion initial state`);
        if (/\bdata-enter=|["']data-enter["']/.test(line)) found.push(`${where} enters from an edge (data-enter)`);
        if (/usePresence\([^)]*appear:\s*true/.test(line)) found.push(`${where} plays a presence entrance on mount`);
        for (const match of line.matchAll(/className=(?:"([^"]*)"|\{[^}]*["'`]([^"'`]*)["'`])/g)) {
          const names = match[1] ?? match[2] ?? "";
          if (ENTER_CLASS.test(` ${names} `)) found.push(`${where} uses an entrance class (${names.trim()})`);
        }
      }
    }
    expect(found).toEqual([]);
  });
});

/// The open tokens noEntry.css sets to 0 while a New Tab shows.
const ZEROED = ["--ui-popup-open", "--tooltip-fade-in", "--ui-enter-duration"];

describe("what the New Tab opens appears at once", () => {
  const noEntry = parseCss(NO_ENTRY_CSS, read(NO_ENTRY_CSS)).rules;

  test("noEntry.css sets every open token to 0 under the New Tab's mark", () => {
    const root = noEntry.find((rule) => rule.selector === ":root[data-new-tab]");
    expect(
      Object.fromEntries(ZEROED.map((token) => [token, root?.decls.find(([name]) => name === token)?.[1]])),
    ).toEqual(Object.fromEntries(ZEROED.map((token) => [token, "0s"])));
  });

  test("noEntry.css ships with the pane and the dev pages", () => {
    // The menu probe consumes this exact list. A separate import or build path cannot stand in
    // for a missing sheet here: the test would render different styles from the shipped pane.
    expect(paneSheets()).toContain(NO_ENTRY_CSS);
    // The hook imports it, so the dev server and the gallery load it with the page.
    expect(read("webviews/src/agent-session/acpmux/newtab/noEntryMotion.ts")).toContain('import "./noEntry.css";');
  });

  test("every New Tab template marks the root while it shows", () => {
    // Every template App.tsx renders for a New Tab: the screen (Default, Minimal, Cards, ...),
    // History, and the classic page.
    for (const screen of ["newtab/NewTabScreen.tsx", "newtab/HistoryScreen.tsx", "NewTabPage.tsx"])
      expect(read(`webviews/src/agent-session/acpmux/${screen}`)).toMatch(/\n\s+useNoEntryMotion\(\);\n/);
  });
});
