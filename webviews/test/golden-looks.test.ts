// The golden screen's looks (dev-server/goldenLooks.ts): the registry, theme files and setup folders
// resolve to what the gallery draws.
import { expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  lookFromSetup,
  parseJsonc,
  readGoldenLooks,
  schemeFromThemeFile,
  discoverLooks,
  drawnSchemes,
  previewPath,
} from "../dev-server/goldenLooks";
import { lookDisplay, lookSettingsValues, lookTheme } from "../src/gallery/golden/look";

test("theme files read with comments, a URL in a string and trailing commas", () => {
  expect(parseJsonc('// head\n{ "a": "https://x.test/y", /* b */ "c": [1, 2,], }')).toEqual({
    a: "https://x.test/y",
    c: [1, 2],
  });
});

test("the registry's built-in looks resolve, and a look with missing files is skipped with its reason", () => {
  const { looks, skipped } = readGoldenLooks([]);
  const ids = looks.map((look) => look.id);
  expect(ids.slice(0, 4)).toEqual(["cmux", "claude", "codex", "studio"]);
  const claude = looks.find((look) => look.id === "claude")!;
  // The shipped theme file in light, with its colors and agent pane surface.
  expect(claude.schemes.light).toMatchObject({
    source: "Resources/theme-files/claude-desktop.json",
    theme: "Claude Light",
    colors: { background: "#faf9f5", accent: "#d97757" },
    surfaces: { agentPane: "#faf9f5", sidebar: "#f0eee6" },
  });
  expect(claude.composerLook).toBe("claude");
  expect(lookDisplay(claude)).toEqual({ "agentPane.display.transcriptLook": "claude" });
  for (const skip of skipped) expect(skip.reason).toContain("is not in this checkout");
  expect([...ids, ...skipped.map((skip) => skip.id)]).toContain("studio-addon");
});

test("a setup folder is a look: its theme file for the scheme it draws, its stylesheet and settings", () => {
  const dir = mkdtempSync(path.join(os.tmpdir(), "golden-look-"));
  mkdirSync(path.join(dir, "themes"));
  mkdirSync(path.join(dir, "agent-pane"));
  writeFileSync(
    path.join(dir, "cmux-setup.json"),
    JSON.stringify({
      name: "Night",
      tagline: "A dark look.",
      settings: { "appearance.themeFile": "night", "agentPane.display.font.size": 13, "sidebar.density": "compact" },
    }),
  );
  writeFileSync(
    path.join(dir, "themes/night.json"),
    '// Night\n{ "appearance.theme": "Builtin Dark", "colors": { "background": "#101010", "foreground": "#eeeeee" }, "appearance.surfaces.sidebar.color": "#0a0a0a" }',
  );
  writeFileSync(path.join(dir, "agent-pane/theme.css"), ":root { --cv-user-bubble-radius: 8px; }");
  const look = lookFromSetup(dir);
  expect(look.title).toBe("Night");
  expect(look.schemes.dark).toMatchObject({ colors: { background: "#101010" }, surfaces: { sidebar: "#0a0a0a" } });
  expect(look.schemes.light).toEqual({});
  expect(look.themeCSS).toContain("--cv-user-bubble-radius");
  expect(look.settings).toEqual({ "agentPane.display.font.size": 13, "sidebar.density": "compact" });
  expect(lookDisplay(look)).toEqual({ "agentPane.display.font.size": 13 });
  // The folder it came from, so `golden:looks --preview` writes the look repo's own stills.
  expect(look.setupDir).toBe(path.resolve(dir));
});

test("a setting a look keeps in a file of its folder is that file's document, as install puts it", () => {
  const dir = mkdtempSync(path.join(os.tmpdir(), "golden-look-"));
  mkdirSync(path.join(dir, "agent-pane"));
  writeFileSync(
    path.join(dir, "cmux-setup.json"),
    JSON.stringify({
      settings: {
        "agentPane.display.thinking.glyph": { $file: "agent-pane/thinking-glyph.json" },
        "agentPane.display.font.size": { $file: "../outside.json" },
      },
    }),
  );
  writeFileSync(
    path.join(dir, "agent-pane/thinking-glyph.json"),
    '// dots\n{ "$schema": "cmux.particles/1", "particle": { "size": 3 } }',
  );
  const look = lookFromSetup(dir);
  expect(lookDisplay(look)["agentPane.display.thinking.glyph"]).toEqual({
    $schema: "cmux.particles/1",
    particle: { size: 3 },
  });
  // A path out of the folder stays the reference it was, as install refuses it.
  expect(look.settings["agentPane.display.font.size"]).toEqual({ $file: "../outside.json" });
});

