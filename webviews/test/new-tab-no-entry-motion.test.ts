// The New Tab has no entry animations (Leo 2026-10-22: "we should basically have no entry
// animations a lot of the time, esp here all over the new tab area... exit animations are ok
// tho."). Its cards, project picker, composer, suggestion rows and the menus, popovers and hover
// cards it opens appear in the frame they land in; exits keep their fades, and loops (a spinner,
// the playing bars, the edit-mode wiggle) and hover colors are not entrances.
//
// This reads the sources, so it runs in every lane:
// - every stylesheet and component under webviews/src/**/newtab/ declares no entrance: no
//   @starting-style, no finite `animation` outside an exit state, no transition on an open state
//   (`[data-shown]`, `[data-open]`, `[data-starting-style]`, ...), no Web Animations fade from
//   opacity 0, no framer-motion `initial`, no `data-enter` or enter / appear classes;
// - the shared popup surfaces the page opens (they portal outside it, to the pane's root or the
//   body) open on tokens newtab/noEntry.css sets to 0 while a New Tab shows, or noEntry.css names
//   them, and that sheet ships in the pane's bundle and the dev pages;
// - both New Tab screens set the mark that sheet keys on.
// new-tab-no-entry-menus.test.ts checks the same surfaces in Chromium.
import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { importedSheetsShip, paneSheets } from "./support/paneSheets";

const WEBVIEWS = path.resolve(import.meta.dir, "..");
const REPO = path.resolve(WEBVIEWS, "..");
const NO_ENTRY_CSS = "webviews/src/agent-session/acpmux/newtab/noEntry.css";

type Rule = { file: string; line: number; context: string[]; selector: string; decls: [string, string][] };

