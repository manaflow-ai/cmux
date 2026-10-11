import type { GalleryEntry } from "../format";
import { frameQuery, type GalleryEnv } from "../env";

export type BrowseItem = {
  entry: GalleryEntry;
  variant: string;
};

export type BrowseKind = "all" | "static" | "motion";
export type BrowseMode = "entries" | "variants";

/** Whether an entry has a recorded play sequence in any of its variants. */
export function browseHasMotion(entry: GalleryEntry): boolean {
  return Object.values(entry.variants).some((variant) => Boolean(variant.play));
}

/** Whether the concrete card variant has a recorded play sequence. */
export function browseItemHasMotion(item: BrowseItem): boolean {
  return Boolean(item.entry.variants[item.variant]?.play);
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
export function browseItems(entries: readonly GalleryEntry[], mode: BrowseMode = "entries"): BrowseItem[] {
  return entries.flatMap((entry) => {
    if (mode === "variants") {
      return Object.keys(entry.variants).map((variant) => ({ entry, variant }));
    }
    const variant = browseVariant(entry);
    return variant ? [{ entry, variant }] : [];
  });
}

/** Match the contact sheet's human-facing entry and variant labels. */
export function browseMatches(item: BrowseItem, query: string): boolean {
  const needle = query.trim().toLowerCase();
  if (!needle) return true;
  const variants = Object.keys(item.entry.variants).join(" ");
  return `${item.entry.area} ${item.entry.title} ${item.entry.id} ${variants} ${item.variant}`
    .toLowerCase()
    .includes(needle);
}

/** Prefer the first variant named by a query so a filtered card shows the state being searched for. */
function browseMatchedVariant(item: BrowseItem, query: string): string | undefined {
  const needle = query.trim().toLowerCase();
  if (!needle) return undefined;
  return Object.keys(item.entry.variants).find((variant) => variant.toLowerCase().includes(needle));
}

/** Filter contact-sheet cards by text and available motion, without changing the stable
 * recommended variant for each entry unless the query names one of its variants. */
export function filterBrowseItems(
  entries: readonly GalleryEntry[],
  query: string,
  kind: BrowseKind = "all",
  mode: BrowseMode = "entries",
): BrowseItem[] {
  const needle = query.trim().toLowerCase();
  const variantQuery =
    mode === "variants" && needle
      ? new Set(
          entries.flatMap((entry) =>
            Object.keys(entry.variants).filter((variant) => variant.toLowerCase().includes(needle)),
          ),
        )
      : undefined;
  return browseItems(entries, mode)
    .filter(
      (item) =>
        browseMatches(item, query) &&
        (!variantQuery || variantQuery.size === 0 || variantQuery.has(item.variant)) &&
        (kind === "all" ||
          (kind === "motion"
            ? mode === "variants"
              ? browseItemHasMotion(item)
              : browseHasMotion(item.entry)
            : mode === "variants"
              ? !browseItemHasMotion(item)
              : !browseHasMotion(item.entry))),
    )
    .map((item) =>
      mode === "entries" ? { ...item, variant: browseMatchedVariant(item, query) ?? item.variant } : item,
    );
}

/** A card's external frame link keeps the same env and tunables as its embedded stage. */
export function browseFrameHref(entry: GalleryEntry, variant: string, env: GalleryEnv, tune = ""): string {
  return `frame.html?${frameQuery({ entry: entry.id, variant, tune }, env)}`;
}
