// The host reads each Settings section needs before it draws, as shared TanStack Query options.
// The section route's loader ensures them (router.ts), so a hover or keyboard focus on a sidebar
// link reads them ahead of the click, and the card that draws them (useQuery with the same
// options) finds them in the cache: no card mounts empty and fills in a frame later.
import { queryOptions, type QueryClient } from "@tanstack/react-query";
import { categoryById, homes, categoryOf } from "./categories";
import { personalizationPartOf } from "./personalizationParts";
import type { AgentsState, ChannelsState, SharesState, TailnetState } from "./ops";
import { settingsKeys } from "./queries";
import type { SettingsStore } from "./store";

/** How long a section's host read counts as fresh: long enough that the read a hover started is
 * the one the click shows (no second read on mount), short enough that the next visit refreshes
 * it in the background (stale-while-revalidate: the cached value shows at once). */
export const SECTION_READ_FRESH_MS = 5_000;

type SectionAction = { id: string; title: string; enabled: boolean; hint?: string | null };

/** The section's registry buttons (Reload Configuration, Import from Browser, ...). */
export function sectionActionsQuery(store: SettingsStore, section: string) {
  return queryOptions<SectionAction[]>({
    queryKey: [...settingsKeys.all, "section-actions", section],
    queryFn: () => store.sectionActions(section),
    staleTime: SECTION_READ_FRESH_MS,
    structuralSharing: true,
  });
}

/** Settings > Updates' channels for the picked `ring` (null: the host has no updater). */
export function channelsQuery(store: SettingsStore, ring: string | undefined) {
  return queryOptions<ChannelsState | null>({
    queryKey: [...settingsKeys.all, "channels", ring ?? null],
    queryFn: () => store.channelsState(ring),
    staleTime: SECTION_READ_FRESH_MS,
    structuralSharing: true,
  });
}

/** The Agents state's key; the card's live pushes and gestures write it. */
export const AGENTS_KEY = [...settingsKeys.all, "agents"] as const;

/** Settings > Agents' state (null: the host has no Agents part). */
export function agentsQuery(store: SettingsStore) {
  return queryOptions<AgentsState | null>({
    queryKey: AGENTS_KEY,
    queryFn: () => store.agentsState(),
    staleTime: SECTION_READ_FRESH_MS,
    structuralSharing: true,
  });
}

/** This Mac on Your Tailnet's key; each sign-in step writes its answer here. */
export const TAILNET_KEY = [...settingsKeys.all, "tailnet"] as const;

/** Settings > Server > This Mac on Your Tailnet: the node's snapshot (null: no tailnet here). */
export function tailnetQuery(store: SettingsStore) {
  return queryOptions<TailnetState | null>({
    queryKey: TAILNET_KEY,
    queryFn: () => store.tailnet("state"),
    staleTime: SECTION_READ_FRESH_MS,
    structuralSharing: true,
  });
}

/** The Shared Links list's key; a revoke refreshes it. */
export const SHARES_KEY = [...settingsKeys.all, "shares"] as const;

/** Settings > Privacy and Security > Shared Links: this Mac's chat shares (null: the host has none). */
export function sharesQuery(store: SettingsStore) {
  return queryOptions<SharesState | null>({
    queryKey: SHARES_KEY,
    queryFn: () => store.shares(),
    staleTime: SECTION_READ_FRESH_MS,
    structuralSharing: true,
  });
}

/** The section a route shows: the focused key's home, else the path's category or schema section. */
export function routeSection(section: string | undefined, focus: string | undefined | null): string {
  // Personalization is the one page that draws the theme, background, density, Chief pet and sounds
  // rows: a link to one of them (a search result, the CLI, the palette, MCP) opens it there, and a
  // link to Personalization with any key stays on it.
  if ((focus && personalizationPartOf(focus)) || (section && categoryOf(section) === "personalization"))
    return "personalization";
  const home = focus ? homes.get(focus) : undefined;
  return home?.category ?? categoryOf(section);
}

/** One read a section draws from: its query options, and whether a stale copy refreshes. */
export type SectionRead = { options: { queryKey: readonly unknown[] }; revalidate: boolean };

/** Every read `section` draws from; empty for a section with only schema rows. */
export function sectionReads(store: SettingsStore, section: string): SectionRead[] {
  const category = categoryById(section);
  const cards = new Set([...category.lead, ...category.trail]);
  const reads: SectionRead[] = [];
  // The store's own keys (theme colors, accounts, harnesses) read through its query defaults and
  // stay fresh until the host pushes a change; the per-section host reads refresh when stale.
  for (const id of category.actions) reads.push({ options: sectionActionsQuery(store, id), revalidate: true });
  if (cards.has("themeStudio") || cards.has("personalization"))
    reads.push({ options: { queryKey: settingsKeys.themeColors }, revalidate: false });
  if (cards.has("accounts")) reads.push({ options: { queryKey: settingsKeys.accounts }, revalidate: false });
  if (cards.has("harnesses")) reads.push({ options: { queryKey: settingsKeys.harnesses }, revalidate: false });
  if (cards.has("agentHarnesses")) reads.push({ options: agentsQuery(store), revalidate: true });
  if (cards.has("sharedLinks")) reads.push({ options: sharesQuery(store), revalidate: true });
  if (cards.has("tailnet")) reads.push({ options: tailnetQuery(store), revalidate: true });
  if (cards.has("channels")) {
    const ring = store.getSnapshot().rows.get("updates.channel")?.value;
    reads.push({ options: channelsQuery(store, typeof ring === "string" ? ring : undefined), revalidate: true });
  }
  return reads;
}

/**
 * Ensures every read `section` draws from is in the cache: cached data answers at once (a stale
 * one refreshes in the background), a missing one is read. Never rejects: a failed read shows as
 * its card's own empty state, never as a route error.
 */
export async function ensureSection(queryClient: QueryClient, store: SettingsStore, section: string): Promise<void> {
  await Promise.all(
    sectionReads(store, section).map(({ options, revalidate }) =>
      queryClient.ensureQueryData({ ...options, revalidateIfStale: revalidate }).catch(() => undefined),
    ),
  );
}
