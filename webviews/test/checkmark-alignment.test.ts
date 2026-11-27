import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const WEBVIEWS = join(import.meta.dir, "..");

// Every composer/menu bundle has to center its selection glyph in the row. Keeping this in the
// shared `.ui-menu-check` contract catches the drift that made a checkmark sit on the text's
// baseline in one picker while the other pickers were centered.
test("menu checks use the shared centered row contract", () => {
  for (const file of ["src/agent-session/acpmux/styles.css", "src/ui/ui.css", "src/ui/popupSurface.css"]) {
    const css = readFileSync(join(WEBVIEWS, file), "utf8");
    const rule = css.match(/(?:^|\n)\s*(?::where\()?\.ui-menu-check(?:\))?\s*\{([^}]*)\}/)?.[1] ?? "";
    expect(rule, `${file} must define the shared menu-check rule`).not.toBe("");
    expect(rule, `${file} centers the check on the row`).toMatch(/align-items\s*:\s*center/);
    expect(rule, `${file} removes text-baseline drift`).toMatch(/line-height\s*:\s*1(?:;|\s|$)/);
  }
});
