// The gallery's controls live in the URL: a query reads the same in the web gallery and in the
// native one (schemas/gallery/env-vectors.json, which CmuxNextGalleryTests replays too).
import { expect, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { readEnv, withColorScheme, writeEnv, type GalleryEnv } from "../src/gallery/env";
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
