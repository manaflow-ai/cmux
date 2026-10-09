import type { GalleryEntry } from "../format";
import { frameQuery, type GalleryEnv } from "../env";

export type BrowseItem = {
  entry: GalleryEntry;
  variant: string;
};

export type BrowseKind = "all" | "static" | "motion";

/** Whether an entry has a recorded play sequence in any of its variants. */
export function browseHasMotion(entry: GalleryEntry): boolean {
  return Object.values(entry.variants).some((variant) => Boolean(variant.play));
}

/** Advance a card to the next real variant, wrapping so a cycle never invents a state. */
export function nextBrowseVariant(current: string, variants: readonly string[]): string | undefined {
  if (variants.length === 0) return undefined;
  const index = variants.indexOf(current);
  return variants[(index + 1 + variants.length) % variants.length] ?? variants[0];
}

/** Filter contact-sheet cards by their stable title/id/area text and available motion. */
export function filterBrowseItems(items: readonly BrowseItem[], query: string, kind: BrowseKind): BrowseItem[] {
  const needle = query.trim().toLowerCase();
  return items.filter(({ entry }) => {
    const text = `${entry.area} ${entry.title} ${entry.id}`.toLowerCase();
    const matchesText = !needle || text.includes(needle);
    const matchesKind = kind === "all" || (kind === "motion" ? browseHasMotion(entry) : !browseHasMotion(entry));
    return matchesText && matchesKind;
  });
}

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
