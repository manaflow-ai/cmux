import * as Effect from "effect/Effect";
import type { VMStatus, VMVolume } from "./drivers";
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
export const VM_REAPER_DEFAULT_ORPHAN_VOLUME_MIN_AGE_MINUTES = 2 * 60;
export const VM_REAPER_DEFAULT_CREATING_TERMINAL_AGE_MINUTES = 24 * 60;
export const VM_REAPER_MAX_BATCH_LIMIT = 100;
export const VM_REAPER_SYSTEM_USER_ID = "cmux-vm-reaper";

const ORPHAN_VOLUME_EVENT = "vm.reaper.orphan_volume";
const ORPHAN_VOLUME_OBSERVATION_EVENT = "vm.reaper.orphan_volume_observed";
const STUCK_PROVISIONING_TERMINAL_EVENT = "vm.reaper.stuck_provisioning_terminal";
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
  /** Minimum provider-volume age before a prior observation can be deleted. */
  readonly orphanVolumeMinAgeMs?: number;
  /** Maximum age for a provider that remains in `creating`. */
  readonly stuckProvisioningTerminalAgeMs?: number;
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
    const orphanVolumeMinAgeMs = resolveDurationOption(
      input.orphanVolumeMinAgeMs,
      resolveOrphanVolumeMinAgeMs(env),
    );
    const stuckProvisioningTerminalAgeMs = resolveDurationOption(
      input.stuckProvisioningTerminalAgeMs,
      resolveCreatingTerminalAgeMs(env),
    );
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
      terminalAgeMs: stuckProvisioningTerminalAgeMs,
    });

    yield* reapOrphanVolumes(repo, providers, summary, {
      deleteVolumes,
      limit: resolveLimit(input.volumeLimit, env.CMUX_VM_REAPER_VOLUME_LIMIT),
      minAgeMs: orphanVolumeMinAgeMs,
      now,
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
  input: {
    readonly now: Date;
    readonly limit: number;
    readonly ageMs: number;
    readonly terminalAgeMs: number;
  },
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
      (vm) => reapOneStuckProvisioningRow(repo, providers, summary, vm, {
        now: input.now,
        terminalAgeMs: input.terminalAgeMs,
      }),
      { concurrency: 1, discard: true },
    );
  });
}

function reapOneStuckProvisioningRow(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  summary: MutableSummary,
  vm: CloudVmRow,
  input: { readonly now: Date; readonly terminalAgeMs: number },
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
        ageMinutes: ageMinutes(vm.createdAt, input.now),
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
      if (!isOlderThan(vm.createdAt, input.now, input.terminalAgeMs)) {
        summary.stuckProvisioning.skipped += 1;
        console.info("[VM] reaper left provider still creating", { vmId: vm.id, providerVmId });
        return;
      }

      const marked = yield* markProvisioningFailed(repo, vm).pipe(Effect.either);
      if (marked._tag === "Left") {
        recordStuckError(summary, vm, marked.left, "mark_terminal_failed");
        return;
      }
      if (!marked.right) {
        summary.stuckProvisioning.skipped += 1;
        console.info("[VM] reaper skipped terminal creating row changed concurrently", { vmId: vm.id });
        return;
      }

      summary.stuckProvisioning.failed += 1;
      console.warn("[VM] reaper finalized provider-creating row after terminal deadline", {
        vmId: vm.id,
        providerVmId,
        ageMinutes: ageMinutes(vm.createdAt, input.now),
      });
      yield* recordVmUsageEvent(repo, vm, "vm.create.failed", {
        source: "vm_reaper",
        code: STUCK_PROVISIONING_FAILURE_CODE,
        reason: "provider_still_creating_terminal_deadline",
        providerStatus,
      });
      yield* recordVmUsageEvent(repo, vm, STUCK_PROVISIONING_TERMINAL_EVENT, {
        source: "vm_reaper",
        reason: "provider_still_creating_terminal_deadline",
        providerStatus,
        terminalAgeMinutes: Math.round(input.terminalAgeMs / 60_000),
      });
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
      expectedStatus: "provisioning",
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
  input: {
    readonly deleteVolumes: boolean;
    readonly limit: number;
    readonly minAgeMs: number;
    readonly now: Date;
  },
): Effect.Effect<void, never> {
  const listVolumes = providers.listVolumes;
  if (!listVolumes) return Effect.void;

  return Effect.gen(function* () {
    const listed = yield* listVolumes("blaxel").pipe(
      Effect.catchAll((error) => Effect.sync(() => {
        summary.orphanVolumes.errors += 1;
        console.error("[VM] reaper could not list provider volumes", safeErrorMessage(error));
        return [] as readonly VMVolume[];
      })),
    );
    const candidates = yield* selectOrphanVolumeCandidates(repo, summary, listed, input.limit);
    const observations = yield* loadOrphanVolumeObservations(
      repo,
      candidates.map((volume) => volume.name),
      summary,
    );
    summary.orphanVolumes.candidates = candidates.length;

    yield* Effect.forEach(
      candidates,
      (volume) => reapOneOrphanVolume(repo, providers, summary, volume, {
        deleteVolumes: input.deleteVolumes,
        minAgeMs: input.minAgeMs,
        now: input.now,
        observations,
      }),
      { concurrency: 1, discard: true },
    );
  });
}

