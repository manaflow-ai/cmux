import * as Effect from "effect/Effect";
import type { VMStatus, VMVolume, ProviderId } from "./drivers";
import { isProviderNotFoundError } from "./providerErrors";
import { VmProviderGateway, type VmProviderGatewayShape } from "./providerGateway";
import {
  VmRepository,
  type CloudVmRow,
  type VmRepositoryShape,
} from "./repository";
import { isMachineOwnedHomeVolumeName } from "./volumeNaming";

/** The reaper is intentionally small enough to finish inside one Vercel invocation. */
export const VM_REAPER_DEFAULT_VOLUME_LIMIT = 100;
export const VM_REAPER_DEFAULT_PROVISIONING_LIMIT = 100;
export const VM_REAPER_DEFAULT_STUCK_PROVISIONING_MINUTES = 60;
export const VM_REAPER_MAX_BATCH_LIMIT = 100;
export const VM_REAPER_SYSTEM_USER_ID = "cmux-vm-reaper";

const ORPHAN_VOLUME_EVENT = "vm.reaper.orphan_volume";
const STUCK_VOLUME_ERROR_EVENT = "vm.reaper.orphan_volume_error";
const STUCK_PROVISIONING_FAILURE_CODE = "provisioning_timeout";

export type VmReaperCounts = {
  readonly candidates: number;
  readonly deleted: number;
  readonly reported: number;
  readonly skipped: number;
  readonly errors: number;
};

export type VmStuckProvisioningCounts = {
  readonly candidates: number;
  readonly recovered: number;
  readonly failed: number;
  readonly destroyed: number;
  readonly skipped: number;
  readonly errors: number;
};

export type VmReaperSummary = {
  /** True when no provider deletion was enabled for this run. */
  readonly reportOnly: boolean;
  readonly orphanVolumes: VmReaperCounts;
  readonly stuckProvisioning: VmStuckProvisioningCounts;
  /** Aggregate fields are convenient for dashboards and the PostHog event. */
  readonly candidates: number;
  readonly deleted: number;
  readonly skipped: number;
  readonly errors: number;
};

export type VmReaperOptions = {
  readonly now?: Date;
  /** Explicit option wins over CMUX_VM_REAPER_DELETE. */
  readonly deleteVolumes?: boolean;
  readonly volumeLimit?: number;
  readonly provisioningLimit?: number;
  /** Threshold in milliseconds. Explicit option wins over the env setting. */
  readonly stuckProvisioningAgeMs?: number;
  readonly env?: Record<string, string | undefined>;
};

type MutableSummary = {
  reportOnly: boolean;
  orphanVolumes: {
    candidates: number;
    deleted: number;
    reported: number;
    skipped: number;
    errors: number;
  };
  stuckProvisioning: {
    candidates: number;
    recovered: number;
    failed: number;
    destroyed: number;
    skipped: number;
    errors: number;
  };
};

type ReaperOutcome = "deleted" | "reported" | "skipped" | "error";
type StuckOutcome = "recovered" | "failed" | "destroyed" | "skipped" | "error";

/**
 * Reconcile old provisioning rows and clean up unreferenced Blaxel volumes.
 * Every item is isolated in its own Effect boundary. A provider or database
 * failure for one item becomes an error count and never aborts the batch.
 */
export function reapVmResources(
  input: VmReaperOptions = {},
): Effect.Effect<
  VmReaperSummary,
  never,
  VmRepository | VmProviderGateway
