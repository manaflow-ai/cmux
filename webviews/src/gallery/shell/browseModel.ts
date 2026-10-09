import type { GalleryEntry } from "../format";
import { frameQuery, type GalleryEnv } from "../env";

export type BrowseItem = {
  entry: GalleryEntry;
  variant: string;
};

/** The variant a contact-sheet card starts on: the recorded recommendation, otherwise the first. */
export function browseVariant(entry: GalleryEntry): string | undefined {
  const variants = Object.keys(entry.variants);
  return entry.pick?.recommendedId && variants.includes(entry.pick.recommendedId)
    ? entry.pick.recommendedId
    : variants[0];
}

/** Stable card data for ready registry entries. Empty entries cannot produce a useful stage. */
export function browseItems(entries: readonly GalleryEntry[]): BrowseItem[] {
  return entries.flatMap((entry) => {
    const variant = browseVariant(entry);
    return variant ? [{ entry, variant }] : [];
  });
}

/** Match the contact sheet's human-facing entry and variant labels. */
export function browseMatches(item: BrowseItem, query: string): boolean {
  const needle = query.trim().toLowerCase();
  if (!needle) return true;
  return `${item.entry.area} ${item.entry.title} ${item.entry.id} ${item.variant}`.toLowerCase().includes(needle);
}

/** Filter contact-sheet cards without changing the stable recommended variant for each entry. */
export function filterBrowseItems(entries: readonly GalleryEntry[], query: string): BrowseItem[] {
  return browseItems(entries).filter((item) => browseMatches(item, query));
}

/** A card's external frame link keeps the same env and tunables as its embedded stage. */
export function browseFrameHref(entry: GalleryEntry, variant: string, env: GalleryEnv, tune = ""): string {
  return `frame.html?${frameQuery({ entry: entry.id, variant, tune }, env)}`;
}
