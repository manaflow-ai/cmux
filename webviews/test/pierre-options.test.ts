import { expect, test } from "bun:test";
import {
  codeViewOptions,
  codeViewUnsafeCSS,
  DIFF_FILE_HEADER_HEIGHT,
  fileTreeUnsafeCSS,
  shikiThemeFromGhostty,
  workerHighlighterOptions,
} from "../src/pierre-options";

test("code view CSS paints Pierre surfaces with the one viewer background", () => {
  const css = codeViewUnsafeCSS();

  expect(css).toContain("--diffs-light-bg: var(--cmux-diff-viewer-bg)");
  expect(css).toContain("--diffs-dark-bg: var(--cmux-diff-viewer-bg)");
  expect(css).toContain("--diffs-bg-separator-override: var(--cmux-diff-viewer-bg)");
  expect(css).toContain("--diffs-bg-buffer-override: color-mix(in srgb, var(--cmux-diff-fg) 12%, transparent)");
  expect(css).toContain("--diffs-bg-context-override: transparent");
  expect(css).toContain("--diffs-bg-context-gutter-override: transparent");
  expect(css).toContain("--diffs-bg-addition-override: color-mix");
  expect(css).toContain("--diffs-bg-deletion-override: color-mix");
  expect(css).toContain("[data-separator='line-info'] [data-separator-wrapper]");
  expect(css).toContain("[data-gutter-buffer='buffer']");
  expect(css).toContain("background-image: repeating-linear-gradient(");
});

test("file headers are opaque and sized to the virtualizer's header metric", () => {
  const css = codeViewUnsafeCSS();
  const header = css.match(/\[data-diffs-header\] \{(?<body>[^}]*)\}/)?.groups?.body ?? "";

  expect(header).toContain("background-color: var(--cmux-diff-viewer-bg)");
  expect(header).toContain(`height: var(--cmux-diff-file-header-height, ${DIFF_FILE_HEADER_HEIGHT}px)`);
  expect(css).not.toContain("backdrop-filter");
  expect(css).not.toContain("--cmux-diff-header-bg");
  const options = codeViewOptions(
    {
      collapsed: false,
      diffIndicators: "bars",
      expandUnchanged: false,
      layout: "split",
      lineNumbers: true,
      showBackgrounds: true,
      wordDiffs: false,
      wordWrap: false,
    },
    { theme: { dark: "d", light: "l" } },
  );
  expect(options.itemMetrics?.diffHeaderHeight).toBe(DIFF_FILE_HEADER_HEIGHT);
});

test("file tree surfaces use the viewer background and keep counts tabular", () => {
  const css = fileTreeUnsafeCSS();

  expect(css).toContain("background-color: var(--cmux-diff-viewer-bg)");
  expect(css).toContain("[data-file-tree-sticky-overlay-content]");
  expect(css).toContain("background-color: var(--cmux-diff-viewer-bg) !important");
  expect(css).toContain("font-variant-numeric: tabular-nums");
  expect(css).not.toContain("font-weight");
});

test("Ghostty Shiki theme maps Markdown token scopes", () => {
  const theme = shikiThemeFromGhostty(
    {
      name: "test-dark",
      ghosttyName: "Test Dark",
      type: "dark",
      background: "#101010",
      foreground: "#f0f0f0",
      selectionBackground: "#333333",
      selectionForeground: "#ffffff",
      palette: {
        "1": "#ff453a",
        "2": "#32d74b",
        "3": "#ffd60a",
        "4": "#0a84ff",
        "5": "#bf5af2",
        "6": "#64d2ff",
        "8": "#8e8e93",
        "9": "#ff6961",
        "10": "#63e6be",
        "11": "#ffdf6e",
        "12": "#5ac8fa",
        "13": "#ff9ff3",
        "14": "#7ee7ff",
      },
    },
    { backgroundOpacity: 1 },
  );
  const scopes = theme.tokenColors.flatMap((entry) => entry.scope ?? []);

  expect(scopes).toContain("markup.heading");
  expect(scopes).toContain("markup.bold");
  expect(scopes).toContain("markup.italic");
  expect(scopes).toContain("markup.inline.raw");
  expect(scopes).toContain("markup.underline.link");
  expect(scopes).toContain("punctuation.definition.list");
  expect(scopes).not.toContain("markup.list");
  expect(scopes).toContain("markup.table");
});

test("Ghostty Shiki theme keeps transparent rendering separate from contrast checks", () => {
  const theme = shikiThemeFromGhostty(
    {
      name: "low-contrast-dark",
      ghosttyName: "Low Contrast Dark",
      type: "dark",
      background: "#000000",
      foreground: "#111111",
      palette: { "2": "#111111" },
    },
    { backgroundOpacity: 1 },
  );

  expect(theme.colors["editor.background"]).toBe("transparent");
  expect(theme.colors["terminal.background"]).toBe("transparent");
  expect(theme.colors["editor.foreground"]).toBe("#ffffff");
  expect(theme.colors["terminal.ansiGreen"]).toBe("#ffffff");
  expect(theme.tokenColors[0]?.settings.background).toBe("transparent");
});

test("worker highlighter options carry preloaded diff languages", () => {
  const options = workerHighlighterOptions(
    {
      collapsed: false,
      diffIndicators: "bars",
      expandUnchanged: false,
      layout: "unified",
      lineNumbers: true,
      showBackgrounds: true,
      wordDiffs: false,
      wordWrap: false,
    },
    {},
    ["text", "markdown", "swift"],
  );

  expect(options.langs).toEqual(["text", "markdown", "swift"]);
});
