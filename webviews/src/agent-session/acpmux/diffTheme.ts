// Pierre diff and tree styling for the changes view, after the Codex Changes pane in
// manaflow-ai/codex-atlas-clone (src/changes/theme.ts, diffStyles.ts, treeStyles.ts).
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

/// The pane's colors, each a theme variable with the Codex value behind it.
export const diffColors = {
  bg: `var(--agent-surface-elevated, ${codex.bg})`,
  fg: `var(--agent-text, ${codex.fg})`,
  muted: `var(--agent-muted, ${codex.muted})`,
  line: `var(--agent-border, ${codex.line})`,
  selected: `var(--agent-card-hover, ${codex.selected})`,
  addition: codex.addition,
  deletion: codex.deletion,
  additionLine: `color-mix(in srgb, ${codex.addition} 22%, transparent)`,
  deletionLine: `color-mix(in srgb, ${codex.deletion} 22%, transparent)`,
  additionGutter: `color-mix(in srgb, ${codex.addition} 10%, transparent)`,
  deletionGutter: `color-mix(in srgb, ${codex.deletion} 10%, transparent)`,
  separator: `var(--agent-control, ${codex.separator})`,
} as const;

/// Syntax colors for Shiki. Shiki needs literal colors; the background is transparent so
/// the themed background shows through.
const theme = {
  name: AGENT_DIFF_THEME,
  type: "dark",
  colors: { "editor.background": "#00000000", "editor.foreground": codex.fg },
  fg: codex.fg,
  bg: "#00000000",
  tokenColors: [
    { settings: { foreground: codex.fg } },
    {
      scope: ["markup.heading", "entity.name.section.markdown", "punctuation.definition.heading.markdown"],
      settings: { foreground: codex.heading, fontStyle: "bold" },
    },
    { scope: ["markup.inline.raw", "markup.inline.raw.string.markdown"], settings: { foreground: codex.inlineCode } },
    { scope: ["markup.underline.link", "string.other.link.title.markdown"], settings: { foreground: codex.link } },
    { scope: ["comment", "punctuation.definition.comment"], settings: { foreground: codex.comment } },
    { scope: ["string", "string.quoted"], settings: { foreground: codex.string } },
    { scope: ["keyword", "storage", "keyword.control"], settings: { foreground: codex.link } },
    { scope: ["variable.other", "variable.parameter"], settings: { foreground: codex.inlineCode } },
    { scope: ["constant.numeric", "constant.language"], settings: { foreground: codex.inlineCode } },
    { scope: ["support.function", "entity.name.function"], settings: { foreground: codex.heading } },
  ],
};

/// The same scopes in darker colors for a light pane.
const light = {
  ...theme,
  name: AGENT_DIFF_THEME_LIGHT,
  type: "light",
  colors: { "editor.background": "#00000000", "editor.foreground": "#24292f" },
  fg: "#24292f",
  tokenColors: theme.tokenColors.map((rule) => ({
    ...rule,
    settings: {
      ...rule.settings,
      foreground:
        (
          {
            [codex.fg]: "#24292f",
            [codex.heading]: "#3f7d0f",
            [codex.inlineCode]: "#b35900",
            [codex.link]: "#6f42c1",
            [codex.comment]: "#6e7781",
            [codex.string]: "#0a6b52",
          } as Record<string, string>
        )[rule.settings.foreground] ?? rule.settings.foreground,
    },
  })),
};

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