test("a look repo's preview stills go where the looks gallery reads them", () => {
  expect(previewPath("/src/my-look", "light")).toBe("/src/my-look/preview/golden-light.png");
  expect(previewPath("/src/my-look", "dark")).toBe("/src/my-look/preview/golden-dark.png");
});

test("a scheme's colors go over its terminal theme; an unknown theme name keeps the base", () => {
  const base = { name: "Base", background: "#000000", foreground: "#ffffff", palette: [] };
  const scheme = schemeFromThemeFile(
    { "appearance.theme": "Nope", colors: { accent: "#3366ff", background: "#111111" } },
    "x",
  );
  expect(lookTheme(scheme, base, () => undefined)).toMatchObject({
    name: "Base",
    background: "#111111",
    foreground: "#ffffff",
    accent: "#3366ff",
  });
});

test("Settings under a look lists its settings, composer look and the scheme's theme file keys", () => {
  const claude = readGoldenLooks([]).looks.find((look) => look.id === "claude")!;
  const light = lookSettingsValues(claude, "light");
  expect(light).toMatchObject({
    "agentPane.display.transcriptLook": "claude",
    "sidebar.density": "compact",
    "agentPane.composerLook": "claude",
    "appearance.theme": "Claude Light",
    "appearance.surfaces.sidebar.color": "#f0eee6",
  });
  expect(lookSettingsValues(claude, "dark")).toMatchObject({
    "appearance.theme": "Claude Dark",
    "appearance.accent": "theme",
    "appearance.density": "comfortable",
    "appearance.surfaces.sidebar.color": "#121211",
  });
  // The default look puts nothing in effect: Settings shows the app's defaults.
  expect(
    lookSettingsValues(
      readGoldenLooks([]).looks.find((look) => look.id === "cmux")!,
      "dark",
    ),
  ).toEqual({});
});

test("every look in a checkout is found: shipped theme files, examples/ setup folders and theme files", () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "golden-every-"));
  const theme = (bg: string, fg: string) => JSON.stringify({ colors: { background: bg, foreground: fg } });
  mkdirSync(path.join(root, "Resources/theme-files"), { recursive: true });
  writeFileSync(path.join(root, "Resources/theme-files/ink.json"), theme("#101010", "#eeeeee"));
  mkdirSync(path.join(root, "examples/customize/me/day/themes"), { recursive: true });
  writeFileSync(path.join(root, "examples/customize/me/day/themes/day.json"), theme("#ffffff", "#111111"));
  const pack = path.join(root, "examples/looks/new-look");
  mkdirSync(path.join(pack, "themes"), { recursive: true });
  writeFileSync(
    path.join(pack, "cmux-setup.json"),
    JSON.stringify({
      name: "New look",
      settings: { "appearance.themeFile": "new", "agentPane.display.font.size": 13 },
    }),
  );
  writeFileSync(path.join(pack, "themes/new.json"), theme("#202020", "#f0f0f0"));
  const looks = discoverLooks(root);
  // Outside the repo a source is its base name; the pack's own theme file is drawn with the pack.
  expect(looks.map((look) => look.source)).toEqual(["ink.json", "new-look", "day.json"]);
  const [ink, newLook, day] = looks;
  // A theme file alone draws in the scheme it is for; a setup folder that brings settings, in both.
  expect(drawnSchemes(ink!)).toEqual(["dark"]);
  expect(drawnSchemes(day!)).toEqual(["light"]);
  expect(newLook!.title).toBe("New look");
  expect(drawnSchemes(newLook!)).toEqual(["light", "dark"]);
  expect(drawnSchemes({ ...newLook!, settings: {} })).toEqual(["dark"]);
});