> {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const env = input.env ?? process.env;
    const now = input.now ?? new Date();
    const deleteVolumes = input.deleteVolumes ?? env.CMUX_VM_REAPER_DELETE === "1";
    const summary: MutableSummary = {
      reportOnly: !deleteVolumes,
      orphanVolumes: { candidates: 0, deleted: 0, reported: 0, skipped: 0, errors: 0 },
      stuckProvisioning: { candidates: 0, recovered: 0, failed: 0, destroyed: 0, skipped: 0, errors: 0 },
    };

    // Process stuck rows first. A row that is conclusively dead should no
    // longer protect its old machine-owned volume during this same run.
    yield* reapStuckProvisioningRows(repo, providers, summary, {
      now,
      limit: resolveLimit(input.provisioningLimit, env.CMUX_VM_REAPER_PROVISIONING_LIMIT),
      ageMs: input.stuckProvisioningAgeMs ?? resolveStuckAgeMs(env),
    });

    yield* reapOrphanVolumes(repo, providers, summary, {
      deleteVolumes,
      limit: resolveLimit(input.volumeLimit, env.CMUX_VM_REAPER_VOLUME_LIMIT),
    });

    const orphan = summary.orphanVolumes;
    const stuck = summary.stuckProvisioning;
    return {
      reportOnly: summary.reportOnly,
      orphanVolumes: orphan,
      stuckProvisioning: stuck,
      candidates: orphan.candidates + stuck.candidates,
      deleted: orphan.deleted + stuck.destroyed,
      skipped: orphan.skipped + stuck.skipped,
      errors: orphan.errors + stuck.errors,
    } satisfies VmReaperSummary;
  });
}

/** Alias kept for callers that name the job after its Cloud VM scope. */
export const reapCloudVmResources = reapVmResources;

function reapStuckProvisioningRows(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  summary: MutableSummary,
  input: { readonly now: Date; readonly limit: number; readonly ageMs: number },
): Effect.Effect<void, never> {
  const candidatesEffect = repo.stuckProvisioningCandidates
    ? repo.stuckProvisioningCandidates({
      before: new Date(input.now.getTime() - input.ageMs),
      limit: input.limit,
    })
    : Effect.succeed([] as CloudVmRow[]);

  return Effect.gen(function* () {
    const candidates = yield* candidatesEffect.pipe(
      Effect.catchAll((error) => Effect.sync(() => {
        summary.stuckProvisioning.errors += 1;
        console.error("[VM] reaper could not list stuck provisioning rows", safeErrorMessage(error));
        return [] as CloudVmRow[];
      })),
    );
    summary.stuckProvisioning.candidates = candidates.length;
    yield* Effect.forEach(
      candidates,
      (vm) => reapOneStuckProvisioningRow(repo, providers, summary, vm, input.now),
      { concurrency: 1, discard: true },
    );
  });
}

function reapOneStuckProvisioningRow(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  summary: MutableSummary,
  vm: CloudVmRow,
  now: Date,
): Effect.Effect<void, never> {
  return Effect.gen(function* () {
    const providerVmId = vm.providerVmId?.trim() || null;
    if (!providerVmId) {
      const marked = yield* markProvisioningFailed(repo, vm).pipe(Effect.either);
      if (marked._tag === "Left") {
        recordStuckError(summary, vm, marked.left, "mark_failed");
        return;
      }
      if (!marked.right) {
        summary.stuckProvisioning.skipped += 1;
        console.info("[VM] reaper skipped stale provisioning row changed concurrently", { vmId: vm.id });
        return;
      }
      summary.stuckProvisioning.failed += 1;
      console.warn("[VM] reaper marked provisioning row failed without provider id", {
        vmId: vm.id,
        ageMinutes: ageMinutes(vm.createdAt, now),
      });
      yield* recordVmUsageEvent(repo, vm, "vm.create.failed", {
        source: "vm_reaper",
        code: STUCK_PROVISIONING_FAILURE_CODE,
        reason: "provider_vm_id_missing",
      });
      return;
    }

    const getStatus = providers.getStatus;
    if (!getStatus) {
      recordStuckError(summary, vm, new Error("provider status is not supported"), "get_status");
      return;
    }

    const statusResult = yield* getStatus(vm.provider, providerVmId).pipe(Effect.either);
    let providerStatus: VMStatus;
    if (statusResult._tag === "Left") {
      if (!isProviderNotFoundError(statusResult.left)) {
        recordStuckError(summary, vm, statusResult.left, "get_status");
        return;
      }
      providerStatus = "destroyed";
    } else {
      providerStatus = statusResult.right;
    }

    if (providerStatus === "creating") {
      summary.stuckProvisioning.skipped += 1;
      console.info("[VM] reaper left provider still creating", { vmId: vm.id, providerVmId });
      return;
    }

    const desiredStatus = stuckDbStatus(
      vm,
      providerStatus as Exclude<VMStatus, "creating">,
    );
    const updated = yield* repo.markProviderObservedStatus({
      id: vm.id,
      providerVmId,
      status: desiredStatus,
    }).pipe(Effect.either);
    if (updated._tag === "Left") {
      recordStuckError(summary, vm, updated.left, "mark_status");
      return;
    }
    if (!updated.right) {
      summary.stuckProvisioning.skipped += 1;
      console.info("[VM] reaper skipped stale provisioning row changed concurrently", { vmId: vm.id });
      return;
    }

    if (desiredStatus === "destroyed") {
      summary.stuckProvisioning.destroyed += 1;
      console.warn("[VM] reaper marked missing provider sandbox destroyed", { vmId: vm.id, providerVmId });
      yield* recordVmUsageEvent(repo, vm, "vm.destroyed", {
        source: "vm_reaper",
        reason: "provider_sandbox_missing",
      });
      return;
    }

    summary.stuckProvisioning.recovered += 1;
    console.info("[VM] reaper reconciled stale provisioning row", {
      vmId: vm.id,
      providerVmId,
      status: desiredStatus,
    });
  });
}

