// Pierre diff and tree styling for the changes view, ported from
// the agent-pane reference prototype (src/changes/theme.ts, diffStyles.ts, treeStyles.ts).
// Colors come from the pane's theme variables (applyAgentTheme), which inherit into
// Pierre's shadow roots; the dark values below are the fallbacks.
import { registerCustomTheme } from "@pierre/diffs";
import { PIERRE_DIFFS_SCROLLER_CSS, PIERRE_TREES_SCROLLER_CSS } from "../../scrollers";

export const AGENT_DIFF_THEME = "cmux-agent-dark";
export const AGENT_DIFF_THEME_LIGHT = "cmux-agent-light";

/// Dark fallback colors, used when the host sends no theme.
const fallbackDark = {
  bg: "#272823",
  fg: "#f8f8f3",
  muted: "#a8a9a3",
  heading: "#b3e053",
  inlineCode: "#ef9c40",
  link: "#a783f7",
  string: "#e4db82",
  comment: "#8f908a",
  addition: "#90b345",
  deletion: "#b4365e",
  additionLine: "#3b412a",
  deletionLine: "#422e2e",
  additionGutter: "#1a1d10",
  deletionGutter: "#1f1113",
  separator: "#43443f",
  line: "#383934",
  selected: "#32332d",
} as const;

/// The pane's colors, each a theme variable with a dark fallback behind it. The diffs sit on
/// the page background, so the changes view is one surface with the transcript. Additions and
/// deletions read `--acpmux-add` and `--acpmux-del` (styles.css), which a theme can set.
const addition = `var(--acpmux-add, ${fallbackDark.addition})`;
const deletion = `var(--acpmux-del, ${fallbackDark.deletion})`;
export const diffColors = {
  bg: `var(--agent-page-bg, ${fallbackDark.bg})`,
  fg: `var(--agent-text, ${fallbackDark.fg})`,
  muted: `var(--agent-muted, ${fallbackDark.muted})`,
  line: `var(--agent-border, ${fallbackDark.line})`,
  selected: `var(--agent-card-hover, ${fallbackDark.selected})`,
  addition,
  deletion,
  additionLine: `color-mix(in srgb, ${addition} 20%, transparent)`,
  deletionLine: `color-mix(in srgb, ${deletion} 20%, transparent)`,
  additionGutter: `color-mix(in srgb, ${addition} 10%, transparent)`,
  deletionGutter: `color-mix(in srgb, ${deletion} 10%, transparent)`,
  separator: `var(--agent-control, ${fallbackDark.separator})`,
} as const;

/// Syntax colors for Shiki: the terminal's ANSI colors where the host sends them
/// (`--agent-ansi-N`, set by applyAgentTheme), the dark fallbacks otherwise. Shiki writes each color
/// into the token's inline style, so a CSS variable resolves against the page's theme.
/// The background is transparent so the themed background shows through.
type Syntax = Record<
  "fg" | "keyword" | "fn" | "string" | "number" | "comment" | "added" | "removed" | "heading" | "link",
  string
>;
const syntax = (fallback: Syntax): Syntax => ({
  fg: `var(--agent-text, ${fallback.fg})`,
  keyword: `var(--agent-ansi-5, ${fallback.keyword})`,
  fn: `var(--agent-ansi-4, ${fallback.fn})`,
  string: `var(--agent-ansi-2, ${fallback.string})`,
  number: `var(--agent-ansi-3, ${fallback.number})`,
  comment: `var(--agent-soft, ${fallback.comment})`,
  added: `var(--agent-ansi-2, ${fallback.added})`,
  removed: `var(--agent-ansi-1, ${fallback.removed})`,
  heading: `var(--agent-ansi-4, ${fallback.heading})`,
  link: `var(--agent-ansi-5, ${fallback.link})`,
});

