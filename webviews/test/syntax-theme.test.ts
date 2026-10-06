import { expect, test } from "bun:test";
import { shikiThemeFromGhostty } from "../src/pierre-options";

// Diff viewer syntax colors come from the terminal palette. Before the fix every token rule fell
// back to the foreground when the host sent no palette (the dev host, any host without a Ghostty
// theme), and a palette color under 4.5:1 also became the foreground: no visible highlighting.

function luminance(hex: string): number {
  const [r, g, b] = [1, 3, 5].map((i) => Number.parseInt(hex.slice(i, i + 2), 16) / 255);
  const c = (v: number) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
  return 0.2126 * c(r) + 0.7152 * c(g) + 0.0722 * c(b);
}
function contrast(a: string, b: string): number {
  const [x, y] = [luminance(a), luminance(b)].sort((p, q) => q - p);
  return (x + 0.05) / (y + 0.05);
}
const build = (palette: Record<string, string>, type: string, background: string, foreground: string) =>
  shikiThemeFromGhostty({ name: "t", type, background, foreground, palette }, { backgroundOpacity: 1 });
const colorFor = (theme: ReturnType<typeof build>, scope: string): string =>
  (theme.tokenColors as Array<{ scope?: string[]; settings: { foreground?: string } }>)
    .find((rule) => rule.scope?.includes(scope))!
    .settings.foreground!.toLowerCase();

test("a host without a palette still gets distinct syntax colors, in light and dark", () => {
  for (const [type, background, foreground] of [
    ["dark", "#000000", "#ffffff"],
    ["light", "#ffffff", "#000000"],
  ]) {
    const theme = build({}, type, background, foreground);
    const colors = ["keyword", "string", "entity.name.function", "comment"].map((scope) => colorFor(theme, scope));
    expect(colors).not.toContain(foreground);
    expect(new Set(colors).size).toBe(colors.length);
    for (const color of colors) expect(contrast(color, background)).toBeGreaterThanOrEqual(3);
  }
});

test("a low-contrast palette color keeps its hue instead of becoming the foreground", () => {
  // Ghostty's default dark palette on its #1e1e1e background: magenta, blue and bright black
  // are all under 4.5:1.
  const theme = build({ "4": "#0869cb", "5": "#9647bf", "8": "#464646" }, "dark", "#1e1e1e", "#ffffff");
  for (const scope of ["keyword", "entity.name.function", "comment"]) {
    const color = colorFor(theme, scope);
    expect(color).not.toBe("#ffffff");
    expect(contrast(color, "#1e1e1e")).toBeGreaterThanOrEqual(3);
  }
});
