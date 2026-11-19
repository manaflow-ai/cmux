// The golden screen's looks (dev-server/goldenLooks.ts): the registry, theme files and setup folders
// resolve to what the gallery draws.
import { expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { lookFromSetup, parseJsonc, readGoldenLooks, schemeFromThemeFile } from "../dev-server/goldenLooks";
import { lookDisplay, lookTheme } from "../src/gallery/golden/look";

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
