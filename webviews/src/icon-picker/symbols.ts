// SF Symbol names as searchable picker items. The host sends the catalog the running OS ships
// (CoreGlyphs: names in the system order, search keywords, categories) with the first session;
// the page never bundles symbol images (the host renders each visible cell through
// `symbolImageURL`). Words come from the dotted name ("person.crop.circle" matches "person",
// "crop" and "circle") and from the system's keywords ("star" matches "favorite").
import { fold } from "./emojiData";
import type { Searchable } from "./search";

export interface SymbolItem extends Searchable {
  readonly name: string;
}

/** One system category (CoreGlyphs categories.plist): its key, its SF Symbol, its members. */
export interface SymbolCategory {
  readonly key: string;
  readonly icon: string;
  /** Indices into `SymbolCatalog.names`. */
  readonly members: readonly number[];
}

/** The host's SF Symbol catalog: names in the system's order, keywords and categories. */
export interface SymbolCatalog {
  readonly names: readonly string[];
  /** Aligned with `names`: space-separated search keywords ("" for none). */
  readonly keywords?: readonly string[];
  readonly categories?: readonly SymbolCategory[];
}

/** Categories that are not sections: "all" is the whole list; "draw" and "variable" are animation features. */
export const HIDDEN_SYMBOL_CATEGORIES: ReadonlySet<string> = new Set(["all", "draw", "variable"]);
/** The system category whose members have a multicolor variant. */
export const MULTICOLOR_CATEGORY = "multicolor";

/** The searchable items, one per name; `keywords` (aligned with `names`) join the search text. */
export function symbolItems(names: readonly string[], keywords: readonly string[] = []): SymbolItem[] {
  return names.map((name, index) => {
    const words = name.split(".");
    const extra = keywords[index] ? fold(keywords[index]).split(/\s+/u).filter(Boolean) : [];
    return {
      index,
      name,
      nameText: `\n${words.join(" ")}\n${name}`,
      searchText: `\n${words.join("\n")}\n${name}${extra.map((word) => `\n${word}`).join("")}`,
    };
  });
}

/** A bare name list (tests, gallery mocks) as a catalog with no keywords or categories. */
export function asCatalog(symbols: SymbolCatalog | readonly string[]): SymbolCatalog {
  return "names" in symbols ? symbols : { names: symbols };
}

/** How the Symbols tab draws symbols (remembered with the prefs). */
export type SymbolMode = "monochrome" | "hierarchical" | "multicolor";
export const SYMBOL_MODES: readonly SymbolMode[] = ["monochrome", "hierarchical", "multicolor"];

/** The mode a symbol is drawn in under `mode`: multicolor needs a symbol that has colors. */
export function symbolRendering(mode: SymbolMode, multicolor: boolean): SymbolMode {
  return mode === "multicolor" && !multicolor ? "monochrome" : mode;
}

export function isSymbolMode(value: unknown): value is SymbolMode {
  return typeof value === "string" && (SYMBOL_MODES as readonly string[]).includes(value);
}
