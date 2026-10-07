import { keepPreviousData, QueryClient, useQuery } from "@tanstack/react-query";
import { useMemo } from "react";
import type { AcpmuxSnapshot } from "./model";

// TanStack Query holds acpmux server state the pane reads on request: today the
// harness and model catalog. The transcript, session list, queue and permission
// stay in the direct client's snapshot, because acpmux streams them over the
// watch/attach subscription and the client folds every update in order; a
// query cache in front of that stream would only add a second copy to keep in
// sync. Older history pages also stay there: they merge into the same
// transcript rows rather than standing alone.

export type HarnessCatalog = AcpmuxSnapshot["catalog"];
/// `cwd`: the chat's folder; the reply then also lists that folder's profiles (`folder` entries).
export type HarnessCatalogSource = { harnesses(cwd?: string): Promise<HarnessCatalog> };

/** How long a fetched catalog counts as fresh. After that, focusing the pane refetches it. */
export const HARNESS_CATALOG_STALE_MS = 60_000;

export function createPaneQueryClient(): QueryClient {
  // One retry: a failed request usually means the socket closed, and the pane
  // makes a new client (and so a new query key) when it reconnects.
  return new QueryClient({ defaultOptions: { queries: { retry: 1 } } });
}

const CATALOG_KEY = "cmux.acpmux.harnessCatalog.v1";

/// The last catalog the pane fetched, kept per viewer so the model picker opens with real data
/// before acpmux answers (stale-while-revalidate: the query refetches it in the background).
/// Each harness keeps its own models: a fetch whose model probe has not finished for a harness
/// (no models yet) keeps that harness's cached ones, and a harness acpmux no longer lists is
/// dropped. Storage can be missing or blocked; then nothing is cached. In the app the pane's web
/// view has a non-persistent data store, so this cache lasts one app session: the first pane after
/// a launch fetches before its picker has models. A host-backed store is a follow-up.
export class HarnessCatalogCache {
  private memory: { catalog: HarnessCatalog; at: number } | undefined;
  private loaded = false;
  constructor(private readonly storage: () => Storage | undefined = defaultStorage) {}

  read(): { catalog: HarnessCatalog; at: number } | undefined {
    if (this.loaded) return this.memory;
    this.loaded = true;
    try {
      const value = JSON.parse(this.storage()?.getItem(CATALOG_KEY) ?? "null") as {
        catalog?: unknown;
        at?: unknown;
      } | null;
      if (value && Array.isArray(value.catalog) && typeof value.at === "number")
        this.memory = { catalog: value.catalog as HarnessCatalog, at: value.at };
    } catch {
      // A broken entry reads as none; the next fetch writes a good one.
    }
    return this.memory;
  }

  /// `fresh` with each harness's cached models where `fresh` has none yet; stored for next time.
  /// A folder's profiles pass through but are never stored: they belong to one chat's folder.
  merge(fresh: HarnessCatalog, at: number): HarnessCatalog {
    const cached = new Map((this.read()?.catalog ?? []).map((entry) => [entry.id, entry]));
    const profiles = fresh.filter((entry) => entry.folder);
    const merged = fresh
      .filter((entry) => !entry.folder)
      .map((entry) =>
        entry.models.length > 0 || !cached.get(entry.id)?.models.length
          ? entry
          : { ...entry, models: cached.get(entry.id)!.models },
      );
    this.memory = { catalog: merged, at };
    try {
      this.storage()?.setItem(CATALOG_KEY, JSON.stringify(this.memory));
    } catch {
      // Private windows and blocked storage keep the catalog for this page only.
    }
    return profiles.length > 0 ? [...merged, ...profiles] : merged;
  }
}

function defaultStorage(): Storage | undefined {
  try {
    return globalThis.localStorage;
  } catch {
    return undefined;
  }
}

/// The pane's catalog cache.
export const harnessCatalogCache = new HarnessCatalogCache();

/** Key per direct client: a reconnect to a restarted daemon fetches its catalog fresh. A chat
 *  folder (`cwd`) gets its own entry, since its folder profiles differ. */
export function harnessCatalogKey(clientId: number, cwd?: string) {
  return cwd ? (["acpmux", "harnesses", clientId, cwd] as const) : (["acpmux", "harnesses", clientId] as const);
}

/// Whether a folder profile from `folder` applies to a chat in `cwd` (the folder or inside it).
export function profileCovers(folder: string, cwd: string | undefined): boolean {
  if (!cwd) return false;
  const root = folder.endsWith("/") ? folder.slice(0, -1) : folder;
  return cwd === root || cwd.startsWith(`${root}/`);
}

/**
 * The harness catalog for the composer's model picker. With a direct client it
 * comes from acpmux through the query cache; without one (the Swift bridge or
 * the mock host push it in the snapshot) the snapshot's catalog is used as is. Until either
 * arrives, the catalog cached from the last fetch stands in (`cache`), and a client's first
 * fetch starts from it as stale data. With `cwd` (the chat's folder) the catalog also lists that
 * folder's profiles; a profile of another folder (the previous chat's, kept while the new
 * folder's fetch runs) is never shown.
 */
export function useHarnessCatalog(
  source: { id: number; client: HarnessCatalogSource } | undefined,
  snapshotCatalog: HarnessCatalog,
  cache: HarnessCatalogCache = harnessCatalogCache,
  cwd?: string,
): HarnessCatalog {
  const query = useQuery({
    queryKey: harnessCatalogKey(source?.id ?? 0, cwd),
    queryFn: async () => cache.merge(await source!.client.harnesses(cwd), Date.now()),
    enabled: source !== undefined,
    staleTime: HARNESS_CATALOG_STALE_MS,
    // The cached catalog draws at once and counts as stale, so every client fetches its own.
    initialData: () => cache.read()?.catalog,
    initialDataUpdatedAt: 0,
    // A new client's catalog replaces the last one when it arrives, so the
    // model picker does not empty out across a reconnect.
    placeholderData: keepPreviousData,
  });
  const cached = () => cache.read()?.catalog ?? snapshotCatalog;
  let catalog: HarnessCatalog;
  if (!source) catalog = snapshotCatalog.length > 0 ? snapshotCatalog : cached();
  // Until this client's fetch lands, a catalog the host pushed wins over the cached one.
  else if (query.dataUpdatedAt === 0 && snapshotCatalog.length > 0) catalog = snapshotCatalog;
  else catalog = query.data ?? cached();
  return useMemo(
    () =>
      catalog.some((entry) => entry.folder && !profileCovers(entry.folder.folder, cwd))
        ? catalog.filter((entry) => !entry.folder || profileCovers(entry.folder.folder, cwd))
        : catalog,
    [catalog, cwd],
  );
}
