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
const swiftShortcutDefaults = readFileSync(
  resolve(webRoot, "../Sources/KeyboardShortcutSettings.swift"),
  "utf8",
);

function swiftDefaultComboText(id: string): string {
  const match = swiftShortcutDefaults.match(
    new RegExp(
      `case \\.${id}:\\s*return StoredShortcut\\(key: "([^"]+)", command: (true|false), shift: (true|false), option: (true|false), control: (true|false)\\)`,
    ),
  );
  if (!match) throw new Error(`No Swift default for ${id}`);
  const [, key, command, shift, option, control] = match;
  return [
    control === "true" ? "⌃" : "",
    option === "true" ? "⌥" : "",
    command === "true" ? "⌘" : "",
    shift === "true" ? "⇧" : "",
    key.toUpperCase(),
  ].join("");
}

const navigationShortcutIds = ["prevSidebarTab", "nextSidebarTab", "prevSurface", "nextSurface"];

describe("docs concepts shortcuts", () => {
  test("shortcut data matches the app defaults for workspace and surface navigation", () => {
    for (const id of navigationShortcutIds) {
      expect(shortcutComboText(id)).toBe(swiftDefaultComboText(id));
    }
  });

  test("concepts page reads navigation shortcuts from the shortcut data", () => {
    for (const id of navigationShortcutIds) {
      expect(conceptsPage).toContain(`shortcutComboText("${id}")`);
    }
  });
});
