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

/** Keep a card on a real variant after a registry refresh removes its selected state. */
export function resolveBrowseVariant(
  current: string,
  fallback: string | undefined,
  variants: readonly string[],
): string | undefined {
  if (variants.includes(current)) return current;
  if (fallback && variants.includes(fallback)) return fallback;
  return variants[0];
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

/** Match the contact sheet's human-facing entry and variant labels. */
export function browseMatches(item: BrowseItem, query: string): boolean {
  const needle = query.trim().toLowerCase();
  if (!needle) return true;
  const variants = Object.keys(item.entry.variants).join(" ");
  return `${item.entry.area} ${item.entry.title} ${item.entry.id} ${variants}`.toLowerCase().includes(needle);
}

/** Filter contact-sheet cards by text and available motion, without changing the stable
 * recommended variant for each entry. */
export function filterBrowseItems(
  entries: readonly GalleryEntry[],
  query: string,
  kind: BrowseKind = "all",
): BrowseItem[] {
  return browseItems(entries).filter(
    (item) =>
      browseMatches(item, query) &&
      (kind === "all" || (kind === "motion" ? browseHasMotion(item.entry) : !browseHasMotion(item.entry))),
  );
}

/** A card's external frame link keeps the same env and tunables as its embedded stage. */
export function browseFrameHref(entry: GalleryEntry, variant: string, env: GalleryEnv, tune = ""): string {
  return `frame.html?${frameQuery({ entry: entry.id, variant, tune }, env)}`;
}
