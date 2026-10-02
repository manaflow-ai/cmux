// Codex dark diff theme for @pierre/diffs. Colors sampled from
// reference/screenshots/chatgpt/manual-changes-current.png.
import { registerCustomTheme } from "@pierre/diffs";

export const CODEX_DIFF_THEME = "codex-dark";

export const codexColors = {
  bg: "#272823",
  fg: "#f8f8f3",
  number: "#a8a9a3",
  heading: "#b3e053",
  inlineCode: "#ef9c40",
  link: "#a783f7",
  url: "#e4db82",
  addition: "#90b345",
  deletion: "#b4365e",
  additionLine: "#3b412a",
  deletionLine: "#422e2e",
  additionGutter: "#1a1d10",
  deletionGutter: "#1f1113",
  separatorBg: "#43443f",
  separatorFg: "#a8a9a3",
  scrollbarThumb: "#666762",
} as const;

const c = codexColors;

/** The theme itself, for viewers that extend it (src/app/PaneTabs.tsx). */
export const codexDiffTheme = {
  name: CODEX_DIFF_THEME,
  type: "dark",
  colors: {
    "editor.background": c.bg,
    "editor.foreground": c.fg,
  },
  fg: c.fg,
  bg: c.bg,
  tokenColors: [
    { settings: { foreground: c.fg, background: c.bg } },
    {
      scope: [
        "markup.heading",
        "entity.name.section.markdown",
        "punctuation.definition.heading.markdown",
        "markup.heading.markdown",
      ],
      settings: { foreground: c.heading, fontStyle: "bold" },
    },
    {
      scope: [
        "punctuation.definition.list.begin.markdown",
        "markup.list.unnumbered.markdown punctuation",
      ],
      settings: { foreground: c.heading },
    },
    {
      scope: ["string.other.link.title.markdown", "string.other.link.description.markdown"],
      settings: { foreground: c.link },
    },
    {
      scope: ["markup.underline.link.markdown", "markup.underline.link"],
      settings: { foreground: c.url },
    },
    {
      scope: [
        "markup.inline.raw.string.markdown",
        "markup.inline.raw",
        "punctuation.definition.raw.markdown",
      ],
      settings: { foreground: c.inlineCode },
    },
    {
      scope: ["punctuation.definition.link", "punctuation.definition.metadata.markdown"],
      settings: { foreground: c.fg },
    },
    { scope: ["comment", "punctuation.definition.comment"], settings: { foreground: "#8f908a" } },
    { scope: ["string", "string.quoted"], settings: { foreground: c.url } },
    { scope: ["keyword", "storage", "keyword.control"], settings: { foreground: c.link } },
    { scope: ["variable.other", "variable.parameter"], settings: { foreground: c.inlineCode } },
    { scope: ["constant.numeric", "constant.language"], settings: { foreground: c.inlineCode } },
    { scope: ["support.function", "entity.name.function"], settings: { foreground: c.heading } },
  ],
};

let registered = false;
export function registerCodexDiffTheme() {
  if (registered) return;
  registered = true;
  registerCustomTheme(CODEX_DIFF_THEME, async () => codexDiffTheme as never);
}