function shikiTheme(name: string, type: "dark" | "light", fallbackFg: string, color: Syntax) {
  return {
    name,
    type,
    colors: { "editor.background": "#00000000", "editor.foreground": fallbackFg },
    fg: fallbackFg,
    bg: "#00000000",
    tokenColors: [
      { settings: { foreground: color.fg } },
      {
        scope: ["markup.heading", "entity.name.section.markdown", "punctuation.definition.heading.markdown"],
        settings: { foreground: color.heading, fontStyle: "bold" },
      },
      { scope: ["markup.inline.raw", "markup.inline.raw.string.markdown"], settings: { foreground: color.number } },
      { scope: ["markup.underline.link", "string.other.link.title.markdown"], settings: { foreground: color.link } },
      { scope: ["comment", "punctuation.definition.comment"], settings: { foreground: color.comment } },
      { scope: ["string", "string.quoted"], settings: { foreground: color.string } },
      { scope: ["keyword", "storage", "keyword.control"], settings: { foreground: color.keyword } },
      { scope: ["variable.other", "variable.parameter"], settings: { foreground: color.number } },
      { scope: ["constant.numeric", "constant.language"], settings: { foreground: color.number } },
      { scope: ["support.function", "entity.name.function"], settings: { foreground: color.fn } },
      { scope: ["markup.inserted", "punctuation.definition.inserted"], settings: { foreground: color.added } },
      { scope: ["markup.deleted", "punctuation.definition.deleted"], settings: { foreground: color.removed } },
    ],
  };
}

const theme = shikiTheme(
  AGENT_DIFF_THEME,
  "dark",
  fallbackDark.fg,
  syntax({
    fg: fallbackDark.fg,
    keyword: fallbackDark.link,
    fn: fallbackDark.heading,
    string: fallbackDark.string,
    number: fallbackDark.inlineCode,
    comment: fallbackDark.comment,
    added: fallbackDark.addition,
    removed: fallbackDark.deletion,
    heading: fallbackDark.heading,
    link: fallbackDark.link,
  }),
);
/// The same scopes in darker fallbacks for a light pane.
const light = shikiTheme(
  AGENT_DIFF_THEME_LIGHT,
  "light",
  "#24292f",
  syntax({
    fg: "#24292f",
    keyword: "#6f42c1",
    fn: "#3f7d0f",
    string: "#0a6b52",
    number: "#b35900",
    comment: "#6e7781",
    added: "#1a7f37",
    removed: "#cf222e",
    heading: "#3f7d0f",
    link: "#6f42c1",
  }),
);

/// The two syntax themes, for tests.
export const syntaxThemes = { dark: theme, light };

let registered = false;
export function registerAgentDiffTheme() {
  if (registered) return;
  registered = true;
  registerCustomTheme(AGENT_DIFF_THEME, async () => theme as never);
  registerCustomTheme(AGENT_DIFF_THEME_LIGHT, async () => light as never);
}

const c = diffColors;
const MONO = `"SF Mono", SFMono-Regular, ui-monospace, Menlo, monospace`;
const UI = `system-ui, -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif`;

/// Injected into each diff's shadow root: 12px / 21.6px code rows, a 4ch number column,
/// darker gutters on changed rows and quiet "N unmodified lines" rows.
export const diffUnsafeCSS = /* css */ `
:host {
  --diffs-font-family: ${MONO};
  --diffs-header-font-family: ${UI};
  --diffs-font-size: 12px;
  --diffs-line-height: 21.6px;
  --diffs-dark-bg: ${c.bg};
  --diffs-dark: ${c.fg};
  --diffs-light-bg: ${c.bg};
  --diffs-light: ${c.fg};
  --diffs-min-number-column-width: 4ch;
  --diffs-dark-addition-color: ${c.addition};
  --diffs-dark-deletion-color: ${c.deletion};
  --diffs-light-addition-color: ${c.addition};
  --diffs-light-deletion-color: ${c.deletion};
  --diffs-fg-number-override: ${c.muted};
  --diffs-bg-separator-override: ${c.separator};
  --diffs-gap-block: 0px;
  --diffs-bg-addition-emphasis-override: color-mix(in srgb, ${c.addition} 22%, transparent);
  --diffs-bg-deletion-emphasis-override: color-mix(in srgb, ${c.deletion} 22%, transparent);
  background: ${c.bg};
}
[data-column-number][data-line-type="change-addition"],
[data-gutter-buffer][data-line-type="change-addition"] { --diffs-line-bg: ${c.additionGutter}; }
[data-column-number][data-line-type="change-deletion"],
[data-gutter-buffer][data-line-type="change-deletion"] { --diffs-line-bg: ${c.deletionGutter}; }
[data-line][data-line-type="change-addition"] { --diffs-line-bg: ${c.additionLine}; }
[data-line][data-line-type="change-deletion"] { --diffs-line-bg: ${c.deletionLine}; }
[data-separator="line-info"] { height: 32px; }
[data-acpmux-current] { box-shadow: inset 2px 0 0 var(--agent-accent, ${c.fg}); }
[data-expand-button], [data-separator-content] { color: ${c.muted}; }
[data-separator-content] { font-size: 12px; padding: 0 9px; }
${PIERRE_DIFFS_SCROLLER_CSS}`;

