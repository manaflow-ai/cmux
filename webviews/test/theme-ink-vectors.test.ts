// schemas/theme/theme-ink-vectors.json holds every bundled theme's text inks and popup surface as
// Swift derives them (CmuxNextDesignTests ThemeInkVectorsTests keeps it equal to Swift's output).
// The gallery's tokens (src/gallery/theme/tokens.ts), the agent pane harness's
// (scripts/agent-pane/theme.mjs) and the spec's Python port that writes the file must give the same.
import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { themeTokens as harnessTokens } from "../scripts/agent-pane/theme.mjs";
import {
  GHOSTTY_DEFAULT,
  deriveTokens,
  hex,
  opaqueOverlayFill,
  parseHex,
  type ThemeRGB,
} from "../src/gallery/theme/tokens";

const ROOT = path.resolve(import.meta.dir, "../..");
const VECTORS = path.join(ROOT, "schemas/theme/theme-ink-vectors.json");
const TOOL = path.join(ROOT, "plans/cmux-next/spec-proposals/visuals/tools/derive_theme_tokens.py");
const INKS = ["textPrimary", "textSecondary", "textTertiary"] as const;

type Case = {
  theme: string;
  input: { background: string; foreground: string; accentColor?: string; palette?: string[] };
  isDark: boolean;
} & Record<(typeof INKS)[number] | "opaqueOverlayFill", string>;

const vectors = JSON.parse(fs.readFileSync(VECTORS, "utf8")) as { lift: number; cases: Case[] };
const color = (text: string): ThemeRGB => parseHex(text)!;
const upper = (value: ThemeRGB) => hex(value).toUpperCase();

test("the gallery tokens give Swift's inks and popup surface for every bundled theme", () => {
  expect(vectors.cases.length).toBeGreaterThan(500);
  const differences = vectors.cases.flatMap((item) => {
    const tokens = deriveTokens({
      background: color(item.input.background),
      foreground: color(item.input.foreground),
      // Only a theme with its own accent lists its palette (the inks read it through the app theme).
      palette: item.input.palette?.map(color) ?? GHOSTTY_DEFAULT.palette,
      accentColor: item.input.accentColor ? color(item.input.accentColor) : null,
      backgroundOpacity: 1,
    });
    const got: Record<string, string> = {
      isDark: String(tokens.isDark),
      ...Object.fromEntries(INKS.map((name) => [name, upper(tokens[name])])),
      opaqueOverlayFill: upper(opaqueOverlayFill(tokens, vectors.lift)),
    };
    return Object.entries(got)
      .filter(([name, value]) => String(item[name as keyof Case]) !== value)
      .map(([name, value]) => `${item.theme}.${name}: Swift ${String(item[name as keyof Case])}, gallery ${value}`);
  });
  expect(differences).toEqual([]);
});

test("the agent pane harness gives Swift's inks for every bundled theme without its own accent", () => {
  const channel = (text: string) => {
    const value = color(text);
    return { r: value.red, g: value.green, b: value.blue, a: 1 };
  };
  const hexOf = (value: { r: number; g: number; b: number }) =>
    upper({ red: value.r, green: value.g, blue: value.b, alpha: 1 });
  const differences = vectors.cases
    .filter((item) => !item.input.accentColor)
    .flatMap((item) => {
      const tokens = harnessTokens({
        background: channel(item.input.background),
        foreground: channel(item.input.foreground),
        palette: [],
        backgroundOpacity: 1,
      });
      return INKS.filter((name) => hexOf(tokens[name]) !== item[name]).map(
        (name) => `${item.theme}.${name}: Swift ${item[name]}, harness ${hexOf(tokens[name])}`,
      );
    });
  expect(differences).toEqual([]);
});

test("the spec's Python port writes the same vectors (derive_theme_tokens.py --check-theme-ink-vectors)", () => {
  const result = spawnSync("python3", ["-I", TOOL, "--check-theme-ink-vectors", VECTORS], { encoding: "utf8" });
  expect(`${result.stdout}${result.stderr}`.trim()).toEndWith("is current");
  expect(result.status).toBe(0);
});
