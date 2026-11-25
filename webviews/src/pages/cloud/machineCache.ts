// The Cloud page's last known machine list, kept in the page's own storage so the next open draws it in
// its first frame (Leo, 2026-11-14: "load faster/percievably load faster / whatever it takes"). The
// owner's list replaces it as soon as it answers; it is only what the page last showed, never a source
// of truth: no action runs from it (`CloudStore.canChange` waits for the link), and a sign-out, another
// account or another team drops it.
import type { CloudMachine } from "./ops";

const KEY = "cmux.cloud.machines.v1";
/** A team with more machines than this keeps only the first ones: the cache is a first frame, not the list. */
export const CACHED_MACHINES_MAX = 200;

export interface CachedMachines {
  /** The team the list belongs to (`cloud.auth.status` `team`). */
  team: string | null;
  /** The signed-in user, when the account stream said who it is. */
  user?: string | null;
  machines: CloudMachine[];
  revision: number;
}

export type CacheStorage = Pick<Storage, "getItem" | "setItem" | "removeItem">;

export function readCachedMachines(storage: CacheStorage | undefined): CachedMachines | undefined {
  try {
    const raw = storage?.getItem(KEY);
    if (!raw) return undefined;
    const value = JSON.parse(raw) as Partial<CachedMachines> | null;
    if (!value || !Array.isArray(value.machines) || typeof value.revision !== "number") return undefined;
    const machines = value.machines.filter(
      (machine): machine is CloudMachine =>
        !!machine && typeof machine === "object" && typeof (machine as CloudMachine).id === "string",
    );
    if (machines.length === 0) return undefined;
    return {
      team: typeof value.team === "string" ? value.team : null,
      user: typeof value.user === "string" ? value.user : value.user === null ? null : undefined,
      machines,
      revision: value.revision,
    };
  } catch {
    return undefined;
  }
}

export function writeCachedMachines(storage: CacheStorage | undefined, value: CachedMachines): void {
  try {
    if (value.machines.length === 0) return storage?.removeItem(KEY);
    storage?.setItem(KEY, JSON.stringify({ ...value, machines: value.machines.slice(0, CACHED_MACHINES_MAX) }));
  } catch {
    // A full or refused store: the next open waits for the owner, as before.
  }
}

export function clearCachedMachines(storage: CacheStorage | undefined): void {
  try {
    storage?.removeItem(KEY);
  } catch {
    // Nothing kept, nothing to drop.
  }
}

/** The page's own `localStorage`, or none where it is absent or refuses. */
export function pageStorage(): CacheStorage | undefined {
  try {
    return typeof localStorage === "undefined" ? undefined : localStorage;
  } catch {
    return undefined;
  }
}
