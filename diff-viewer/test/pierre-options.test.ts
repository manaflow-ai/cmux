import { expect, test } from "bun:test";
import { codeViewUnsafeCSS, fileTreeUnsafeCSS } from "../src/pierre-options";

test("code view CSS leaves Pierre diff body surfaces transparent", () => {
  const css = codeViewUnsafeCSS();

  expect(css).toContain("--diffs-light-bg: transparent");
  expect(css).toContain("--diffs-dark-bg: transparent");
  expect(css).toContain("--diffs-bg-context-override: transparent");
  expect(css).toContain("--cmux-diff-header-bg: color-mix(in lab, var(--cmux-diff-bg) 92%, var(--cmux-diff-fg))");
  expect(css).not.toContain("[data-diffs-header][data-sticky]");
  expect(css).toContain("--diffs-bg-addition-override: color-mix");
  expect(css).toContain("--diffs-bg-deletion-override: color-mix");
  expect(css).toContain("[data-diffs-header] {");
  expect(css).toContain("background-color: var(--cmux-diff-header-bg) !important");
  expect(css).toContain("border-block: 1px solid var(--cmux-diff-border)");
  expect(css).toContain("[data-separator='line-info'] {");
  expect(css).toContain("[data-separator='line-info'] [data-separator-wrapper]");
  expect(css).not.toContain("[data-line-type='change-addition'] span");
  expect(css).not.toContain("[data-line-type='change-deletion'] span");
});

test("file tree sticky overlays use a non-transparent surface", () => {
  const css = fileTreeUnsafeCSS();

  expect(css).toContain("[data-file-tree-sticky-overlay-content]");
  expect(css).toContain("background-color: var(--cmux-diff-tree-sticky-bg, color-mix(in lab, var(--cmux-diff-bg) 92%, var(--cmux-diff-fg))) !important");
  expect(css).toContain("box-shadow: 0 1px 0 var(--trees-border-color)");
});
