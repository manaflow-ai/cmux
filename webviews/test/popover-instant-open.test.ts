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
// - Every `data-enter` entrance (ENTRANCES) and every Web Animations call (WEB_ANIMATIONS) under
//   webviews/src is a listed non-popup surface, so a menu cannot enter from script.
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
    `|\\[\\s*role\\s*[~|^$*]?=\\s*["']?(menu|listbox)["']?(\\s+[is])?\\s*\\]`,
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
    // Each animation in a comma list on its own (`none, ui-enter 120ms` still runs ui-enter), with
    // the iteration count at its index (CSS repeats a shorter count list): a looping spinner is not
    // an entrance, the finite animation beside it is.
    const counts = values("animation-iteration-count").flatMap((value) => splitTop(value, /,/));
    const loops = (index: number) => counts.length > 0 && /infinite/.test(counts[index % counts.length]);
    const animation = values("animation", "animation-name")
      .flatMap((value) => splitTop(value, /,/))
      .find((value, index) => !/^none\b/.test(value) && !/\binfinite\b/.test(value) && !loops(index));
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
  sources(
    dir,
    (file) => /\.tsx?$/.test(file) && !/\.(test|gallery)\.tsx?$/.test(file) && !file.includes("/prototypes/"),
  );

/// Every script that gives an element a `data-enter` entrance (ui/popupSurface.css), directly
/// (`data-enter=`, `"data-enter":`) or through `usePresence(`, with the count and what enters.
/// None of them is a popup or menu: they are banners, side panels and arriving rows. A new
/// entrance anywhere under webviews/src fails until it is listed here, so a menu cannot be given
/// one whatever shape its JSX takes.
const ENTRANCES: Record<string, { count: number; what: string }> = {
  "src/agent-session/acpmux/App.tsx": { count: 1, what: "the hand-off error line under the header" },
  "src/agent-session/acpmux/DiffPanel.tsx": { count: 1, what: "the diff side panel, from the right" },
  "src/agent-session/acpmux/Inspector.tsx": { count: 1, what: "the event inspector side panel, from the right" },
  "src/agent-session/acpmux/LiveChatChoice.tsx": { count: 1, what: "a banner at the top of the chat" },
  "src/agent-session/acpmux/MissingChat.tsx": { count: 1, what: "a banner at the top of the chat" },
  "src/agent-session/acpmux/PeerCopyBanner.tsx": { count: 3, what: "a banner at the top of the chat" },
  "src/agent-session/acpmux/WatchBanner.tsx": { count: 1, what: "a banner at the top of the chat" },
  "src/agent-session/acpmux/conversation/ArtifactPanel.tsx": { count: 1, what: "the artifact side panel" },
  "src/agent-session/acpmux/session-info/SessionInfo.tsx": { count: 1, what: "the Session Info side panel" },
  "src/agent-session/acpmux/session-info/TasksSection.tsx": { count: 1, what: "an arriving task row" },
  "src/agent-session/acpmux/subagents/SubagentTray.tsx": { count: 1, what: "an arriving subagent row" },
  "src/agent-session/acpmux/summary/SummaryCard.tsx": { count: 1, what: "the summary side panel" },
  "src/agent-session/acpmux/summary/SummaryTasks.tsx": { count: 1, what: "an arriving task row" },
  "src/pages/settings/components/ReadOnlyBanner.tsx": { count: 1, what: "a banner at the top of Settings" },
  "src/ui/presence.ts": { count: 3, what: "usePresence itself (its declaration, props type and value)" },
};

