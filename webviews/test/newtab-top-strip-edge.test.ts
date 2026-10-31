// The New Tab's top strip variants (Debug Settings `data-top-strip` plain and tray) put the project and
// machine strip's leading icon on the + glyph's left edge. The + button stands --nt-composer-inset off
// the box (newtab/screen.css, derived from the font-scaled row), so the strip's edge is derived from the
// same inset (the 18 px glyph sits 5 px into its 28 px button), never a fixed px that matched only the
// old 18 px inset.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const css = readFileSync(join(import.meta.dir, "../src/agent-session/acpmux/composerLocation.css"), "utf8");

for (const variant of ["plain", "tray"]) {
  test(`${variant}: the New Tab strip edge follows the composer inset`, () => {
    const rule = css.match(new RegExp(`:root\\[data-top-strip="${variant}"\\] \\.nt-composer \\{([^}]*)\\}`));
    expect(rule).not.toBeNull();
    expect(rule![1]).toMatch(/--acpmux-top-strip-edge:\s*calc\(var\(--nt-composer-inset\) \+ 5px\);/);
  });
}
