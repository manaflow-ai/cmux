import { useMemo, useSyncExternalStore } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { postNative } from "./native";
import type { AcpmuxSnapshot } from "./model";
import {
  BUNDLED_MODEL_CATALOG,
  buildPickerCatalog,
  readModelCatalog,
  type ModelCatalog,
  type PickerCatalog,
} from "./modelCatalogData";

// The model catalog the app host delivers (`models.catalog`: request and host event), held once per
// page. Until the host answers, the snapshot bundled with the page stands in (`provisional`); a host
// that does not know the method (an older app) leaves the bundled one in place.

/** The host's answer: the cached server catalog (null when the app has none yet), how it got it, and
 *  cmux.json `agentPane.models`. */
export type ModelCatalogDelivery = { catalog?: unknown; delivery?: unknown; user?: unknown };

type State = { catalog: ModelCatalog; user: unknown; provisional: boolean };

let state: State = { catalog: BUNDLED_MODEL_CATALOG, user: undefined, provisional: true };
const listeners = new Set<() => void>();
let pending: Promise<void> | undefined;

/** Folds a host answer or `models.catalog` event into the page's catalog. */
export function receiveModelCatalog(value: unknown): void {
  const delivery = (value ?? {}) as ModelCatalogDelivery;
  const catalog = readModelCatalog(delivery.catalog);
  const kind = delivery.delivery === "network" || delivery.delivery === "disk" ? delivery.delivery : undefined;
  state = {
    catalog: catalog ? { ...catalog, ...(kind ? { delivery: kind } : {}) } : state.catalog,
    user: delivery.user ?? undefined,
    provisional: false,
  };
  for (const listener of listeners) listener();
}

/** Asks the host for its catalog; one request at a time. `refresh` makes the host fetch first. */
export function loadModelCatalog(refresh = false): Promise<void> {
  if (pending) return refresh ? pending.then(() => loadModelCatalog(true)) : pending;
  pending ??= postNative<ModelCatalogDelivery>("models.catalog", refresh ? { refresh: true } : {})
    .then(receiveModelCatalog)
    .finally(() => {
      pending = undefined;
    });
  return pending;
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  if (state.provisional) void loadModelCatalog().catch(() => undefined);
  return () => listeners.delete(listener);
}

export function useModelCatalogState(): State {
  return useSyncExternalStore(
    subscribe,
    () => state,
    () => state,
  );
}

/** Test seam: back to the bundled catalog. */
export function resetModelCatalogForTests(): void {
  state = { catalog: BUNDLED_MODEL_CATALOG, user: undefined, provisional: true };
  pending = undefined;
}

/**
 * The picker's data (CONTRACT section 3). `refresh()` is for the picker's open: it re-asks the host
 * for the catalog and acpmux for its harness list (profiles can change while the pane is open; a
 * push event from acpmux will replace this re-fetch later).
 */
export function usePickerCatalog(
  acpmux: AcpmuxSnapshot["catalog"],
  session?: {
    harness?: string;
    configOptions?: NonNullable<AcpmuxSnapshot["summary"]>["configOptions"];
  },
): { catalog: PickerCatalog; date?: string; refresh(): Promise<void> } {
  const { catalog, user, provisional } = useModelCatalogState();
  const queryClient = useQueryClient();
  const picker = useMemo(
    () => buildPickerCatalog({ catalog, user, acpmux, session, provisional }),
    [catalog, user, acpmux, session, provisional],
  );
  return {
    catalog: picker,
    date: catalog.generatedAt,
    async refresh() {
      await Promise.all([loadModelCatalog(true), queryClient.invalidateQueries({ queryKey: ["acpmux", "harnesses"] })]);
    },
  };
}
