import type { GalleryEntry } from "../format";
import { frameQuery, type GalleryEnv } from "../env";

export type BrowseItem = {
  entry: GalleryEntry;
  variant: string;
};

export type BrowseKind = "all" | "static" | "motion";
export type BrowseMode = "entries" | "variants";

export type BrowseState = {
  filter: string;
  kind: BrowseKind;
  mode: BrowseMode;
  cycle: boolean;
  page: number;
  picks: Record<string, string>;
};

export const DEFAULT_BROWSE: BrowseState = {
  filter: "",
  kind: "all",
  mode: "entries",
  cycle: false,
  page: 1,
  picks: {},
};

const BROWSE_QUERY_KEYS = [
  "browse-filter",
  "browse-kind",
  "browse-mode",
  "browse-cycle",
  "browse-page",
  "browse-pick",
] as const;

function readPick(value: string): [string, string] | undefined {
  const separator = value.indexOf("=");
  if (separator <= 0) return undefined;
  try {
    const entry = decodeURIComponent(value.slice(0, separator));
    const variant = decodeURIComponent(value.slice(separator + 1));
    return entry && variant ? [entry, variant] : undefined;
  } catch {
    return undefined;
  }
}

/** Read the contact-sheet controls that make a Browse URL reproducible. */
export function readBrowse(params: URLSearchParams): BrowseState {
  const kind = params.get("browse-kind");
  const mode = params.get("browse-mode");
  const page = Number(params.get("browse-page"));
  const picks: Record<string, string> = {};
  for (const value of params.getAll("browse-pick")) {
    const pick = readPick(value);
    if (pick) picks[pick[0]] = pick[1];
  }
  return {
    filter: (params.get("browse-filter") ?? "").trim(),
    kind: kind === "static" || kind === "motion" ? kind : DEFAULT_BROWSE.kind,
    mode: mode === "variants" ? mode : DEFAULT_BROWSE.mode,
    cycle: params.get("browse-cycle") === "1" || params.get("browse-cycle") === "true",
    page: Number.isInteger(page) && page > 0 ? page : DEFAULT_BROWSE.page,
    picks,
  };
}

/** Write only non-default contact-sheet controls, preserving unrelated query keys. */
export function writeBrowse(state: BrowseState, params = new URLSearchParams()): URLSearchParams {
  for (const key of BROWSE_QUERY_KEYS) params.delete(key);
  const filter = state.filter.trim();
  if (filter) params.set("browse-filter", filter);
  if (state.kind !== DEFAULT_BROWSE.kind) params.set("browse-kind", state.kind);
  if (state.mode !== DEFAULT_BROWSE.mode) params.set("browse-mode", state.mode);
  if (state.cycle) params.set("browse-cycle", "1");
  if (state.page !== DEFAULT_BROWSE.page) params.set("browse-page", String(state.page));
  for (const [entry, variant] of Object.entries(state.picks).sort(([a], [b]) => a.localeCompare(b)))
    if (entry && variant) params.append("browse-pick", `${encodeURIComponent(entry)}=${encodeURIComponent(variant)}`);
  return params;
}

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
function browseMatchedVariant(variants: readonly string[], query: string): string | undefined {
  const needle = query.trim().toLowerCase();
  if (!needle) return undefined;
  return variants.find((variant) => variant.toLowerCase().includes(needle));
}

function browseKindMatches(item: BrowseItem, kind: BrowseKind): boolean {
  return kind === "all" || browseItemHasMotion(item) === (kind === "motion");
}

/** Filter contact-sheet cards by text and available motion, without changing the stable
 * recommended variant unless the query or kind selects another matching variant. */
export function filterBrowseItems(
  entries: readonly GalleryEntry[],
  query: string,
  kind: BrowseKind = "all",
  mode: BrowseMode = "entries",
  picks: Readonly<Record<string, string>> = {},
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
        browseMatches(item, query) && (!variantQuery || variantQuery.size === 0 || variantQuery.has(item.variant)),
    )
    .flatMap((item) => {
      if (mode === "variants") return browseKindMatches(item, kind) ? [item] : [];
      const variants = Object.keys(item.entry.variants).filter((variant) =>
        browseKindMatches({ entry: item.entry, variant }, kind),
      );
      const variant =
        browseMatchedVariant(variants, query) ??
        (picks[item.entry.id] && variants.includes(picks[item.entry.id]!) ? picks[item.entry.id] : undefined) ??
        (variants.includes(item.variant) ? item.variant : variants[0]);
      return variant ? [{ ...item, variant }] : [];
    });
}

/** A card's external frame link keeps the same env and tunables as its embedded stage. */
export function browseFrameHref(
  entry: GalleryEntry,
  variant: string,
  env: GalleryEnv,
  tune = "",
  source?: string,
): string {
  return `frame.html?${frameQuery({ entry: entry.id, variant, tune, source }, env)}`;
}