/**
 * Select a bounded batch after removing provider-attached and database-live
 * volumes. Reference queries are chunked so a large provider inventory never
 * becomes an unbounded SQL `IN` list.
 */
function selectOrphanVolumeCandidates(
  repo: VmRepositoryShape,
  summary: MutableSummary,
  listed: readonly VMVolume[],
  limit: number,
): Effect.Effect<VMVolume[], never> {
  return Effect.gen(function* () {
    const owned = listed
      .filter((volume) => isMachineOwnedHomeVolumeName(volume.name))
      .sort(compareVolumes);
    const unattached = owned.filter((volume) => {
      const attachedTo = normalizedAttachment(volume);
      if (!attachedTo) return true;
      summary.orphanVolumes.skipped += 1;
      console.info("[VM] reaper skipped attached volume", {
        volumeName: volume.name.trim(),
        attachedTo,
      });
      return false;
    });
    const candidates: VMVolume[] = [];
    let offset = 0;

    while (offset < unattached.length && candidates.length < limit) {
      const chunk = unattached.slice(offset, offset + limit);
      offset += chunk.length;
      let liveNames: readonly string[] = [];

      if (repo.listLiveHomeVolumeNames) {
        const result = yield* repo.listLiveHomeVolumeNames({
          provider: "blaxel",
          volumeNames: chunk.map((volume) => volume.name.trim()),
        }).pipe(Effect.either);
        if (result._tag === "Left") {
          summary.orphanVolumes.errors += 1;
          summary.orphanVolumes.skipped += chunk.length;
          console.error("[VM] reaper could not load live volume references", safeErrorMessage(result.left));
          continue;
        }
        liveNames = result.right;
      }

      const liveReferences = new Set(liveNames.map((name) => name.trim()).filter(Boolean));
      for (const volume of chunk) {
        const name = volume.name.trim();
        if (liveReferences.has(name)) {
          summary.orphanVolumes.skipped += 1;
          console.info("[VM] reaper skipped volume referenced by a live VM", { volumeName: name });
          continue;
        }
        candidates.push(volume);
        if (candidates.length >= limit) break;
      }
    }
    return candidates;
  });
}

type OrphanVolumeObservationState = {
  readonly available: boolean;
  readonly byName: ReadonlyMap<string, Date>;
};

function loadOrphanVolumeObservations(
  repo: VmRepositoryShape,
  volumeNames: readonly string[],
  summary: MutableSummary,
): Effect.Effect<OrphanVolumeObservationState, never> {
  if (!repo.listOrphanVolumeObservations || volumeNames.length === 0) {
    return Effect.succeed({ available: !!repo.listOrphanVolumeObservations, byName: new Map() });
  }
  return repo.listOrphanVolumeObservations({ provider: "blaxel", volumeNames }).pipe(
    Effect.map((observations) => {
      const byName = new Map<string, Date>();
      for (const observation of observations) {
        const name = observation.volumeName.trim();
        if (!name || byName.has(name)) continue;
        if (!(observation.firstObservedAt instanceof Date) || !Number.isFinite(observation.firstObservedAt.getTime())) {
          continue;
        }
        byName.set(name, observation.firstObservedAt);
      }
      return { available: true, byName } satisfies OrphanVolumeObservationState;
    }),
    Effect.catchAll((error) => Effect.sync(() => {
      summary.orphanVolumes.errors += 1;
      console.error("[VM] reaper could not load orphan volume observations", safeErrorMessage(error));
      return { available: false, byName: new Map() } satisfies OrphanVolumeObservationState;
    })),
  );
}

