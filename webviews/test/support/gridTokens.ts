import { readFileSync } from "node:fs";
import path from "node:path";

/** The layout grid's custom properties (the generated `layout-grid` block of pages/shared/desktop.css,
 *  design/grid.md section 6), for a test that loads a surface's own CSS without the page's: a surface
 *  on the grid reads `--grid-*`, and without them its gaps, insets and widths fall back to nothing. */
export function gridTokenCss(): string {
  const css = readFileSync(path.resolve(import.meta.dir, "../../src/pages/shared/desktop.css"), "utf8");
  const start = css.indexOf("/* layout-grid:begin");
  const end = css.indexOf("/* layout-grid:end */");
  if (start < 0 || end < start) throw new Error("pages/shared/desktop.css has no layout-grid block");
  return css.slice(start, end);
}

/** Every top-level `:root { ... }` token block of pages/shared/desktop.css (the `--ds-*`, `--grid-*`,
 *  type and motion tokens), without its element rules, for a browser test that injects a surface's
 *  sheet (New Tab's screen.css, say) on a bare page: without it the tokenised gaps and insets resolve
 *  to nothing (#33751). */
export function designTokenCss(): string {
  const css = readFileSync(path.resolve(import.meta.dir, "../../src/pages/shared/desktop.css"), "utf8");
  const blocks = css.match(/^:root \{[\s\S]*?^\}/gm) ?? [];
  if (blocks.length === 0) throw new Error("pages/shared/desktop.css has no :root token blocks");
  return blocks.join("\n");
}
