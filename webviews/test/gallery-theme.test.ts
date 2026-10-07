// The gallery paints pages with the app's own theme pipeline: every shipped Ghostty theme parses,
// the token derivation (a port of CmuxTheme ThemeTokens.derive) keeps its contrast guarantees,
// and the inputs the gallery reads from the app's sources (WebTheme.bootstrapScript, the agent
// pane's shipped stylesheet list) are found.
import { describe, expect, test } from "bun:test";
import fs from "node:fs";
import { agentPaneStylesheets, readShippedThemes, readWebThemeBootstrap, THEMES_DIR } from "../dev-server/galleryHost";
import { parseGhosttyTheme } from "../src/gallery/theme/ghostty";
import {
  contrast,
  css,
  deriveTokens,
  GHOSTTY_DEFAULT,
  MINIMUM_MARK_CONTRAST,
  MINIMUM_TEXT_CONTRAST,
  composited,
} from "../src/gallery/theme/tokens";
import { agentPaneTheme, themeInput, themeTokens, webThemePayload } from "../src/gallery/theme/web";

describe("gallery themes", () => {
  test("every shipped Ghostty theme parses with a background, a foreground and 16 colors", () => {
    const files = fs.readdirSync(THEMES_DIR).filter((name) => !name.startsWith("."));
    const themes = readShippedThemes();
    expect(files.length).toBeGreaterThan(500);
    expect(themes.map((theme) => theme.name).sort()).toEqual([...files].sort());
    const gaps = themes.filter((theme) => theme.palette.filter(Boolean).length < 16).map((theme) => theme.name);
    expect(gaps).toEqual([]);
  });

  test("a theme file's keys map to the ThemeBridge inputs", () => {
    const theme = parseGhosttyTheme(
      "Sample",
      "# comment\npalette = 0=#000000\npalette = 4=#3366ff\npalette = 99=#ffffff\nbackground = #1E1E1E\nforeground = ffffff\nselection-background = #3f638b\ncursor-color = #ff0000\n",
    );
    expect(theme?.background).toBe("#1e1e1e");
    expect(theme?.foreground).toBe("#ffffff");
    expect(theme?.palette[4]).toBe("#3366ff");
    expect(theme?.palette.length).toBe(16);
    expect(theme?.selectionBackground).toBe("#3f638b");
    expect(parseGhosttyTheme("Empty", "palette = 0=#000000\n")).toBeNull();
  });

  test("text tokens hold their contrast on the strongest fill, for every shipped theme", () => {
    for (const theme of readShippedThemes()) {
      const tokens = themeTokens(theme);
      const worst = composited(tokens.pressedFill, themeInput(theme).background);
      expect({ theme: theme.name, ok: contrast(tokens.textPrimary, worst) >= MINIMUM_TEXT_CONTRAST - 0.01 }).toEqual({
        theme: theme.name,
        ok: true,
      });
      expect(contrast(tokens.textTertiary, worst)).toBeGreaterThanOrEqual(MINIMUM_MARK_CONTRAST - 0.01);
    }
  });

  test("Ghostty's default theme derives the values CmuxTheme documents", async () => {
    const tokens = deriveTokens(GHOSTTY_DEFAULT);
    expect(tokens.isDark).toBe(true);
    expect(css(tokens.hoverFill)).toBe("rgba(255, 255, 255, 0.06)");
    expect(css(tokens.windowBackground)).toBe("rgba(40, 44, 52, 1.0)");
    expect(tokens.hasThemeAccent).toBe(true);
    const payload = webThemePayload(tokens);
    expect(payload.colorScheme).toBe("dark");
    expect(Object.keys(payload.variables).sort()).toEqual(
      [
        "--cmux-elevated-background",
        "--cmux-hover",
        "--cmux-selection",
        "--cmux-separator",
        "--cmux-surface-background",
        "--cmux-surface-token",
        "--cmux-text",
        "--cmux-text-secondary",
        "--cmux-text-tertiary",
      ].sort(),
    );
    // With the app theme (the stage passes it, as WebTheme does), every --cmux-app-* token too.
    const { APP_THEME_TOKENS, deriveAppTheme } = await import("../src/theme/appTheme");
    const withApp = webThemePayload(tokens, deriveAppTheme(readShippedThemes()[0]!));
    for (const spec of Object.values(APP_THEME_TOKENS))
      expect(withApp.variables[spec.variable]).toMatch(/^#[0-9a-f]{6}$/);
    const pane = agentPaneTheme(tokens, true);
    expect((pane.palette as string[]).length).toBe(16);
    expect(pane.motion).toEqual({ hover: 0.08, focus: 0.1, fadeIn: 0.1, fadeOut: 0.08 });
  });

  test("the app's document-start theme script is read from WebTheme.swift and defines cmuxTheme", () => {
    const script = readWebThemeBootstrap();
    expect(script).toContain("window.cmuxTheme = {");
    expect(script.startsWith("(function () {")).toBe(true);
  });

  test("the agent pane's stylesheets are the build script's, in its order, and all exist", () => {
    const files = agentPaneStylesheets();
    expect(files[0]).toEndWith("pages/shared/desktop.css");
    expect(files[1]).toEndWith("agent-session/shared/styles.css");
    expect(files.some((file) => file.endsWith("acpmux/conversation/conversation.css"))).toBe(true);
    for (const file of files) expect(fs.existsSync(file)).toBe(true);
  });
});
