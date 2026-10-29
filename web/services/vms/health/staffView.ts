import * as Effect from "effect/Effect";
import type { StoredVmHealthReport, VmHealthReport } from "./types";
import { vmHealthRepositoryMethods } from "./repository";

/** A snapshot older than this means the cron stopped; the page says so. */
export const VM_HEALTH_STALE_AFTER_MS = 15 * 60 * 1000;
/** Owner email lookups per page read; the rest show their user id. */
export const VM_HEALTH_OWNER_LOOKUP_LIMIT = 60;
const OWNER_LOOKUP_CONCURRENCY = 5;
const OWNER_LOOKUP_TIMEOUT_MS = 3_000;

export type VmHealthOwnerContact = {
  readonly email: string | null;
  readonly displayName: string | null;
};

export type VmHealthStaffView = {
  readonly snapshot: {
    readonly id: string;
    readonly createdAt: string;
    readonly ageSeconds: number;
    readonly stale: boolean;
  } | null;
  readonly report: VmHealthReport | null;
  /** Keyed by cmux user id. Only staff ever receive this map. */
  readonly owners: Readonly<Record<string, VmHealthOwnerContact>>;
};

export type VmHealthStaffViewDeps = {
  readonly latest: () => Promise<StoredVmHealthReport | null>;
  readonly lookupOwner: (userId: string) => Promise<VmHealthOwnerContact | null>;
  readonly now: () => Date;
};

/**
 * The staff page's read: the newest stored sweep and owner contacts for the
 * VMs it flags. Never probes the provider. Callers must have passed the admin
 * gate; this function does not check authorization itself.
 */
export async function readVmHealthStaffView(deps: VmHealthStaffViewDeps): Promise<VmHealthStaffView> {
  const stored = await deps.latest();
  if (!stored) return { snapshot: null, report: null, owners: {} };
  const ageMs = Math.max(0, deps.now().getTime() - stored.createdAt.getTime());
  const userIds = flaggedOwnerIds(stored.report).slice(0, VM_HEALTH_OWNER_LOOKUP_LIMIT);
  const owners: Record<string, VmHealthOwnerContact> = {};
  await mapBounded(userIds, OWNER_LOOKUP_CONCURRENCY, async (userId) => {
    const contact = await withTimeout(deps.lookupOwner(userId), OWNER_LOOKUP_TIMEOUT_MS).catch(() => null);
    if (contact) owners[userId] = contact;
  });
  return {
    snapshot: {
      id: stored.id,
      createdAt: stored.createdAt.toISOString(),
      ageSeconds: Math.floor(ageMs / 1000),
      stale: ageMs > VM_HEALTH_STALE_AFTER_MS,
    },
    report: stored.report,
    owners,
  };
}

/** Owners of flagged VMs, most urgent list first, deduplicated. */
export function flaggedOwnerIds(report: VmHealthReport): string[] {
  const ids = new Set<string>();
  for (const entry of [...report.hung, ...report.stuck, ...report.drift, ...(report.tls?.pausedHolders.top ?? [])]) {
    if (entry.owner?.userId) ids.add(entry.owner.userId);
  }
  return [...ids];
}

export function latestStoredVmHealthReport(): Promise<StoredVmHealthReport | null> {
  return Effect.runPromise(vmHealthRepositoryMethods.latestVmHealthSnapshot());
}

async function mapBounded<T>(items: readonly T[], concurrency: number, run: (item: T) => Promise<void>): Promise<void> {
  let next = 0;
  const worker = async () => {
    while (next < items.length) {
      const item = items[next++]!;
      await run(item);
    }
  };
  await Promise.all(Array.from({ length: Math.min(concurrency, items.length) }, worker));
}

function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error("timeout")), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}
