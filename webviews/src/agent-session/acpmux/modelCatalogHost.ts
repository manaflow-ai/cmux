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
// that does not know the method (an older app) leaves the bundled one in place.

/** The host's answer: the cached server catalog (null when the app has none yet), how it got it, and
 *  cmux.json `agentPane.models`. */
export type ModelCatalogDelivery = { catalog?: unknown; delivery?: unknown; user?: unknown };

type State = { catalog: ModelCatalog; user: unknown; provisional: boolean };

let state: State = { catalog: BUNDLED_MODEL_CATALOG, user: undefined, provisional: true };
const listeners = new Set<() => void>();
let pending: Promise<void> | undefined;
let reload: Promise<void> | undefined;

/** Folds a host answer or `models.catalog` event into the page's catalog. */
export function receiveModelCatalog(value: unknown): void {
  const delivery = (value ?? {}) as ModelCatalogDelivery;
  const catalog = readModelCatalog(delivery.catalog);
  // Older hosts can acknowledge a reload without a catalog. Once settled, that answer changes
  // nothing: notifying the external store would force a synchronous pane render during startup.
  if (!catalog && !state.provisional && state.user === (delivery.user ?? undefined)) return;
  const kind = delivery.delivery === "network" || delivery.delivery === "disk" ? delivery.delivery : undefined;
  state = {
    catalog: catalog ? { ...catalog, ...(kind ? { delivery: kind } : {}) } : state.catalog,
    user: delivery.user ?? undefined,
    provisional: false,
  };
  for (const listener of listeners) listener();
}

/** How long the page waits for acpmux's catalog, and for a refresh (two catalog URLs and the
 *  public feed, each up to 30 s, but usually a 304 in well under a second). A daemon that never
 *  answers must not hold `pending`, which every later load waits on. */
const ACPMUX_WAIT_MS = 15_000;
const ACPMUX_REFRESH_WAIT_MS = 45_000;

function withinTime<T>(promise: Promise<T>, ms: number): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const late = new Promise<never>((_, reject) => {
    // l10n-allow: a rejection the catalog loader handles, never drawn
    timer = setTimeout(() => reject(new Error(`no model catalog from acpmux in ${ms / 1000} s`)), ms);
  });
  return Promise.race([promise, late]).finally(() => clearTimeout(timer));
}

/** Asks the host for its catalog; one request at a time. `refresh` makes the host fetch first. A
 *  host that does not serve `models.catalog` (the app today) leaves it to acpmux's own catalog,
 *  through the pane's direct client: its copy with the public feed's newer models over it, so a
 *  model released today reaches the picker without a page or app update (user 2026-11-19: "gemini
 *  neon didn't automatically appear in model picker for us"). */
export function loadModelCatalog(refresh = false): Promise<void> {
  if (pending) return refresh ? pending.then(() => loadModelCatalog(true)) : pending;
  pending ??= postNative<ModelCatalogDelivery>("models.catalog", refresh ? { refresh: true } : {})
    .then(receiveModelCatalog, (error: unknown) => {
      const acpmux = window.cmuxAcpmuxActions?.["models.catalog"];
      // Any host refusal (unserved, not connected) still has acpmux's copy, which beats the bundle.
      if (!acpmux) throw error;
      return withinTime(acpmux({ refresh }), refresh ? ACPMUX_REFRESH_WAIT_MS : ACPMUX_WAIT_MS).then((reply) => {
        if (window.cmuxAcpmuxActions?.["models.catalog"] !== acpmux) return;
        const catalog = (reply as { catalog?: unknown } | undefined)?.catalog;
        // No catalog in the reply (an older acpmux) keeps the bundled one, still provisional.
        if (readModelCatalog(catalog)) receiveModelCatalog({ catalog, delivery: "network" });
      });
    })
    .finally(() => {
      pending = undefined;
    });
  return pending;
}

/** A connection or catalog event may arrive after an in-flight read took its snapshot. Read once
 * more after it settles, including after a refusal; coalesce events waiting on that same read. */
export function reloadModelCatalog(): Promise<void> {
  if (!pending) return loadModelCatalog();
  reload ??= pending
    .catch(() => undefined)
    .then(() => {
      reload = undefined;
      return loadModelCatalog();
    });
  return reload;
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

export function useModelCatalogState(): State {
  return useSyncExternalStore(
    subscribe,
    () => state,
    () => state,
  );
}

/** Test seam: the catalog the page holds now. */
export function modelCatalogStateForTests(): State {
  return state;
}

/** Test seam: back to the bundled catalog. */
export function resetModelCatalogForTests(): void {
  state = { catalog: BUNDLED_MODEL_CATALOG, user: undefined, provisional: true };
  pending = undefined;
  reload = undefined;
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
