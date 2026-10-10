// DESKTOP-FEEL (R139) gate: every first-party page entry loads the shared desktop layer
// (src/pages/shared/desktop.ts) as its FIRST import, so its CSS comes before the page's own and
// the page can only opt content back in. A new page under src/pages fails here until it does.
import { expect, test } from "bun:test";
import { readFileSync, readdirSync, existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const src = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

function firstImport(file: string): string | null {
  const text = readFileSync(file, "utf8");
  const match = /^\s*import\s+(?:[^"';]*\sfrom\s+)?["']([^"']+)["']/m.exec(text);
  return match ? match[1]! : null;
}

function layerSpecifier(file: string): string {
  const relative = path.relative(path.dirname(file), path.join(src, "pages/shared/desktop"));
  return relative.startsWith(".") ? relative : `./${relative}`;
}

test("every page under src/pages imports the desktop layer first", () => {
  const pages = readdirSync(path.join(src, "pages"), { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && entry.name !== "shared")
    .map((entry) => path.join(src, "pages", entry.name, "main.tsx"))
    .filter((file) => existsSync(file));
  expect(pages.length).toBeGreaterThan(5);
  for (const file of pages) {
    expect({ file: path.relative(src, file), first: firstImport(file) }).toEqual({
      file: path.relative(src, file),
      first: layerSpecifier(file),
    });
  }
});

