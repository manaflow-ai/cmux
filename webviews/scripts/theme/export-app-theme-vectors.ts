#!/usr/bin/env bun
// Writes schemas/theme/app-theme-vectors.json: the web app-theme module's output (src/theme/appTheme.ts)
// for a fixed sample of the bundled Ghostty themes, so the Swift port (CmuxTheme AppTheme.swift)
// replays the same inputs and must produce the same tokens.
//   bun scripts/theme/export-app-theme-vectors.ts          # write
//   bun scripts/theme/export-app-theme-vectors.ts --check  # fail when stale
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { readShippedThemes } from "../../dev-server/galleryHost";
import { APP_THEME_TOKENS, deriveAppTheme } from "../../src/theme/appTheme";

export const VECTORS_PATH = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../../../schemas/theme/app-theme-vectors.json",
);

/** Every 8th bundled theme by name, plus the cases that exercise the fallbacks. */
const PINNED = ["Apple System Colors", "Apple System Colors Light", "Dracula", "Grass", "Hot Dog Stand", "Nord"];

export function vectors(): string {
  const themes = readShippedThemes().sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  const sample = themes.filter((theme, index) => index % 8 === 0 || PINNED.includes(theme.name));
  const cases = sample.map((theme) => {
    const app = deriveAppTheme(theme);
    return {
      name: theme.name,
      input: { background: theme.background, foreground: theme.foreground, palette: theme.palette },
      isDark: app.isDark,
      tokens: app.tokens,
    };
  });
  const tokens = Object.fromEntries(Object.entries(APP_THEME_TOKENS).map(([name, spec]) => [name, spec.variable]));
  // One case per line keeps the file short and its diffs readable.
  return [
    "{",
    `"generator": ${JSON.stringify("webviews/scripts/theme/export-app-theme-vectors.ts (do not edit)")},`,
    `"tokens": ${JSON.stringify(tokens)},`,
    '"cases": [',
    cases.map((item) => JSON.stringify(item)).join(",\n"),
    "]",
    "}",
    "",
  ].join("\n");
}

if ((import.meta as ImportMeta & { main?: boolean }).main) {
  const text = vectors();
  if (process.argv.includes("--check")) {
    const current = fs.existsSync(VECTORS_PATH) ? fs.readFileSync(VECTORS_PATH, "utf8") : "";
    if (current !== text) {
      console.error(`${VECTORS_PATH} is stale; run bun scripts/theme/export-app-theme-vectors.ts`);
      process.exit(1);
    }
  } else {
    fs.writeFileSync(VECTORS_PATH, text);
    console.log(`wrote ${VECTORS_PATH}`);
  }
}
