// Realtime Cloud machine list publication to the presence Worker.
//
// The Mac machines list subscribes to the `vms` sync collection on the
// per-team presence Durable Object instead of polling `GET /api/vm`. Postgres
// stays the source of truth; this module pushes each list-relevant
// `cloud_vms` write (and, after every list read, the full visible list) to
// `POST /v1/sync/vms` on the Worker (`workers/presence/src/syncVms.ts`).
//
// Publication is best-effort and never fails a mutation: it runs after the
// response (`runAfterResponse`), with a short timeout, and a Worker outage only
// delays the next list convergence (the Mac still has its REST list). The
// Worker is service-to-service authenticated with
// `CMUX_PRESENCE_VMS_PUBLISHER_SECRET` (no user bearer: cron reconcilers have
// none), so the body's `teamId` is the list scope the Worker trusts. Each op
// carries the row's `updated_at` as `sourceUpdatedAtMs` so the Worker rejects
// out-of-order publications from concurrent web instances.

import { eq } from "drizzle-orm";
import * as Effect from "effect/Effect";
import { env } from "../../app/env";
import { cloudDb } from "../../db/client";
import { cloudVms } from "../../db/schema";
import { isProviderId, vmCapabilitiesFor } from "./drivers";
import type { VmCapabilities } from "./drivers/types";
import { vmImageKindFor } from "./images/resolver";
import type { CloudVmRow, VmRepositoryShape } from "./repository";
import { runAfterResponse } from "./routeHelpers";

/** Wall-clock budget for one publication. The Worker does one DO RPC. */
export const VM_SYNC_PUBLISH_TIMEOUT_MS = 750;

/** One machine as the Worker stores it: the `GET /api/vm` entry minus
 * per-request fields (creator names, plan windows). */
export type VmSyncRecord = {
  readonly id: string;
  readonly provider: string;
  readonly status: string;
  readonly image: string;
  readonly imageVersion: string | null;
  readonly kind: string;
  readonly capabilities: VmCapabilities;
  readonly createdAt: number;
  readonly displayName: string | null;
  readonly slug: string | null;
  readonly createdByUserId: string;
  readonly address: { readonly ipv4: string | null; readonly ipv6: string | null };
  readonly sourceUpdatedAtMs: number;
};

export type VmSyncOp =
  | { readonly kind: "upsert"; readonly record: VmSyncRecord }
  | { readonly kind: "delete"; readonly id: string; readonly sourceUpdatedAtMs: number }
  | { readonly kind: "replace"; readonly records: readonly VmSyncRecord[]; readonly observedAtMs: number };

/** The row fields the list entry carries (mirrors `VmEntry` in workflows.ts). */
export type VmSyncEntry = {
  readonly providerVmId: string;
  readonly provider: string;
  readonly image: string;
  readonly imageVersion: string | null;
  readonly status: string;
  readonly createdAt: number;
  readonly updatedAt: number;
  readonly displayName: string | null;
  readonly slug: string | null;
  readonly createdByUserId: string;
  readonly ownerTeamId: string;
  readonly addressIpv4: string | null;
  readonly addressIpv6: string | null;
};

/** Build the synced record from a list entry. Derivations (image kind,
 * provider capabilities) match the `GET /api/vm` handler. */
export function vmSyncRecordFromEntry(entry: VmSyncEntry): VmSyncRecord {
  const provider = entry.provider;
  return {
    id: entry.providerVmId,
    provider,
    status: entry.status,
    image: entry.image,
    imageVersion: entry.imageVersion,
    kind: isProviderId(provider) ? vmImageKindFor(provider, entry.image) : "base",
    capabilities: isProviderId(provider) ? vmCapabilitiesFor(provider) : emptyCapabilities(),
    createdAt: entry.createdAt,
    displayName: entry.displayName,
    slug: entry.slug,
    createdByUserId: entry.createdByUserId,
    address: { ipv4: entry.addressIpv4, ipv6: entry.addressIpv6 },
    sourceUpdatedAtMs: entry.updatedAt,
  };
}

/** The list scope a row belongs to: the same team `listUserVms` filters on
 * (`ownerTeamId`, falling back like the runtime insert does). */
export function vmSyncTeamId(row: Pick<CloudVmRow, "ownerTeamId" | "billingTeamId" | "userId">): string {
  return row.ownerTeamId.trim() || row.billingTeamId?.trim() || row.userId.trim();
}

