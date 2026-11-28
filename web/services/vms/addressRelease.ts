/**
 * Paused machines release their private network address after a bounded time.
 *
 * Leo, 2026-11-28: "Paused sandboxes must release addresses or have bounded expiry."
 *
 * A paused Freestyle machine keeps its private address for as long as it
 * stays paused, so a team's /24 fills with machines nobody is using and new
 * starts wait for an address that never frees (createWait.ts). The provider
 * has no call that detaches a machine's network, so the only way to free the
 * address is to remove the provider machine. Parking does that without losing
 * the machine:
 *
 *   1. snapshot the paused machine (memory and disk) and record the snapshot
 *      as owned, so it can be restored like any other snapshot;
 *   2. verify the snapshot through the provider's own snapshot list;
 *   3. mark the row `parking` with the snapshot id (fenced on the row being
 *      unchanged since it was read, so a resume or attach in between wins);
 *   4. destroy the provider machine;
 *   5. mark the row `parked` and drop `networkIpv4`, which takes the row out
 *      of the address count (countNetworkAddressHolders).
 *
 * A failure at any step before 4 destroys nothing. A failure after 3 leaves
 * the row `parking`, still counted as holding its address, and the next run
 * finishes the destroy from the recorded snapshot. Resuming a parked machine
 * restores it from the snapshot through the normal create path (admission and
 * `waiting_for_address` included); the parked row then points at its
 * successor, and lookups by the old id follow the pointer.
 *
 * Reconcile, health and the runtime-limit cron skip rows with this record: a
 * parked row has no provider machine by design, and treating it as gone would
 * retire the row and lose the pointer to its snapshot.
 *
 * Off unless CMUX_VM_PAUSED_ADDRESS_RELEASE_HOURS is a positive number.
 */

import { maxMemoryMbForPlan, maxVcpusForPlan } from "./entitlements";

export const VM_ADDRESS_RELEASE_KEY = "addressRelease";
export const VM_PAUSED_ADDRESS_RELEASE_HOURS_ENV = "CMUX_VM_PAUSED_ADDRESS_RELEASE_HOURS";
/** Machines one run parks at most; each park is a snapshot plus a destroy. */
export const VM_ADDRESS_RELEASE_BATCH_LIMIT = 20;
/** Display name of the snapshot a park takes, so the person can tell it apart. */
export const VM_ADDRESS_RELEASE_SNAPSHOT_NAME = "cmux-parked";

export type VmAddressReleaseState = "parking" | "parked" | "restored";

export type VmAddressRelease = {
  readonly state: VmAddressReleaseState;
  /** The owned snapshot the machine restores from. */
  readonly snapshotId: string;
  /** The provider machine the snapshot was taken from. */
  readonly sourceProviderVmId: string;
  /** The address the machine held before it parked; informational only. */
  readonly releasedIpv4: string | null;
  /** Epoch ms the park began. */
  readonly startedAt: number;
  /** Epoch ms the provider machine was destroyed and the address freed. */
  readonly parkedAt?: number;
  /** The restored machine's provider id, once a resume restored it. */
  readonly successorProviderVmId?: string;
  readonly restoredAt?: number;
};

/** Hours a machine stays paused before it parks, or null when parking is off (the default). */
export function pausedAddressReleaseHours(env: Readonly<Record<string, string | undefined>> = process.env): number | null {
  const raw = env[VM_PAUSED_ADDRESS_RELEASE_HOURS_ENV]?.trim();
  if (!raw) return null;
  const hours = Number(raw);
  return Number.isFinite(hours) && hours > 0 ? hours : null;
}

/** The park record on a row, or null when the row never parked. */
export function addressReleaseFromMetadata(metadata: Readonly<Record<string, unknown>> | null | undefined): VmAddressRelease | null {
  const raw = metadata?.[VM_ADDRESS_RELEASE_KEY];
  if (!raw || typeof raw !== "object") return null;
  const record = raw as Record<string, unknown>;
  if (record.state !== "parking" && record.state !== "parked" && record.state !== "restored") return null;
  if (typeof record.snapshotId !== "string" || !record.snapshotId) return null;
  if (typeof record.sourceProviderVmId !== "string" || !record.sourceProviderVmId) return null;
  if (typeof record.startedAt !== "number") return null;
  return {
    state: record.state,
    snapshotId: record.snapshotId,
    sourceProviderVmId: record.sourceProviderVmId,
    releasedIpv4: typeof record.releasedIpv4 === "string" ? record.releasedIpv4 : null,
    startedAt: record.startedAt,
    ...(typeof record.parkedAt === "number" ? { parkedAt: record.parkedAt } : {}),
    ...(typeof record.successorProviderVmId === "string" ? { successorProviderVmId: record.successorProviderVmId } : {}),
    ...(typeof record.restoredAt === "number" ? { restoredAt: record.restoredAt } : {}),
  };
}

/**
 * True when the row carries any park record, malformed ones included. Every
 * cron that would act on a missing provider machine checks this first; a
 * record it cannot parse still means "do not retire this row".
 */
export function isAddressReleaseRow(row: { readonly providerMetadata?: Readonly<Record<string, unknown>> | null }): boolean {
  const raw = row.providerMetadata?.[VM_ADDRESS_RELEASE_KEY];
  return raw !== undefined && raw !== null;
}

/**
 * Why a paused row cannot park, or null when it can. Only plain paused
 * Freestyle machines with a private address park. A machine with a home
 * volume is left alone: the snapshot does not carry the volume, and restoring
 * one without it would lose the person's files.
 */
export function addressReleaseIneligibleReason(row: {
  readonly provider: string;
  readonly status: string;
  readonly providerVmId: string | null;
  readonly providerMetadata?: Readonly<Record<string, unknown>> | null;
}, isSandboxRun: boolean): string | null {
  if (row.provider !== "freestyle") return "provider";
  if (row.status !== "paused") return "status";
  if (!row.providerVmId) return "no_provider_vm";
  if (isSandboxRun) return "sandbox_run";
  const metadata = row.providerMetadata ?? {};
  if (typeof metadata.homeVolume === "string" && metadata.homeVolume.length > 0) return "home_volume";
  if (typeof metadata.networkIpv4 !== "string" || !metadata.networkIpv4) return "no_address";
  return null;
}

/**
 * True when the row's plan can restore a snapshot of this shape. A machine
 * the plan could not restore is never parked: its snapshot would be the only
 * copy, and a resume would refuse it.
 */
export function addressReleaseRestorable(
  billingPlanId: string,
  reservation: { readonly vcpus: number; readonly memoryMb: number },
  env: Readonly<Record<string, string | undefined>> = process.env,
): boolean {
  const mutableEnv = env as Record<string, string | undefined>;
  return reservation.memoryMb <= maxMemoryMbForPlan(billingPlanId, mutableEnv) &&
    reservation.vcpus <= maxVcpusForPlan(billingPlanId, mutableEnv);
}