function reapOneOrphanVolume(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  summary: MutableSummary,
  volume: VMVolume,
  input: {
    readonly deleteVolumes: boolean;
    readonly minAgeMs: number;
    readonly now: Date;
    readonly observations: OrphanVolumeObservationState;
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

    const firstObservedAt = input.observations.byName.get(name);
    const hasPriorObservation = input.observations.available &&
      !!firstObservedAt &&
      firstObservedAt.getTime() < input.now.getTime();
    if (!hasPriorObservation) {
      // A delete-enabled deployment must fail closed when the durable marker
      // path is unavailable. Report-only deployments can still surface the
      // candidate without pretending it is safe to delete.
      if (!input.observations.available || !repo.recordOrphanVolumeObservation) {
        if (input.deleteVolumes) {
          summary.orphanVolumes.skipped += 1;
          console.warn("[VM] reaper cannot delete volume without an observation marker", { volumeName: name });
          return;
        }
        summary.orphanVolumes.reported += 1;
        yield* recordSystemUsageEvent(repo, ORPHAN_VOLUME_EVENT, {
          volumeName: name,
          mode: "report",
          action: "report",
          reason: "observation_marker_unavailable",
        });
        return;
      }

      const recorded = yield* repo.recordOrphanVolumeObservation({
        provider: "blaxel",
        volumeName: name,
        observedAt: input.now,
      }).pipe(Effect.either);
      if (recorded._tag === "Left") {
        recordVolumeError(summary, name, recorded.left, "record_observation");
        return;
      }
      summary.orphanVolumes.reported += 1;
      console.info("[VM] reaper recorded first orphan volume observation", { volumeName: name });
      yield* recordSystemUsageEvent(repo, ORPHAN_VOLUME_EVENT, {
        volumeName: name,
        mode: "report",
        action: "observe",
        reason: "first_observation",
      });
      return;
    }

    const ageMs = volumeAgeMs(volume, input.now);
    if (ageMs === null || ageMs < input.minAgeMs) {
      summary.orphanVolumes.reported += 1;
      console.info("[VM] reaper deferred young orphan volume", {
        volumeName: name,
        ageMinutes: ageMs === null ? null : Math.round(ageMs / 60_000),
        minimumAgeMinutes: Math.round(input.minAgeMs / 60_000),
      });
      yield* recordSystemUsageEvent(repo, ORPHAN_VOLUME_EVENT, {
        volumeName: name,
        mode: "report",
        action: "report",
        reason: "minimum_age",
        minimumAgeMinutes: Math.round(input.minAgeMs / 60_000),
      });
      return;
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

function markProvisioningFailed(
  repo: VmRepositoryShape,
  vm: CloudVmRow,
): Effect.Effect<boolean, unknown> {
  if (repo.markProvisioningFailed) {
    return repo.markProvisioningFailed({
      id: vm.id,
      code: STUCK_PROVISIONING_FAILURE_CODE,
      message: "Cloud VM provisioning exceeded the reconciliation threshold.",
      expectedStatus: "provisioning",
    });
  }
  // Compatibility fallback for focused repository doubles and older deploys.
  return repo.markCreateFailed({
    id: vm.id,
    code: STUCK_PROVISIONING_FAILURE_CODE,
    message: "Cloud VM provisioning exceeded the reconciliation threshold.",
    expectedStatus: "provisioning",
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

function resolveOrphanVolumeMinAgeMs(env: Record<string, string | undefined>): number {
  const minutes = parsePositiveInteger(env.CMUX_VM_REAPER_ORPHAN_VOLUME_MIN_AGE_MINUTES) ??
    VM_REAPER_DEFAULT_ORPHAN_VOLUME_MIN_AGE_MINUTES;
  return minutes * 60 * 1_000;
}

function resolveCreatingTerminalAgeMs(env: Record<string, string | undefined>): number {
  const minutes = parsePositiveInteger(env.CMUX_VM_REAPER_STUCK_PROVISIONING_TERMINAL_MINUTES) ??
    VM_REAPER_DEFAULT_CREATING_TERMINAL_AGE_MINUTES;
  return minutes * 60 * 1_000;
}

function resolveDurationOption(value: number | undefined, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0
    ? Math.trunc(value)
    : fallback;
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

function isOlderThan(createdAt: Date, now: Date, thresholdMs: number): boolean {
  return now.getTime() - createdAt.getTime() >= thresholdMs;
}

function volumeAgeMs(volume: VMVolume, now: Date): number | null {
  const createdAt = volume.createdAt;
  if (typeof createdAt !== "number" || !Number.isFinite(createdAt)) return null;
  return Math.max(0, now.getTime() - createdAt);
}

function safeErrorMessage(error: unknown): string {
  const raw = error instanceof Error ? error.message : String(error);
  return raw.replace(/Bearer\s+\S+/gi, "Bearer [redacted]").slice(0, 500);
}

// Keep these names exported for focused tests and future cron dashboards.
export const VM_REAPER_ORPHAN_VOLUME_EVENT = ORPHAN_VOLUME_EVENT;
export const VM_REAPER_ORPHAN_VOLUME_OBSERVATION_EVENT = ORPHAN_VOLUME_OBSERVATION_EVENT;
export const VM_REAPER_STUCK_PROVISIONING_TERMINAL_EVENT = STUCK_PROVISIONING_TERMINAL_EVENT;
export const VM_REAPER_VOLUME_ERROR_EVENT = STUCK_VOLUME_ERROR_EVENT;