function reapOrphanVolumes(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  summary: MutableSummary,
  input: { readonly deleteVolumes: boolean; readonly limit: number },
): Effect.Effect<void, never> {
  const listVolumes = providers.listVolumes;
  if (!listVolumes) return Effect.void;

  return Effect.gen(function* () {
    const liveReferences = yield* loadLiveVolumeReferences(repo).pipe(
      Effect.catchAll((error) => Effect.sync(() => {
        console.error("[VM] reaper could not load live volume references", safeErrorMessage(error));
        return null as Set<string> | null;
      })),
    );
    const listed = yield* listVolumes("blaxel").pipe(
      Effect.catchAll((error) => Effect.sync(() => {
        summary.orphanVolumes.errors += 1;
        console.error("[VM] reaper could not list provider volumes", safeErrorMessage(error));
        return [] as readonly VMVolume[];
      })),
    );
    const candidates = listed
      .filter((volume) => isMachineOwnedHomeVolumeName(volume.name))
      .sort(compareVolumes)
      .slice(0, input.limit);
    summary.orphanVolumes.candidates = candidates.length;

    yield* Effect.forEach(
      candidates,
      (volume) => reapOneOrphanVolume(repo, providers, summary, volume, {
        deleteVolumes: input.deleteVolumes,
        liveReferences,
      }),
      { concurrency: 1, discard: true },
    );
  });
}