/** Build the synced record from a `cloud_vms` row, or null when the row has no
 * provider VM id (the list omits it too). */
export function vmSyncRecordFromRow(row: CloudVmRow): VmSyncRecord | null {
  if (!row.providerVmId) return null;
  const metadata = row.providerMetadata ?? {};
  const ipv4 = metadata["networkIpv4"];
  const ipv6 = metadata["networkIpv6"];
  return vmSyncRecordFromEntry({
    providerVmId: row.providerVmId,
    provider: row.provider,
    image: row.imageId,
    imageVersion: row.imageVersion,
    status: row.status,
    createdAt: row.createdAt.getTime(),
    updatedAt: row.updatedAt.getTime(),
    displayName: row.displayName ?? null,
    slug: row.slug ?? null,
    createdByUserId: row.userId,
    ownerTeamId: vmSyncTeamId(row),
    addressIpv4: typeof ipv4 === "string" && ipv4 ? ipv4 : null,
    addressIpv6: typeof ipv6 === "string" && ipv6 ? ipv6 : null,
  });
}

/** Whether `listUserVms` would return this row (`GET /api/vm` filter). */
export function vmRowIsListed(row: Pick<CloudVmRow, "status" | "providerVmId" | "provider">): boolean {
  return row.status !== "destroyed" && !!row.providerVmId && isProviderId(row.provider);
}

/** The single op that brings the Worker in line with one row: an upsert when
 * the list shows it, a delete when it left the list, nothing without an id. */
export function vmSyncOpForRow(row: CloudVmRow): VmSyncOp | null {
  if (!row.providerVmId) return null;
  if (!vmRowIsListed(row)) {
    return { kind: "delete", id: row.providerVmId, sourceUpdatedAtMs: row.updatedAt.getTime() };
  }
  const record = vmSyncRecordFromRow(row);
  return record ? { kind: "upsert", record } : null;
}

/** The full-list op published after a list read. `observedAtMs` is taken
 * BEFORE the query so a machine created after it carries a newer clock and
 * the Worker keeps it. */
export function vmSyncReplaceOp(entries: readonly VmSyncEntry[], observedAtMs: number): VmSyncOp {
  return { kind: "replace", records: entries.map(vmSyncRecordFromEntry), observedAtMs };
}

/** Builds the exact backend-only Worker publication without performing I/O.
 * Null when the Worker or the publisher secret is not configured. */
export function buildVmSyncRequest(
  teamId: string,
  ops: readonly VmSyncOp[],
  configuration: {
    readonly baseURL?: string;
    readonly publisherSecret?: string;
  } = {
    baseURL: env.CMUX_PRESENCE_BASE_URL,
    publisherSecret: env.CMUX_PRESENCE_VMS_PUBLISHER_SECRET,
  },
): Request | null {
  const { baseURL, publisherSecret } = configuration;
  if (!baseURL || !publisherSecret || !teamId || ops.length === 0) return null;
  return new Request(new URL("/v1/sync/vms", baseURL), {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-cmux-vms-publisher-secret": publisherSecret,
    },
    body: JSON.stringify({ teamId, ops }),
  });
}

/** Publish ops for one team. Best-effort: resolves without throwing on any
 * failure (misconfiguration, timeout, non-2xx), logging a coarse warning. */
export async function publishVmSync(
  teamId: string,
  ops: readonly VmSyncOp[],
  fetchImpl: typeof fetch = fetch,
): Promise<void> {
  const publication = buildVmSyncRequest(teamId, ops);
  if (!publication) return;
  const controller = new AbortController();
  const timeout = setTimeout(
    () => controller.abort(new Error("vm_sync_publish_timeout")),
    VM_SYNC_PUBLISH_TIMEOUT_MS,
  );
  try {
    const response = await fetchImpl(publication, { signal: controller.signal });
    if (!response.ok) throw new Error(`vm_sync_publish_rejected_${response.status}`);
  } catch (error) {
    // The Postgres write is committed; the next list read republishes the
    // full list, so a Worker outage only delays convergence.
    console.warn("[VM] presence vms publish failed", {
      ops: ops.length,
      error: error instanceof Error ? error.message.slice(0, 120) : String(error).slice(0, 120),
    });
  } finally {
    clearTimeout(timeout);
  }
}

