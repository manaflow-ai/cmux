import { expect, test } from "bun:test";
import { codeViewUnsafeCSS, fileTreeUnsafeCSS, shikiThemeFromGhostty, workerHighlighterOptions } from "../src/pierre-options";

test("code view CSS gives Pierre diff body surfaces the editor background", () => {
  const css = codeViewUnsafeCSS();

  expect(css).toContain("--diffs-light-bg: var(--cmux-diff-bg)");
  expect(css).toContain("--diffs-dark-bg: var(--cmux-diff-bg)");
  expect(css).toContain("--diffs-bg-buffer-override: color-mix(in srgb, var(--cmux-diff-fg) 12%, transparent)");
  expect(css).toContain("--diffs-bg-context-override: var(--cmux-diff-bg)");
  expect(css).toContain("--diffs-bg-context-gutter-override: var(--cmux-diff-bg)");
  expect(css).toContain("background-color: var(--cmux-diff-bg)");
  expect(css).toContain("--cmux-diff-surface-bg: light-dark(");
  expect(css).toContain("color-mix(in srgb, var(--cmux-diff-bg) 94%, #3e3d32)");
  expect(css).not.toContain("[data-diffs-header][data-sticky]");
  expect(css).toContain("--diffs-bg-addition-override: color-mix");
  expect(css).toContain("--diffs-bg-deletion-override: color-mix");
  expect(css).toContain("[data-diffs-header] {");
  expect(css).toContain("background-color: var(--cmux-diff-surface-bg) !important");
  expect(css).toContain("min-height: 30px");
  expect(css).not.toContain("border-block: 1px solid var(--cmux-diff-border)");
  expect(css).not.toContain("@container sticky-header scroll-state");
  expect(css).toContain("[data-separator='line-info'] {");
  expect(css).toContain("[data-separator='line-info'] [data-separator-wrapper]");
  expect(css).toContain("[data-line-type='change-addition']:where([data-column-number], [data-gutter-buffer])");
  expect(css).toContain("[data-line-type='change-deletion']:where([data-column-number], [data-gutter-buffer])");
  expect(css).toContain("[data-gutter-buffer='buffer']");
  expect(css).toContain("background-image: repeating-linear-gradient(");
  expect(css).not.toContain("[data-line-type='change-addition'] {");
  expect(css).not.toContain("[data-line-type='change-deletion'] {");
});

test("file tree sticky overlays use a non-transparent surface", () => {
  const css = fileTreeUnsafeCSS();

  expect(css).toContain("background-color: var(--cmux-diff-sidebar-bg)");
  expect(css).toContain("[data-file-tree-sticky-overlay-content]");
  expect(css).toContain("background-color: var(--cmux-diff-tree-sticky-bg, var(--cmux-diff-sidebar-bg)) !important");
  expect(css).toContain("box-shadow: 0 1px 0 var(--trees-border-color)");
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
  expect(scopes).toContain("markup.list");
  expect(scopes).toContain("markup.table");
});

test("worker highlighter options carry preloaded diff languages", () => {
  const options = workerHighlighterOptions({
    collapsed: false,
    diffIndicators: "bars",
    expandUnchanged: false,
    layout: "unified",
    lineNumbers: true,
    showBackgrounds: true,
    wordDiffs: false,
    wordWrap: false,
  }, {}, ["text", "markdown", "swift"]);

  expect(options.langs).toEqual(["text", "markdown", "swift"]);
});
