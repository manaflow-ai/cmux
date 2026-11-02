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
