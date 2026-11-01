// The gallery's controls live in the URL: a query reads the same in the web gallery and in the
// native one (schemas/gallery/env-vectors.json, which CmuxNextGalleryTests replays too).
import { expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { overPicture, readEnv, withColorScheme, writeEnv, type GalleryEnv } from "../src/gallery/env";
import { wallpaperTintOpacity } from "../src/gallery/theme/tokens";
import { agentPaneTheme, themeTokens, webThemePayload } from "../src/gallery/theme/web";
import { DEFAULT_DARK_THEME, DEFAULT_LIGHT_THEME } from "../src/gallery/theme/ghostty";

const vectors = JSON.parse(
  fs.readFileSync(path.join(import.meta.dir, "../../schemas/gallery/env-vectors.json"), "utf8"),
) as { vectors: { query: Record<string, string>; env: GalleryEnv }[] };

test("each shared vector's query reads as its value set", () => {
  expect(vectors.vectors.length).toBeGreaterThan(5);
  for (const vector of vectors.vectors) expect(readEnv(new URLSearchParams(vector.query))).toEqual(vector.env);
});

// The app's default theme is the Apple System Colors pair, which follows the window appearance.
// A light window with no theme named shows the pair's light side, not the dark one.
test("a light window with no theme named shows the default pair's light side", () => {
  const env = readEnv(new URLSearchParams("colorScheme=light"));
  expect(env.theme).toBe(DEFAULT_LIGHT_THEME);
  expect(writeEnv(env).toString()).toBe("colorScheme=light");
});

test("a named theme stays put under either appearance", () => {
  expect(readEnv(new URLSearchParams("colorScheme=light&theme=Dracula")).theme).toBe("Dracula");
  expect(readEnv(new URLSearchParams("colorScheme=dark")).theme).toBe(DEFAULT_DARK_THEME);
  expect(writeEnv(readEnv(new URLSearchParams("colorScheme=light&theme=Apple+System+Colors"))).get("theme")).toBe(
    DEFAULT_DARK_THEME,
  );
});

test("switching the appearance moves the default pair to the matching side", () => {
  const start = readEnv(new URLSearchParams());
  const light = withColorScheme(start, "light");
  expect(light.theme).toBe(DEFAULT_LIGHT_THEME);
  expect(withColorScheme(light, "dark").theme).toBe(DEFAULT_DARK_THEME);
  expect(withColorScheme(light, "auto").theme).toBe(DEFAULT_LIGHT_THEME);
  expect(withColorScheme({ ...start, theme: "Dracula" }, "light").theme).toBe("Dracula");
});

// The background axis (frame/background.ts): web only, so absent from the shared vectors; absent and
// `none` are the opaque window, and the link stays short.
test("a background reads and writes as its picture, none as nothing", () => {
  for (const picture of ["light", "dark", "busy"] as const) {
    const env = readEnv(new URLSearchParams(`background=${picture}`));
    expect(env.background).toBe(picture);
    expect(overPicture(env)).toBe(true);
    expect(writeEnv(env).toString()).toBe(`background=${picture}`);
  }
  for (const query of ["", "background=none", "background=photo"]) {
    const env = readEnv(new URLSearchParams(query));
    expect(env.background).toBeUndefined();
    expect(overPicture(env)).toBe(false);
    expect(writeEnv(env).toString()).toBe("");
  }
  expect(writeEnv({ ...readEnv(new URLSearchParams()), background: "none" }).toString()).toBe("");
});

test("over a picture the page background is clear and the solid surface stays", () => {
  const tokens = themeTokens({
    name: "test",
    background: "#1e1e1e",
    foreground: "#e6e6e6",
    palette: [],
  } as never);
  const opaque = webThemePayload(tokens).variables;
  const clear = webThemePayload(tokens, undefined, true).variables;
  expect(opaque["--cmux-surface-background"]).toBe("rgba(30, 30, 30, 1.0)");
  expect(clear["--cmux-surface-background"]).toBe("rgba(30, 30, 30, 0.0)");
  expect(clear["--cmux-surface-solid"]).toBe("rgba(30, 30, 30, 1.0)");
  expect(agentPaneTheme(tokens, false, true).pageBackground).toBe("rgba(30, 30, 30, 0.0)");
  const tint = wallpaperTintOpacity(tokens);
  expect(tint).toBeGreaterThanOrEqual(0.52);
  expect(tint).toBeLessThanOrEqual(0.76);
});
