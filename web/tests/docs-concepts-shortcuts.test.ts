import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { shortcutCategoriesOf, shortcutComboText } from "../data/cmux-shortcuts";
import { buildDocsShortcuts } from "../scripts/export-docs-shortcuts";

const webRoot = resolve(fileURLToPath(new URL(".", import.meta.url)), "..");
const conceptsPage = readFileSync(
  resolve(webRoot, "app/[locale]/(landing)/docs/concepts/page.tsx"),
  "utf8",
);

// The page renders the committed copy, which only the base autofix writes (RFD 0048) and may lag the
// catalog by one run, so this asks the catalog at the head: a change that drops one of these defaults
// fails here, not on the base after the copy catches up.
const repo = resolve(webRoot, "..");
const surfaces = JSON.parse(readFileSync(join(repo, "plans/cmux-next/action-surfaces.json"), "utf8"));
const catalogDir = join(repo, "Packages/macOS/CmuxNext/Sources/CmuxNextActions");
const catalogs: Record<string, unknown> = Object.fromEntries(
  readdirSync(catalogDir)
    .filter((name) => name.endsWith(".xcstrings"))
    .map((name) => [name.replace(/\.xcstrings$/, ""), JSON.parse(readFileSync(join(catalogDir, name), "utf8"))]),
);
const categories = shortcutCategoriesOf(buildDocsShortcuts(surfaces, catalogs));

const navigationShortcutIds = ["prevSidebarTab", "nextSidebarTab", "prevSurface", "nextSurface"];

describe("docs concepts shortcuts", () => {
  test("the action catalog has a default for workspace and surface navigation", () => {
    for (const id of navigationShortcutIds) {
      expect(shortcutComboText(id, 0, categories).length).toBeGreaterThan(0);
    }
  });

  test("concepts page reads navigation shortcuts from the shortcut data", () => {
    for (const id of navigationShortcutIds) {
      expect(conceptsPage).toContain(`shortcutComboText("${id}")`);
    }
  });
});
