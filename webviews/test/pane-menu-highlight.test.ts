// The agent pane's menus highlight a row the way the native themed menus do (Palette.menuHighlight,
// NSMenu.themeRows): the theme's accent (ThemeTokens.accent, which the host sends as --agent-accent) as
// a 20% wash, so a label keeps its ink and a neutral theme gets a gray wash. The composer chips' menus
// (reasoning, agent options, Plan's context menu) and every ui/Menu row with no rule of its own (--ui-row)
// draw it; none paints a saturated system blue.
import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";

const acpmux = path.resolve(import.meta.dir, "../src/agent-session/acpmux");
const sheet = (name: string) => fs.readFileSync(path.join(acpmux, name), "utf8");

describe("agent pane menu highlight", () => {
  const styles = sheet("styles.css");

  test("the highlight token is the native themed menu's: the accent at 20%, on :root", () => {
    // :root, not .acpmux-shell or .ui-positioner: the context menu portals into document.body.
    expect(styles).toContain(
      ":root{--acpmux-menu-highlight:color-mix(in srgb,var(--agent-accent,var(--agent-text)) 20%,transparent)}",
    );
  });

  test("ui/Menu rows, the context menu and the reasoning menu draw it", () => {
    expect(styles).toMatch(/\.ui-positioner\{[^}]*--ui-row:var\(--acpmux-menu-highlight\)/);
    expect(styles).toContain(
      ".ui-context-menu .ui-menu-item[data-highlighted]{background:var(--acpmux-menu-highlight);",
    );
    expect(sheet("composerControls.css")).toContain(
      ".ui-menu-item.acpmux-effort-item[data-highlighted] { background: var(--acpmux-menu-highlight); }",
    );
  });

  test("no menu highlight names the system selection color", () => {
    for (const name of ["styles.css", "composerControls.css", "composerLocation.css"])
      for (const rule of sheet(name)
        .replace(/\/\*[\s\S]*?\*\//g, "")
        .match(/[^{}]*\[data-highlighted\][^{}]*\{[^}]*\}/g) ?? []) {
        // Only the declarations, and the system color keywords case-sensitively: the token's own name ends in "highlight".
        const body = rule.slice(rule.indexOf("{"));
        expect(body).not.toMatch(/:[^;]*\b(Highlight|SelectedItem|AccentColor)\b/);
        expect(body).not.toMatch(/#0a84ff|#007aff|system-blue/i);
      }
  });
});