/// Comments become spaces (newlines kept), so rule lines stay true.
function stripComments(text: string): string {
  return text.replace(/\/\*[\s\S]*?\*\//g, (comment) => comment.replace(/[^\n]/g, " "));
}

function splitTopLevel(text: string, separator: string): string[] {
  const parts: string[] = [];
  let depth = 0;
  let quote = "";
  let start = 0;
  for (let index = 0; index < text.length; index++) {
    const char = text[index];
    if (quote) {
      if (char === quote) quote = "";
    } else if (char === '"' || char === "'") quote = char;
    else if (char === "(" || char === "[") depth++;
    else if (char === ")" || char === "]") depth--;
    else if (char === separator && depth === 0) {
      parts.push(text.slice(start, index));
      start = index + 1;
    }
  }
  parts.push(text.slice(start));
  return parts;
}

/// Style rules with their at-rule context and line, and `@starting-style` blocks, from one sheet.
function parseCss(file: string, source: string): { rules: Rule[]; startingStyles: number[] } {
  const text = stripComments(source);
  const rules: Rule[] = [];
  const startingStyles: number[] = [];
  const context: string[] = [];
  let prelude = "";
  let preludeAt = 0;
  const lineOf = (index: number) => text.slice(0, index).split("\n").length;
  for (let index = 0; index < text.length; index++) {
    const char = text[index];
    if (char === "{") {
      const head = prelude.trim();
      const at = lineOf(preludeAt + (prelude.length - prelude.trimStart().length));
      prelude = "";
      if (/^@(keyframes|-webkit-keyframes|font-face|property|page)\b/.test(head)) {
        // Skip the whole block: keyframes are judged where they are used.
        let depth = 1;
        while (depth > 0 && ++index < text.length) {
          if (text[index] === "{") depth++;
          else if (text[index] === "}") depth--;
        }
        preludeAt = index + 1;
        continue;
      }
      if (head.startsWith("@")) {
        if (/^@starting-style\b/.test(head)) startingStyles.push(at);
        context.push(head);
        preludeAt = index + 1;
        continue;
      }
      const close = text.indexOf("}", index);
      const body = text.slice(index + 1, close);
      const decls = splitTopLevel(body, ";")
        .map((part) => part.trim())
        .filter(Boolean)
        .map((part) => {
          const colon = part.indexOf(":");
          return [part.slice(0, colon).trim().toLowerCase(), part.slice(colon + 1).trim()] as [string, string];
        });
      rules.push({ file, line: at, context: [...context], selector: head.replace(/\s+/g, " "), decls });
      index = close;
      preludeAt = close + 1;
    } else if (char === "}") {
      context.pop();
      prelude = "";
      preludeAt = index + 1;
    } else if (char === ";" && prelude.trim().startsWith("@")) {
      prelude = "";
      preludeAt = index + 1;
    } else {
      if (!prelude) preludeAt = index;
      prelude += char;
    }
  }
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

/// The shared surfaces a New Tab opens: menus, selects, popovers, context menus, the composer's
/// pickers, tooltips and hover cards, dialogs, the drop sheet, and anything entering from an edge.
const SURFACE =
  /\.(ui-popup|ui-menu|ui-popover|ui-context-menu|ui-select-popup|ui-combobox-popup|ui-tooltip|ui-title-tooltip|ui-card|ui-hint|ui-dialog|ui-backdrop|ui-sheet|acpmux-menu|acpmux-slash-menu|acpmux-mp|acpmux-context-pop|acpmux-access-menu|acpmux-file-menu-list|acpmux-effort-track|acpmux-drop-sheet|acpmux-drop-pill|nt-[\w-]+)(?![\w-])|\[data-enter|\[data-presence/g;
/// The surfaces a selector draws (one it only excludes, in `:not(...)`, is not one).
const surfacesOf = (selector: string) =>
  [...selector.replace(/:not\([^)]*\)/g, "").matchAll(SURFACE)].map((match) => match[0]);
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
    // Listed for the page, or shipped at its import once the page's sheets come from imports.
    expect(paneSheets().includes(NO_ENTRY_CSS) || importedSheetsShip()).toBe(true);
    // The hook imports it, so the dev server and the gallery load it with the page.
    expect(read("webviews/src/agent-session/acpmux/newtab/noEntryMotion.ts")).toContain('import "./noEntry.css";');
  });

  test("both New Tab screens mark the root while they show", () => {
    for (const screen of ["NewTabScreen.tsx", "HistoryScreen.tsx"])
      expect(read(`webviews/src/agent-session/acpmux/newtab/${screen}`)).toMatch(/\n\s+useNoEntryMotion\(\);\n/);
  });

  test("every shared surface it opens enters on a zeroed token or is stopped by name", () => {
    const stopped = new Set(
      noEntry
        .filter((rule) => declared(rule, "animation").some((value) => value === "none"))
        .flatMap((rule) => surfacesOf(rule.selector)),
    );
    const zeroed = (value: string) => ZEROED.some((token) => value.includes(`var(${token}`));
    const found: string[] = [];
    const sheets = paneSheets().filter((file) => file !== NO_ENTRY_CSS);
    // The walk reads the shared surfaces' sheets: an empty list would pass on nothing.
    expect(sheets).toContain("webviews/src/ui/popupSurface.css");
    for (const file of sheets) {
      const { rules } = parseCss(file, read(file));
      const enteringFrom = new Set(
        rules
          .filter((rule) => /\[data-starting-style\]|\[data-presence="?from/.test(rule.selector) && moves(rule))
          .flatMap((rule) => surfacesOf(rule.selector)),
      );
      for (const rule of rules) {
        const surfaces = surfacesOf(rule.selector);
        if (!surfaces.length || EXIT_STATE.test(rule.selector)) continue;
        const where = `${file}:${rule.line} \`${rule.selector}\``;
        const animation = finiteAnimation(rule);
        if (animation && !zeroed(animation) && !surfaces.some((surface) => stopped.has(surface)))
          found.push(`${where} opens with \`animation: ${animation}\``);
        if (!surfaces.some((surface) => enteringFrom.has(surface))) continue;
        // A surface that enters from a starting style fades in on its base transition.
        const parts = [
          ...declared(rule, "transition")
            .flatMap((value) => splitTopLevel(value, ","))
            .filter((part) => /^(opacity|translate|transform|scale|all)\b/.test(part.trim())),
          ...declared(rule, "transition-duration"),
        ];
        for (const part of parts)
          if (runs(part) && !zeroed(part)) found.push(`${where} fades in on \`${part.trim()}\``);
      }
    }
    expect(found).toEqual([]);
  });
});
