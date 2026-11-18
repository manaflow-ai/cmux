import { describe, expect, test } from "bun:test";
import {
  heroTerminalTheme,
  heroTerminalThemes,
  heroThemeVariables,
} from "../app/[locale]/components/hero-playground-theme";

describe("landing hero theme tokens", () => {
  test("keeps the real Ghostty palettes available to the playground", () => {
    expect(heroTerminalThemes.map((theme) => theme.id)).toEqual([
      "ghostty",
      "catppuccin-mocha",
      "catppuccin-latte",
    ]);
    expect(heroTerminalTheme("catppuccin-mocha").background).toBe("#1e1e2e");
    expect(heroTerminalTheme("catppuccin-latte").palette[4]).toBe("#1e66f5");
  });

  test("derives the same semantic surface names as WebTheme", () => {
    const vars = heroThemeVariables(heroTerminalTheme("catppuccin-mocha"), "dark", 18);
    expect(vars["--cmux-surface-token"]).toBe("#1e1e2e");
    expect(vars["--cmux-terminal-foreground"]).toBe("#cdd6f4");
    expect(vars["--cmux-accent"]).toBe("#89b4fa");
    expect(vars["--cmux-surface-background"]).toContain("color-mix");
  });
});
