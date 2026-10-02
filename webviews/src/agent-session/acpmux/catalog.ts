import { QueryClient, useQuery } from "@tanstack/react-query";
import type { AcpmuxSnapshot } from "./model";

// TanStack Query holds acpmux server state the pane reads on request: today the
// harness and model catalog. The transcript, session list, queue and permission
// stay in the direct client's snapshot, because acpmux streams them over the
// watch/attach subscription and the client folds every update in order; a
// query cache in front of that stream would only add a second copy to keep in
// sync. Older history pages also stay there: they merge into the same
// transcript rows rather than standing alone.

export type HarnessCatalog = AcpmuxSnapshot["catalog"];
export type HarnessCatalogSource = { harnesses(): Promise<HarnessCatalog> };

/** How long a fetched catalog counts as fresh. After that, focusing the pane refetches it. */
export const HARNESS_CATALOG_STALE_MS = 60_000;

export function createPaneQueryClient(): QueryClient {
  // One retry: a failed request usually means the socket closed, and the pane
  // makes a new client (and so a new query key) when it reconnects.
  return new QueryClient({ defaultOptions: { queries: { retry: 1 } } });
}

/** Key per direct client: a reconnect to a restarted daemon fetches its catalog fresh. */
export function harnessCatalogKey(clientId: number) {
  return ["acpmux", "harnesses", clientId] as const;
}

/**
 * The harness catalog for the composer's model picker. With a direct client it
 * comes from acpmux through the query cache; without one (the Swift bridge or
 * the mock host push it in the snapshot) the snapshot's catalog is used as is.
 */
export function useHarnessCatalog(
  source: { id: number; client: HarnessCatalogSource } | undefined,
  snapshotCatalog: HarnessCatalog,
): HarnessCatalog {
  const query = useQuery({
    queryKey: harnessCatalogKey(source?.id ?? 0),
    queryFn: () => source!.client.harnesses(),
    enabled: source !== undefined,
    staleTime: HARNESS_CATALOG_STALE_MS,
  });
  if (!source) return snapshotCatalog;
  return query.data ?? snapshotCatalog;
}
