// The keyboard shortcuts docs, built from the cmux-next action catalog
// (DOCS-SHORTCUTS-FROM-CATALOG). cmux-shortcuts.generated.json is a copy of
// the catalog's default shortcuts and chords with the app's own translated
// titles; regenerate it with `bun web/scripts/export-docs-shortcuts.ts`
// (web/tests/docs-shortcuts.test.ts checks that it is fresh).
import type { Locale } from "../i18n/routing";
import generated from "./cmux-shortcuts.generated.json";
import type { DocsShortcutsFile, DocsWireShortcut } from "../scripts/export-docs-shortcuts";

export type LocalizedText = {
  en: string;
} & Partial<Record<Exclude<Locale, "en">, string>>;

export function localizedShortcutText(text: LocalizedText, locale: string) {
  return text[locale as keyof LocalizedText] ?? (locale.startsWith("ja") ? text.ja : undefined) ?? text.en;
}

export type Shortcut = {
  id: string;
  /** Alternative key combinations, or with `sequence` the strokes of one chord in order. */
  combos: string[][];
  sequence?: boolean;
  description: LocalizedText;
  note?: LocalizedText;
  /** The value for `shortcuts.bindings.<id>` in cmux.json. */
  configValue?: string;
};

export type ShortcutCategory = {
  id: string;
  title: LocalizedText;
  shortcuts: Shortcut[];
};

const modifierSymbols: Record<string, string> = { ctrl: "⌃", opt: "⌥", shift: "⇧", cmd: "⌘" };
const keySymbols: Record<string, string> = {
  "\uf700": "↑", "\uf701": "↓", "\uf702": "←", "\uf703": "→", "\uf72c": "PgUp", "\uf72d": "PgDn",
  "\uf729": "Home", "\uf72b": "End", "\r": "↩", "\t": "⇥", " ": "Space", "\u001b": "Esc", "\b": "⌫",
};
const keyConfigNames: Record<string, string> = {
  "\uf700": "up", "\uf701": "down", "\uf702": "left", "\uf703": "right", "\uf72c": "pageup", "\uf72d": "pagedown",
  "\uf729": "home", "\uf72b": "end", "\r": "enter", "\t": "tab", " ": "space", "\u001b": "escape", "\b": "delete",
};

/** The keys a reader sees for one stroke: modifiers ⌃⌥⇧⌘, then the key. */
export function shortcutStroke(wire: DocsWireShortcut): string[] {
  const key = wire.family === "digits" ? "1…9" : (keySymbols[wire.key] ?? wire.key.toUpperCase());
  return [...wire.modifiers.map((modifier) => modifierSymbols[modifier] ?? modifier), key];
}

/** One stroke as cmux.json writes it (`ctrl+cmd+]`). */
export function shortcutConfigStroke(wire: DocsWireShortcut): string {
  return [...wire.modifiers, keyConfigNames[wire.key] ?? wire.key].join("+");
}

const file = generated as DocsShortcutsFile;

export const shortcutCategories: ShortcutCategory[] = file.sections.map((section) => ({
  id: section.id.replace(/^category\./, ""),
  title: section.title as LocalizedText,
  shortcuts: section.shortcuts.map((row) => {
    const strokes = row.chord ?? (row.shortcut ? [row.shortcut] : []);
    // A chord's strokes are one sequence; otherwise the default key, then each
    // table alias once, as alternatives.
    const combos = row.chord
      ? strokes.map(shortcutStroke)
      : [...strokes, ...row.aliases.map((alias) => alias.keys[0])].map(shortcutStroke)
          .filter((combo, index, all) => all.findIndex((other) => other.join() === combo.join()) === index);
    return {
      id: row.id,
      combos,
      sequence: row.chord ? true : undefined,
      description: row.title as LocalizedText,
      configValue: row.chord ? JSON.stringify(row.chord.map(shortcutConfigStroke)) : strokes.map(shortcutConfigStroke)[0],
    };
  }),
}));