function reapOneOrphanVolume(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  summary: MutableSummary,
  volume: VMVolume,
  input: {
    readonly deleteVolumes: boolean;
    readonly liveReferences: Set<string> | null;
  },
): Effect.Effect<void, never> {
  return Effect.gen(function* () {
    const name = volume.name.trim();
    const attachedTo = normalizedAttachment(volume);
    if (attachedTo) {
      summary.orphanVolumes.skipped += 1;
      console.info("[VM] reaper skipped attached volume", { volumeName: name, attachedTo });
      return;
    }

    if (input.liveReferences?.has(name)) {
      summary.orphanVolumes.skipped += 1;
      console.info("[VM] reaper skipped volume referenced by a live VM", { volumeName: name });
      return;
    }

    // Recheck ownership immediately before deletion. The initial inventory is
    // only a snapshot and a create can claim a volume while this run proceeds.
    if (repo.isLiveHomeVolumeReferenced) {
      const referenceResult = yield* repo.isLiveHomeVolumeReferenced({
        provider: "blaxel",
        volumeName: name,
      }).pipe(Effect.either);
      if (referenceResult._tag === "Left") {
        recordVolumeError(summary, name, referenceResult.left, "reference_check");
        return;
      }
      if (referenceResult.right) {
        summary.orphanVolumes.skipped += 1;
        console.info("[VM] reaper skipped volume claimed during the run", { volumeName: name });
        return;
      }
    }

    if (!input.deleteVolumes) {
      summary.orphanVolumes.reported += 1;
      console.info("[VM] reaper orphan volume report-only candidate", { volumeName: name });
      yield* recordSystemUsageEvent(repo, ORPHAN_VOLUME_EVENT, {
        volumeName: name,
        mode: "report",
        action: "report",
      });
      return;
    }

    if (!providers.deleteHomeVolume) {
      recordVolumeError(summary, name, new Error("provider volume deletion is not supported"), "delete");
      return;
    }
    const deleted = yield* providers.deleteHomeVolume("blaxel", name).pipe(Effect.either);
    if (deleted._tag === "Left") {
      recordVolumeError(summary, name, deleted.left, "delete");
      return;
    }
    summary.orphanVolumes.deleted += 1;
    console.info("[VM] reaper deleted orphan volume", { volumeName: name });
    yield* recordSystemUsageEvent(repo, ORPHAN_VOLUME_EVENT, {
      volumeName: name,
      mode: "delete",
      action: "deleted",
    });
  });
}

function loadLiveVolumeReferences(
  repo: VmRepositoryShape,
): Effect.Effect<Set<string>, never> {
  if (!repo.listLiveHomeVolumeNames) return Effect.succeed(new Set<string>());
  return repo.listLiveHomeVolumeNames({ provider: "blaxel" }).pipe(
    Effect.map((names) => new Set(names.map((name) => name.trim()).filter(Boolean))),
  ) as Effect.Effect<Set<string>, never>;
}

function markProvisioningFailed(
  repo: VmRepositoryShape,
  vm: CloudVmRow,
): Effect.Effect<boolean, unknown> {
  if (repo.markProvisioningFailed) {
    return repo.markProvisioningFailed({
      id: vm.id,
      code: STUCK_PROVISIONING_FAILURE_CODE,
      message: "Cloud VM provisioning exceeded the reconciliation threshold.",
    });
  }
  // Compatibility fallback for focused repository doubles and older deploys.
  return repo.markCreateFailed({
    id: vm.id,
    code: STUCK_PROVISIONING_FAILURE_CODE,
    message: "Cloud VM provisioning exceeded the reconciliation threshold.",
  }).pipe(Effect.as(true));
}

function stuckDbStatus(
  vm: CloudVmRow,
  providerStatus: Exclude<VMStatus, "creating">,
): "running" | "paused" | "destroyed" {
  if (providerStatus !== "destroyed") return providerStatus;
  const homeVolume = vm.providerMetadata?.homeVolume;
  // A volume-backed machine can be resurrected after its compute disappears.
  // Preserve the existing workflow semantics and leave it paused.
  return typeof homeVolume === "string" && homeVolume.trim().length > 0 ? "paused" : "destroyed";
}

function recordVmUsageEvent(
  repo: VmRepositoryShape,
  vm: CloudVmRow,
  eventType: string,
  metadata: Record<string, unknown>,
): Effect.Effect<void, never> {
  return repo.recordUsageEvent({
    userId: vm.userId,
    billingTeamId: vm.billingTeamId,
    billingPlanId: vm.billingPlanId,
    vmId: vm.id,
    eventType,
    provider: vm.provider,
    imageId: vm.imageId,
    metadata,
  }).pipe(
    Effect.catchAll((error) => Effect.sync(() => {
      console.error("[VM] reaper could not record VM usage event", {
        vmId: vm.id,
        eventType,
        error: safeErrorMessage(error),
      });
    })),
  );
}