export type VmSyncPublisherDeps = {
  /** Re-read one row by primary key after a write committed. */
  readonly readRow: (id: string) => Promise<CloudVmRow | null>;
  readonly publish: (teamId: string, ops: readonly VmSyncOp[]) => Promise<void>;
  /** Runs `work` after the response (or detached outside a request). */
  readonly schedule: (work: () => Promise<void>) => void;
};

export async function readCloudVmRowById(id: string): Promise<CloudVmRow | null> {
  const [row] = await cloudDb().select().from(cloudVms).where(eq(cloudVms.id, id)).limit(1);
  return row ?? null;
}

export const liveVmSyncPublisherDeps: VmSyncPublisherDeps = {
  readRow: readCloudVmRowById,
  publish: publishVmSync,
  schedule: runAfterResponse,
};

/** Publish the current state of the rows with these ids, grouped by team. */
export function publishVmRowsById(ids: readonly string[], deps: VmSyncPublisherDeps = liveVmSyncPublisherDeps): void {
  if (ids.length === 0) return;
  deps.schedule(async () => {
    const byTeam = new Map<string, VmSyncOp[]>();
    for (const id of new Set(ids)) {
      const row = await deps.readRow(id);
      const op = row ? vmSyncOpForRow(row) : null;
      if (!row || !op) continue;
      const teamId = vmSyncTeamId(row);
      byTeam.set(teamId, [...(byTeam.get(teamId) ?? []), op]);
    }
    for (const [teamId, ops] of byTeam) await deps.publish(teamId, ops);
  });
}

/** Publish already-built ops (rows that no longer exist, or a list replace). */
export function publishVmOps(teamId: string, ops: readonly VmSyncOp[], deps: VmSyncPublisherDeps = liveVmSyncPublisherDeps): void {
  if (ops.length === 0) return;
  deps.schedule(() => deps.publish(teamId, ops));
}

function tapRow<A, E>(
  effect: Effect.Effect<A, E>,
  id: string,
  deps: VmSyncPublisherDeps,
): Effect.Effect<A, E> {
  return effect.pipe(Effect.tap(() => Effect.sync(() => publishVmRowsById([id], deps))));
}

/**
 * The repository wrapped so every list-relevant write also reaches the
 * presence Worker. After each write succeeds the row is re-read by id and its
 * current list state is published (an upsert, or a delete once destroyed).
 * Optional methods stay optional so test doubles keep compiling.
 */
export function withVmSyncPublication(
  repository: VmRepositoryShape,
  deps: VmSyncPublisherDeps = liveVmSyncPublisherDeps,
): VmRepositoryShape {
  const { markCreateAbandoned, resolveCreateCleanup, mergeProviderMetadata } = repository;
  return {
    ...repository,
    markCreateRunning: (input) => tapRow(repository.markCreateRunning(input), input.id, deps),
    markBaseCreateRunning: (input) => tapRow(repository.markBaseCreateRunning(input), input.vmId, deps),
    markCreateFailed: (input) => tapRow(repository.markCreateFailed(input), input.id, deps),
    markBaseCreateFailed: (input) => tapRow(repository.markBaseCreateFailed(input), input.vmId, deps),
    markProviderObservedStatus: (input) => tapRow(repository.markProviderObservedStatus(input), input.id, deps),
    reservePausedResume: (input) => tapRow(repository.reservePausedResume(input), input.id, deps),
    setDisplayName: (input) => tapRow(repository.setDisplayName(input), input.id, deps),
    markDestroyed: (id) => tapRow(repository.markDestroyed(id), id, deps),
    ...(markCreateAbandoned
      ? { markCreateAbandoned: (input) => tapRow(markCreateAbandoned(input), input.id, deps) }
      : {}),
    ...(resolveCreateCleanup
      ? { resolveCreateCleanup: (input) => tapRow(resolveCreateCleanup(input), input.id, deps) }
      : {}),
    ...(mergeProviderMetadata
      ? { mergeProviderMetadata: (input) => tapRow(mergeProviderMetadata(input), input.id, deps) }
      : {}),
  };
}

function emptyCapabilities(): VmCapabilities {
  return {
    snapshot: false,
    restore: false,
    fork: false,
    exec: false,
    stats: false,
    ports: false,
    desktop: false,
    sizing: false,
    persistentHome: false,
    attachTransports: [],
  };
}
