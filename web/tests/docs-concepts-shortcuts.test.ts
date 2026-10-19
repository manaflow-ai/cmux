import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { shortcutComboText } from "../data/cmux-shortcuts";

const webRoot = resolve(fileURLToPath(new URL(".", import.meta.url)), "..");
const conceptsPage = readFileSync(
  resolve(webRoot, "app/[locale]/(landing)/docs/concepts/page.tsx"),
  "utf8",
);

const navigationShortcutIds = ["prevSidebarTab", "nextSidebarTab", "prevSurface", "nextSurface"];

describe("docs concepts shortcuts", () => {
  // The shortcut data comes from the cmux-next action catalog
  // (cmux-shortcuts.generated.json, checked by docs-shortcuts.test.ts).
  test("shortcut data has a default for workspace and surface navigation", () => {
    for (const id of navigationShortcutIds) {
      expect(shortcutComboText(id).length).toBeGreaterThan(0);
    }
  });

  test("concepts page reads navigation shortcuts from the shortcut data", () => {
    for (const id of navigationShortcutIds) {
      expect(conceptsPage).toContain(`shortcutComboText("${id}")`);
    }
  });
});