/// How many entrances a script asks for: `data-enter` attributes or keys, and `usePresence(` calls.
const entranceCalls = (source: string) => source.match(/\bdata-enter\b["']?\s*[=:]|\busePresence\s*\(/g)?.length ?? 0;

/// Every script that drives the Web Animations API (`.animate(`, `new KeyframeEffect(`), with its
/// call count and what it animates. None of them is a popup or menu. A new call anywhere under
/// webviews/src fails until it is listed here, so a popup cannot fade in from script, however its
/// keyframes are built.
const WEB_ANIMATIONS: Record<string, { count: number; what: string }> = {
  "src/agent-session/acpmux/App.tsx": {
    count: 2,
    what: "a cold-opened chat's transcript fades in; a bottom tool fold moves the transcript as one stack",
  },
  "src/agent-session/acpmux/chatSwitch.ts": {
    count: 1,
    what: "a chat switch: the transcript's rows, the title and Session Info move in (an opt-in experiment)",
  },
  "src/agent-session/acpmux/changes/treeMotionDom.ts": { count: 4, what: "the changes tree's rows move and tint" },
  "src/agent-session/acpmux/changes/treeTitles.ts": { count: 2, what: "a long tree title's marquee" },
  "src/agent-session/acpmux/conversation/PromptText.tsx": { count: 3, what: "a prompt bubble resizes" },
  "src/agent-session/acpmux/conversation/fold.ts": { count: 3, what: "a transcript block folds" },
  "src/agent-session/acpmux/conversation/followGlide.ts": {
    count: 1,
    what: "a followed reply eases into each new line",
  },
  "src/agent-session/acpmux/conversation/turnFold.ts": { count: 1, what: "a turn folds" },
  "src/agent-session/acpmux/session-info/SessionInfoGroup.tsx": { count: 1, what: "Session Info sections slide" },
  "src/agent-session/acpmux/newtab/listMotion.ts": { count: 1, what: "New Tab rows move to their new place" },
  "src/agent-session/acpmux/threadMinimap/ThreadMinimap.tsx": { count: 1, what: "the minimap glides" },
  "src/agent-session/acpmux/threadMinimap/scrollMotion.ts": { count: 1, what: "the minimap's scroll bubble" },
  "src/files-panel-motion.ts": { count: 2, what: "the files panel slides in from its edge" },
  "src/motion/SyncTitle.tsx": { count: 3, what: "a title's new text cross-fades" },
  "src/motion/useSyncListMotion.ts": { count: 3, what: "list rows arrive, move and leave" },
};

/// How many times a script drives the Web Animations API.
const webAnimationCalls = (source: string) => source.match(/\.animate\s*\(|\bnew\s+KeyframeEffect\s*\(/g)?.length ?? 0;

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
        [role = "menu"] { animation-name: none, ui-enter }
        .x-popover { animation: spin 1s, ui-enter 120ms; animation-iteration-count: infinite, 1 }
        .acpmux-file-search { animation: ui-enter 120ms both }
        .lg-palette { animation: ui-enter 120ms both }
        .nt-edit-add-menu-item { animation: row-in 80ms }`),
    ).toEqual([
      "2 `.nt-edit-add-menu` starts `animation: ui-enter 120ms both`",
      "3 `.file-tree-context-menu` starts `animation: ui-enter 120ms both`",
      "4 `.model-dropdown, .color-picker` starts `animation: ui-enter 120ms both`",
      "5 `[role=listbox]` starts `animation: ui-enter 120ms both`",
      '6 `[role = "menu"]` starts `animation: ui-enter`',
      "7 `.x-popover` starts `animation: ui-enter 120ms`",
    ]);
  });

  test("the script scans count every entrance and Web Animations call", () => {
    expect(
      entranceCalls(`
        <Menu icon={<Icon />} role="menu" data-enter="top" />
        <div role={isMenu ? "menu" : "dialog"} data-enter = "top">
        return { "data-enter": "bottom" as const, ref };
        const presence = usePresence(shown, "right");
        // data-entered, data-enterable`),
    ).toBe(4);
    expect(webAnimationCalls("a.animate(k, t); b.animate (k); new KeyframeEffect(el, k); c.animated = 1")).toBe(3);
  });

  test("every entrance is a listed non-popup surface", () => {
    const found: Record<string, number> = {};
    for (const file of scripts(path.join(WEBVIEWS, "src"))) {
      const count = entranceCalls(readFileSync(file, "utf8"));
      if (count) found[path.relative(WEBVIEWS, file)] = count;
    }
    expect(found).toEqual(Object.fromEntries(Object.entries(ENTRANCES).map(([file, { count }]) => [file, count])));
  });

  test("every Web Animations call is a listed non-popup surface", () => {
    const found: Record<string, number> = {};
    for (const file of scripts(path.join(WEBVIEWS, "src"))) {
      const count = webAnimationCalls(readFileSync(file, "utf8"));
      if (count) found[path.relative(WEBVIEWS, file)] = count;
    }
    expect(found).toEqual(Object.fromEntries(Object.entries(WEB_ANIMATIONS).map(([file, { count }]) => [file, count])));
  });

  test("every exempt palette is still drawn by a stylesheet", () => {
    const css = stylesheets(path.join(WEBVIEWS, "src"))
      .map((file) => readFileSync(file, "utf8"))
      .join("\n");
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
