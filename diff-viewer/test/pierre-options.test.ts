import { expect, test } from "bun:test";
import { codeViewUnsafeCSS } from "../src/pierre-options";

test("code view CSS leaves Pierre diff body surfaces transparent", () => {
  const css = codeViewUnsafeCSS();

  expect(css).toContain("--diffs-light-bg: transparent");
  expect(css).toContain("--diffs-dark-bg: transparent");
  expect(css).toContain("--diffs-bg-context-override: transparent");
  expect(css).toContain("[data-diffs-header][data-sticky]");
  expect(css).toContain("background-color: transparent");
  expect(css).toContain("--diffs-bg-addition-override: color-mix");
  expect(css).toContain("--diffs-bg-deletion-override: color-mix");
});
