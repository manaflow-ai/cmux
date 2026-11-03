// Leo 2026-11-02, on the gray Updated card over his themed sidebar: "why is the update thing
// unthemed". The card's plain glass mixes from the theme's surface (--glass-surface, WebTheme's page
// color), at the card veil's share, as the sidebar draws it natively (CardSurfaceView.takesThemeTint),
// never from the text color, which reads as a neutral gray over any theme.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const css = readFileSync(new URL("../src/pages/changelog/updateSurfaces.css", import.meta.url), "utf8");

test("the Updated card's plain glass is the theme's surface, not a gray from the text color", () => {
  const rule =
    /:root:not\(\[data-glass="lens"\], \[data-glass="spectrum"\]\):not\(\[data-reduce-transparency\]\) \.wn-card \{([^}]*)\}/.exec(
      css,
    );
  expect(rule).not.toBeNull();
  const tint = /--glass-tint:\s*([^;]+);/.exec(rule![1]!)?.[1] ?? "";
  expect(tint).toContain("var(--glass-surface)");
  expect(tint).not.toContain("--page-text");
});
