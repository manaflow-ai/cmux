import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { localizedShortcutText, shortcutCategories } from "../data/cmux-shortcuts";
import generated from "../data/cmux-shortcuts.generated.json";
import { buildDocsShortcuts } from "../scripts/export-docs-shortcuts";

// DOCS-SHORTCUTS-FROM-CATALOG: the keyboard shortcuts docs are the cmux-next
// action catalog. The page reads a copy in web/data (web/ never reads plans/
// at build time); these tests read the catalog export and the string
// catalogs at test time and require the copy and the page to match them.

const repo = fileURLToPath(new URL("../..", import.meta.url));
const surfaces = JSON.parse(readFileSync(join(repo, "plans/cmux-next/action-surfaces.json"), "utf8"));
const catalogDir = join(repo, "Packages/macOS/CmuxNext/Sources/CmuxNextActions");
const catalogs: Record<string, unknown> = Object.fromEntries(
  readdirSync(catalogDir)
    .filter((name) => name.endsWith(".xcstrings"))
    .map((name) => [name.replace(/\.xcstrings$/, ""), JSON.parse(readFileSync(join(catalogDir, name), "utf8"))]),
);

type Wire = { key: string; modifiers: string[]; family?: string };
type Alias = { keys: Wire[]; when: string | null };
type Action = {
  id: string; title: string; title_key: string | null; title_table: string | null;
  default_shortcut: Wire | null; default_chord: Wire[] | null; default_aliases: Alias[];
};
const bound: Action[] = surfaces.actions.filter((action: Action) => action.default_shortcut || action.default_chord || action.default_aliases.length > 0);

/** The keys a reader sees for one stroke: modifiers ⌃⌥⇧⌘, then the key. */
function expectedStroke(wire: Wire): string[] {
  const symbols: Record<string, string> = { ctrl: "⌃", opt: "⌥", shift: "⇧", cmd: "⌘" };
  const keys: Record<string, string> = {
    "\uf700": "↑", "\uf701": "↓", "\uf702": "←", "\uf703": "→", "\uf72c": "PgUp", "\uf72d": "PgDn",
    "\uf729": "Home", "\uf72b": "End", "\r": "↩", "\t": "⇥", " ": "Space", "\u001b": "Esc", "\b": "⌫",
  };
  const key = wire.family === "digits" ? "1…9" : (keys[wire.key] ?? wire.key.toUpperCase());
  return [...wire.modifiers.map((modifier) => symbols[modifier]), key];
}

describe("keyboard shortcuts docs", () => {
  test("the web/data copy is fresh against the catalog export and string catalogs", () => {
    expect(buildDocsShortcuts(surfaces, catalogs)).toEqual(generated as never);
  });

  test("every catalog default shortcut is on the page with the same keys, and nothing else is", () => {
    const rows = new Map(shortcutCategories.flatMap((category) => category.shortcuts).map((row) => [row.id, row]));
    expect([...rows.keys()].sort()).toEqual(bound.map((action) => action.id).sort());
    for (const action of bound) {
      const row = rows.get(action.id)!;
      // The default key or chord, then each table alias (Ctrl-Cmd arrows for resize, browser tab keys) once.
      const primary = action.default_chord ? action.default_chord.map(expectedStroke) : action.default_shortcut ? [expectedStroke(action.default_shortcut)] : [];
      const aliases = action.default_aliases.map((alias) => expectedStroke(alias.keys[0]));
      const expected = [...primary, ...aliases].filter((combo, index, all) => all.findIndex((other) => other.join() === combo.join()) === index);
      expect({ id: action.id, combos: row.combos, sequence: Boolean(row.sequence) })
        .toEqual({ id: action.id, combos: expected, sequence: Boolean(action.default_chord) });
      expect(localizedShortcutText(row.description, "en")).toBe(action.title);
    }
  });

  test("table aliases are extra keys on their action's row", () => {
    const rows = new Map(shortcutCategories.flatMap((category) => category.shortcuts).map((row) => [row.id, row]));
    expect(rows.get("resizePaneLeft")!.combos).toContainEqual(["⌃", "⌘", "←"]);
    expect(rows.get("nextSurface")!.combos).toContainEqual(["⌃", "⇥"]);
  });

  test("titles are the app's own translations", () => {
    const rows = new Map(shortcutCategories.flatMap((category) => category.shortcuts).map((row) => [row.id, row]));
    const strings = (catalogs.ActionCatalog as { strings: Record<string, { localizations?: Record<string, { stringUnit?: { value: string } }> }> }).strings;
    const ja = strings["action.nextSidebarTab"]?.localizations?.ja?.stringUnit?.value;
    expect(ja).toBeTruthy();
    expect(localizedShortcutText(rows.get("nextSidebarTab")!.description, "ja")).toBe(ja!);
    expect(localizedShortcutText(rows.get("nextSidebarTab")!.description, "zh-CN"))
      .toBe(strings["action.nextSidebarTab"]?.localizations?.["zh-Hans"]?.stringUnit?.value ?? "");
  });
});
