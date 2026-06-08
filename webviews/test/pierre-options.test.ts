import { expect, test } from "bun:test";
import { codeViewUnsafeCSS, fileTreeUnsafeCSS } from "../src/pierre-options";

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