/// Injected into the tree's shadow root: 13px system font, 29px rows, a quiet selection.
export const treeUnsafeCSS = /* css */ `
:host {
  --trees-font-family-override: ${UI};
  --trees-font-size-override: 13px;
  --trees-bg-override: transparent;
  --trees-fg-override: ${c.fg};
  --trees-fg-muted-override: ${c.muted};
  --trees-selected-fg-override: ${c.fg};
  --trees-selected-bg-override: color-mix(in srgb, ${c.fg} 10%, transparent);
  --trees-bg-muted-override: color-mix(in srgb, ${c.fg} 5%, transparent);
  --trees-padding-inline-override: 8px;
  --trees-item-margin-x-override: 0px;
  --trees-item-padding-x-override: 2px;
  --trees-border-radius-override: 6px;
  --trees-focus-ring-width-override: 0px;
  --trees-indent-guide-bg-override: ${c.line};
  --trees-status-added-override: ${c.addition};
  --trees-status-deleted-override: ${c.deletion};
}
[data-type="item"][data-item-focused="true"]::before { display: none; }
[data-item-section="decoration"] { font-size: 12px; }
/* Long names (changes/treeTitles.ts): one unclipped line inside the content section, which clips
   it with a fade at its end (no ellipsis, no middle truncation keeping the extension); the counts
   never shrink. --cmux-title-lead is padding left of the first glyph, inside the section, that a
   marquee fades glyphs across; the negative margin keeps the name where Pierre puts it.
   --cmux-title-tail is the gap before the counts, also inside the section, so the fade ends at
   the counts (or the row's end) and the name uses all the room there is. */
[data-type="item"] [data-item-section="content"] {
  flex: 0 1 auto;
  min-width: 0;
  overflow: hidden;
  text-overflow: clip;
  white-space: nowrap;
  margin-inline-start: calc(-1 * var(--cmux-title-lead, 0px));
  padding-inline-start: var(--cmux-title-lead, 0px);
  padding-inline-end: var(--cmux-title-tail, 0px);
}
[data-type="item"] [data-item-section="content"] > * { width: max-content; min-width: max-content; max-width: none; }
[data-type="item"] [data-item-section="content"] [data-truncate-group-container] > div { flex: none; min-width: max-content; }
[data-type="item"] [data-item-section="content"] [data-truncate-container] { overflow: visible; min-width: max-content; }
[data-type="item"] [data-item-section="content"] [data-truncate-grid] { display: block; }
[data-type="item"] [data-item-section="content"] :is([data-truncate-content="overflow"], [data-truncate-marker-cell], [data-truncate-fill]) { display: none; }
[data-type="item"] [data-item-section="content"] [data-truncate-content="visible"] { white-space: pre; }
[data-type="item"] [data-item-section="content"][data-cmux-clipped] {
  -webkit-mask-image: var(--cmux-title-mask);
  mask-image: var(--cmux-title-mask);
}
[data-type="item"] [data-item-section="decoration"] { flex: 0 0 auto; margin-inline-start: auto; }
${PIERRE_TREES_SCROLLER_CSS}`;
