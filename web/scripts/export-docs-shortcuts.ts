// Writes web/data/cmux-shortcuts.generated.json, the copy of the cmux-next
// action catalog's keyboard shortcuts that the docs pages read
// (DOCS-SHORTCUTS-FROM-CATALOG). web/ never reads plans/ at build time; run
// this after the catalog export changes:
//   bun web/scripts/export-docs-shortcuts.ts
// web/tests/docs-shortcuts.test.ts fails until the copy is fresh.
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

export type DocsWireShortcut = { key: string; modifiers: string[]; family?: string };
export type DocsLocalized = Record<string, string>;
export type DocsAlias = { keys: DocsWireShortcut[]; when: string | null };
export type DocsShortcutRow = {
  id: string;
  title: DocsLocalized;
  shortcut: DocsWireShortcut | null;
  chord: DocsWireShortcut[] | null;
  /** The binding table's extra default keys (browser tab keys, Ctrl-Cmd arrows for resize). */
  aliases: DocsAlias[];
};
export type DocsShortcutSection = { id: string; order: number; title: DocsLocalized; shortcuts: DocsShortcutRow[] };
export type DocsShortcutsFile = { version: 1; sections: DocsShortcutSection[] };

type Catalog = { sourceLanguage?: string; strings: Record<string, { localizations?: Record<string, { stringUnit?: { value?: string } }> }> };
type SurfaceAction = {
  id: string;
  title: string;
  title_key: string | null;
  title_table: string | null;
  default_shortcut: DocsWireShortcut | null;
  default_chord: DocsWireShortcut[] | null;
  default_aliases: DocsAlias[];
  palette_section: { id: string; order: number; title: string; title_key: string; title_table: string };
};

/** The web locale of a string catalog language where the codes differ. */
const webLocale: Record<string, string> = { "zh-Hans": "zh-CN", "zh-Hant": "zh-TW", nb: "no" };

/** English from the export, every other language the string catalog has, keyed by web locale. */
function localized(english: string, key: string | null, table: string | null, catalogs: Record<string, unknown>): DocsLocalized {
  const entry = key && table ? (catalogs[table] as Catalog | undefined)?.strings[key] : undefined;
  const result: DocsLocalized = { en: english };
  for (const [language, localization] of Object.entries(entry?.localizations ?? {}).sort(([a], [b]) => a.localeCompare(b))) {
    const value = localization.stringUnit?.value;
    if (language !== "en" && value) result[webLocale[language] ?? language] = value;
  }
  return result;
}

/** The docs file for a catalog export and the CmuxNextActions string catalogs (table name to JSON). */
export function buildDocsShortcuts(surfaces: { actions: SurfaceAction[] }, catalogs: Record<string, unknown>): DocsShortcutsFile {
  const sections = new Map<string, DocsShortcutSection>();
  for (const action of surfaces.actions) {
    if (!action.default_shortcut && !action.default_chord && action.default_aliases.length === 0) continue;
    const section = action.palette_section;
    let entry = sections.get(section.id);
    if (!entry) {
      entry = { id: section.id, order: section.order, title: localized(section.title, section.title_key, section.title_table, catalogs), shortcuts: [] };
      sections.set(section.id, entry);
    }
    entry.shortcuts.push({
      id: action.id,
      title: localized(action.title, action.title_key, action.title_table, catalogs),
      shortcut: action.default_shortcut,
      chord: action.default_chord,
      aliases: action.default_aliases,
    });
  }
  return { version: 1, sections: [...sections.values()].sort((a, b) => a.order - b.order || a.id.localeCompare(b.id)) };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const repo = fileURLToPath(new URL("../..", import.meta.url));
  const surfaces = JSON.parse(readFileSync(join(repo, "plans/cmux-next/action-surfaces.json"), "utf8"));
  const catalogDir = join(repo, "Packages/macOS/CmuxNext/Sources/CmuxNextActions");
  const catalogs = Object.fromEntries(
    readdirSync(catalogDir)
      .filter((name) => name.endsWith(".xcstrings"))
      .map((name) => [name.replace(/\.xcstrings$/, ""), JSON.parse(readFileSync(join(catalogDir, name), "utf8"))]),
  );
  const output = fileURLToPath(new URL("../data/cmux-shortcuts.generated.json", import.meta.url));
  writeFileSync(output, JSON.stringify(buildDocsShortcuts(surfaces, catalogs), null, 2) + "\n");
  console.log(`wrote ${output}`);
}
