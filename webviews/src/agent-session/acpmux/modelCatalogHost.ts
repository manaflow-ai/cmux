import { useMemo, useSyncExternalStore } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { postNative } from "./native";
import { NativeError } from "./nativeError";
import type { AcpmuxSnapshot } from "./model";
import {
  BUNDLED_MODEL_CATALOG,
  buildPickerCatalog,
  workedProfiles,
  readModelCatalog,
  type ModelCatalog,
  type PickerCatalog,
} from "./modelCatalogData";

// The model catalog the app host delivers (`models.catalog`: request and host event), held once per
// page. Until the host answers, the snapshot bundled with the page stands in (`provisional`); a host
// that does not know the method (an older app) leaves the bundled one in place. The host's last
// answer is kept in localStorage and stands in first: the model chip's name and effort come from
// the catalog, so a relaunched chat drew them from the bundled one and widened when the host
// answered (143 to 154 px, ask-66b7d014c3). It stays provisional, so the host is still asked.

/** The host's answer: the cached server catalog (null when the app has none yet), how it got it, and
 *  cmux.json `agentPane.models`. */
export type ModelCatalogDelivery = { catalog?: unknown; delivery?: unknown; user?: unknown };

type State = { catalog: ModelCatalog; user: unknown; provisional: boolean };

const STORAGE_KEY = "cmux.acpmux.modelCatalog";

function remembered(): State {
  try {
    const kept = JSON.parse(globalThis.localStorage?.getItem(STORAGE_KEY) ?? "null") as ModelCatalogDelivery | null;
    const catalog = kept && readModelCatalog(kept.catalog);
    if (catalog) return { catalog, user: kept.user ?? undefined, provisional: true };
  } catch {
    // An unreadable entry: the bundled catalog, as on a first launch.
  }
  return { catalog: BUNDLED_MODEL_CATALOG, user: undefined, provisional: true };
}

function remember(delivery: ModelCatalogDelivery): void {
  try {
    globalThis.localStorage?.setItem(STORAGE_KEY, JSON.stringify({ catalog: delivery.catalog, user: delivery.user }));
  } catch {
    // Storage full or off: the next launch starts on the bundled catalog.
  }
}

let state: State = remembered();
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
  if (catalog) remember(delivery);
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

/** A host that does not know `models.catalog` (the app today) refuses it as an invalid request. */
function keepBundledWhenUnserved(error: unknown): void {
  if (error instanceof NativeError && error.code === "native.invalid_request") return;
  throw error;
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  if (state.provisional) void loadModelCatalog().catch(() => undefined);
  return () => listeners.delete(listener);
}

/** The catalog a render reads now. */
export function modelCatalogState(): State {
  return state;
}

export function useModelCatalogState(): State {
  return useSyncExternalStore(subscribe, modelCatalogState, modelCatalogState);
}

/** Test seam: back to the bundled catalog, or with `relaunch` to what a new page starts on (the
 *  remembered answer). */
export function resetModelCatalogForTests(relaunch = false): void {
  if (!relaunch) globalThis.localStorage?.removeItem(STORAGE_KEY);
  state = remembered();
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
    /** The model the session reports running (summary.model). */
    model?: string;
    configOptions?: NonNullable<AcpmuxSnapshot["summary"]>["configOptions"];
  },
  /** acpmux's chats: a provider's pick starts the profile its chats last completed a turn on. */
  sessions: AcpmuxSnapshot["sessions"] = [],
): { catalog: PickerCatalog; date?: string; refresh(): Promise<void> } {
  const { catalog, user, provisional } = useModelCatalogState();
  const queryClient = useQueryClient();
  const workedKey = workedProfiles(sessions).join("\n");
  const picker = useMemo(
    () =>
      buildPickerCatalog({
        catalog,
        user,
        acpmux,
        session,
        worked: workedKey ? workedKey.split("\n") : [],
        provisional,
      }),
    [catalog, user, acpmux, session, workedKey, provisional],
  );
  return {
    catalog: picker,
    date: catalog.generatedAt,
    async refresh() {
      // The agents' live lists: the pane's direct client re-probes them; without one the catalog
      // only re-reads. A host without `models.catalog` keeps the bundled catalog, which is no failure.
      const probe = window.cmuxAcpmuxActions?.["models.refresh"];
      await Promise.all([
        loadModelCatalog(true).catch(keepBundledWhenUnserved),
        probe ? probe({}) : queryClient.invalidateQueries({ queryKey: ["acpmux", "harnesses"] }),
      ]);
    },
  };
}
