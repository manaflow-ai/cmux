// Leo 2026-11-02, on the gray Updated card over his themed sidebar: "why is the update thing
// unthemed". The card's glass mixes from the theme's surface, never from the text color alone, which
// reads as a neutral gray over any theme. Since 2026-11-07 that glass is the composer's material
// (ui/glass/composerMaterial.css), whose surface is the theme's (--cmux-surface-solid, WebTheme).
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const css = readFileSync(new URL("../src/pages/changelog/updateSurfaces.css", import.meta.url), "utf8");
const material = readFileSync(new URL("../src/ui/glass/composerMaterial.css", import.meta.url), "utf8");

test("the Updated card's glass is the composer's material, mixed from the theme's surface", () => {
  const rule = /\.wn-card\.wn-updated \{([^}]*)\}/.exec(css);
  expect(rule).not.toBeNull();
  expect(rule![1]).toContain("background: var(--composer-material-tint)");
  const solid = /--composer-material-solid:([^;]+);/.exec(material)?.[1] ?? "";
  // Both halves (light and dark) start from the theme's surface.
  expect(solid.match(/var\(--cmux-surface-solid/g)?.length).toBe(2);
  expect(solid).not.toContain("--page-text");
});
