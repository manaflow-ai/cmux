// Pierre diff and tree styling for the changes view, after the Codex Changes pane in
// the agent-pane reference prototype (src/changes/theme.ts, diffStyles.ts, treeStyles.ts).
// Colors come from the pane's theme variables (applyAgentTheme), which inherit into
// Pierre's shadow roots; the Codex values are the fallbacks.
import { registerCustomTheme } from "@pierre/diffs";

export const AGENT_DIFF_THEME = "cmux-agent-dark";
export const AGENT_DIFF_THEME_LIGHT = "cmux-agent-light";

/// Codex dark, sampled from its Changes pane.
const codex = {
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

/// The pane's colors, each a theme variable with the Codex value behind it. The diffs sit on
/// the page background, so the changes view is one surface with the transcript. Additions and
/// deletions read `--acpmux-add` and `--acpmux-del` (styles.css), which a theme can set.
const addition = `var(--acpmux-add, ${codex.addition})`;
const deletion = `var(--acpmux-del, ${codex.deletion})`;
export const diffColors = {
  bg: `var(--agent-page-bg, ${codex.bg})`,
  fg: `var(--agent-text, ${codex.fg})`,
  muted: `var(--agent-muted, ${codex.muted})`,
  line: `var(--agent-border, ${codex.line})`,
  selected: `var(--agent-card-hover, ${codex.selected})`,
  addition,
  deletion,
  additionLine: `color-mix(in srgb, ${addition} 20%, transparent)`,
  deletionLine: `color-mix(in srgb, ${deletion} 20%, transparent)`,
  additionGutter: `color-mix(in srgb, ${addition} 10%, transparent)`,
  deletionGutter: `color-mix(in srgb, ${deletion} 10%, transparent)`,
  separator: `var(--agent-control, ${codex.separator})`,
} as const;

/// Syntax colors for Shiki: the terminal's ANSI colors where the host sends them
/// (`--agent-ansi-N`, set by applyAgentTheme), Codex's otherwise. Shiki writes each color
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
  codex.fg,
  syntax({
    fg: codex.fg,
    keyword: codex.link,
    fn: codex.heading,
    string: codex.string,
    number: codex.inlineCode,
    comment: codex.comment,
    added: codex.addition,
    removed: codex.deletion,
    heading: codex.heading,
    link: codex.link,
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
  background: ${c.bg};
}
[data-column-number][data-line-type="change-addition"],
[data-gutter-buffer][data-line-type="change-addition"] { --diffs-line-bg: ${c.additionGutter}; }
[data-column-number][data-line-type="change-deletion"],
[data-gutter-buffer][data-line-type="change-deletion"] { --diffs-line-bg: ${c.deletionGutter}; }
[data-line][data-line-type="change-addition"] { --diffs-line-bg: ${c.additionLine}; }
[data-line][data-line-type="change-deletion"] { --diffs-line-bg: ${c.deletionLine}; }
[data-separator="line-info"] { height: 32px; }
[data-expand-button], [data-separator-content] { color: ${c.muted}; }
[data-separator-content] { font-size: 12px; padding: 0 9px; }
`;

/// Injected into the tree's shadow root: 13px system font, 29px rows, a quiet selection.
export const treeUnsafeCSS = /* css */ `
:host {
  --trees-font-family-override: ${UI};
  --trees-font-size-override: 13px;
  --trees-bg-override: transparent;
  --trees-fg-override: ${c.fg};
  --trees-fg-muted-override: ${c.muted};
  --trees-selected-fg-override: ${c.fg};
  --trees-selected-bg-override: ${c.selected};
  --trees-bg-muted-override: ${c.selected};
  --trees-padding-inline-override: 8px;
  --trees-item-margin-x-override: 0px;
  --trees-item-padding-x-override: 2px;
  --trees-border-radius-override: 6px;
  --trees-focus-ring-width-override: 0px;
  --trees-indent-guide-bg-override: ${c.line};
}
[data-type="item"][data-item-focused="true"]::before { display: none; }
[data-item-section="decoration"] { font-size: 12px; }
`;
