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
  "": "↑", "": "↓", "": "←", "": "→", "\r": "↩", "\t": "⇥", " ": "Space",
};
const keyConfigNames: Record<string, string> = {
  "": "up", "": "down", "": "left", "": "right", "\r": "enter", "\t": "tab", " ": "space",
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
    return {
      id: row.id,
      combos: strokes.map(shortcutStroke),
      sequence: row.chord ? true : undefined,
      description: row.title as LocalizedText,
      configValue: row.chord ? JSON.stringify(row.chord.map(shortcutConfigStroke)) : strokes.map(shortcutConfigStroke)[0],
    };
  }),
}));
