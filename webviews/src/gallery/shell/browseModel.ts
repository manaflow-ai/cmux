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

/** A card's external frame link keeps the same env and tunables as its embedded stage. */
export function browseFrameHref(entry: GalleryEntry, variant: string, env: GalleryEnv, tune = ""): string {
  return `frame.html?${frameQuery({ entry: entry.id, variant, tune }, env)}`;
}