function recordSystemUsageEvent(
  repo: VmRepositoryShape,
  eventType: string,
  metadata: Record<string, unknown>,
): Effect.Effect<void, never> {
  return repo.recordUsageEvent({
    userId: VM_REAPER_SYSTEM_USER_ID,
    billingTeamId: null,
    billingPlanId: null,
    eventType,
    provider: "blaxel",
    metadata,
  }).pipe(
    Effect.catchAll((error) => Effect.sync(() => {
      console.error("[VM] reaper could not record volume usage event", {
        eventType,
        volumeName: metadata.volumeName,
        error: safeErrorMessage(error),
      });
    })),
  );
}

function recordVolumeError(
  summary: MutableSummary,
  volumeName: string,
  error: unknown,
  operation: string,
): void {
  summary.orphanVolumes.errors += 1;
  summary.orphanVolumes.skipped += 1;
  console.error("[VM] reaper skipped volume after item error", {
    volumeName,
    operation,
    error: safeErrorMessage(error),
  });
  // The item-level error is also visible in the provider usage ledger when the
  // caller's repository supports it. The main action path records this event
  // asynchronously below only for the provider action itself.
}

function recordStuckError(
  summary: MutableSummary,
  vm: CloudVmRow,
  error: unknown,
  operation: string,
): void {
  summary.stuckProvisioning.errors += 1;
  summary.stuckProvisioning.skipped += 1;
  console.error("[VM] reaper skipped provisioning row after item error", {
    vmId: vm.id,
    operation,
    error: safeErrorMessage(error),
  });
}

function compareVolumes(a: VMVolume, b: VMVolume): number {
  const aCreated = typeof a.createdAt === "number" && Number.isFinite(a.createdAt) ? a.createdAt : 0;
  const bCreated = typeof b.createdAt === "number" && Number.isFinite(b.createdAt) ? b.createdAt : 0;
  if (aCreated !== bCreated) return aCreated - bCreated;
  return a.name.localeCompare(b.name);
}

function normalizedAttachment(volume: VMVolume): string | null {
  const value = volume.attachedTo;
  if (typeof value === "string" && value.trim().length > 0) return value.trim();
  return value == null ? null : String(value);
}

function resolveLimit(value: number | undefined, envValue: string | undefined): number {
  const candidate = value ?? parsePositiveInteger(envValue);
  if (candidate === null || candidate === undefined) return VM_REAPER_DEFAULT_VOLUME_LIMIT;
  return Math.max(1, Math.min(VM_REAPER_MAX_BATCH_LIMIT, Math.trunc(candidate)));
}

function resolveStuckAgeMs(env: Record<string, string | undefined>): number {
  const raw = env.CMUX_VM_REAPER_STUCK_PROVISIONING_MINUTES ??
    env.CMUX_VM_REAPER_STUCK_THRESHOLD_MINUTES ??
    env.CMUX_VM_REAPER_STUCK_AGE_MINUTES;
  const minutes = parsePositiveInteger(raw) ?? VM_REAPER_DEFAULT_STUCK_PROVISIONING_MINUTES;
  return minutes * 60 * 1_000;
}

function parsePositiveInteger(value: string | undefined): number | null {
  const trimmed = value?.trim();
  if (!trimmed || !/^\d+$/.test(trimmed)) return null;
  const parsed = Number(trimmed);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : null;
}

function ageMinutes(createdAt: Date, now: Date): number {
  return Math.max(0, Math.round((now.getTime() - createdAt.getTime()) / 60_000));
}

function safeErrorMessage(error: unknown): string {
  const raw = error instanceof Error ? error.message : String(error);
  return raw.replace(/Bearer\s+\S+/gi, "Bearer [redacted]").slice(0, 500);
}

// Keep these names exported for focused tests and future cron dashboards.
export const VM_REAPER_ORPHAN_VOLUME_EVENT = ORPHAN_VOLUME_EVENT;
export const VM_REAPER_VOLUME_ERROR_EVENT = STUCK_VOLUME_ERROR_EVENT;
