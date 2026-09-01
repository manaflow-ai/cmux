import * as Effect from "effect/Effect";
import type {
  VMVolume,
  VMVolumeInventory,
  VMVolumePage,
} from "./drivers";
import { VmProviderGateway, type VmProviderGatewayShape } from "./providerGateway";
import {
  VmRepository,
  type CloudVmRow,
  type VmRepositoryShape,
} from "./repository";
import { isMachineOwnedHomeVolumeName } from "./volumeNaming";

/** Maximum number of candidate reports emitted by one run. */
export const VM_REAPER_DEFAULT_VOLUME_LIMIT = 100;
export const VM_REAPER_DEFAULT_PROVISIONING_LIMIT = 100;
export const VM_REAPER_DEFAULT_VOLUME_SCAN_LIMIT = 1_000;
export const VM_REAPER_MAX_BATCH_LIMIT = 100;
export const VM_REAPER_MAX_VOLUME_SCAN_LIMIT = 1_000;
/** Sequential provider page requests allowed per run; far below the item cap. */
export const VM_REAPER_MAX_VOLUME_SCAN_PAGES = 20;
/** Wall-clock budget for the volume scan, well inside the route's 300s cap. */
export const VM_REAPER_SCAN_DEADLINE_MS = 120_000;
export const VM_REAPER_DEFAULT_STUCK_PROVISIONING_MINUTES = 60;
export const VM_REAPER_DEFAULT_VOLUME_MIN_AGE_MINUTES = 120;
export const VM_REAPER_SYSTEM_USER_ID = "cmux-vm-reaper";

const ORPHAN_VOLUME_EVENT = "vm.reaper.orphan_volume";
const ORPHAN_VOLUME_UNKNOWN_ATTACHMENT_EVENT = "vm.reaper.orphan_volume_unknown_attachment";
const ORPHAN_VOLUME_UNKNOWN_REFERENCE_EVENT = "vm.reaper.orphan_volume_unknown_reference";
const STUCK_PROVISIONING_EVENT = "vm.reaper.stuck_provisioning";
const VM_REAPER_REPORT_DEDUP_WINDOW_MS = 24 * 60 * 60 * 1_000;

export type VmReaperCounts = {
  /** Known machine-owned, explicitly unattached volumes with no live row. */
  readonly candidates: number;
  /** Usage events successfully emitted for this category. */
  readonly reported: number;
  /** Always zero. The report-only cron has no lifecycle mutation path. */
  readonly deleted: number;
  /** Provider attachment was absent or malformed, so the state was unknown. */
  readonly unknownAttachment: number;
  /** A known-free volume could not be checked against live VM rows. */
  readonly unknownReference: number;
  /** Provider records inspected during this run. */
  readonly scanned: number;
  /** Provider pages fetched during this run. */
  readonly providerPages: number;
  /** True when the provider did not prove that the inventory was exhausted. */
  readonly coveragePartial: boolean;
  readonly skipped: number;
  readonly errors: number;
};

export type VmStuckProvisioningCounts = {
  /** Rows whose updatedAt is older than the configured threshold. */
  readonly candidates: number;
  readonly reported: number;
  /** Retained as zero-valued compatibility fields for existing dashboards. */
  readonly recovered: number;
  readonly failed: number;
  readonly destroyed: number;
  readonly skipped: number;
  readonly errors: number;
};

export type VmReaperSummary = {
  /** Always true. This cron only observes and records findings. */
  readonly reportOnly: boolean;
  readonly orphanVolumes: VmReaperCounts;
  readonly stuckProvisioning: VmStuckProvisioningCounts;
  readonly candidates: number;
  readonly reported: number;
  /** Always zero. Kept for stable API/telemetry consumers. */
  readonly deleted: number;
  readonly skipped: number;
  readonly errors: number;
};

export type VmReaperOptions = {
  readonly now?: Date;
  /** Maximum number of orphan candidates to report in one run. */
  readonly volumeLimit?: number;
  /** Maximum number of provider volume records to inspect in one run. */
  readonly volumeScanLimit?: number;
  readonly provisioningLimit?: number;
  /** Age threshold in milliseconds. */
  readonly stuckProvisioningAgeMs?: number;
  readonly env?: Record<string, string | undefined>;
};

type MutableSummary = {
  reportOnly: boolean;
  orphanVolumes: {
    candidates: number;
    reported: number;
    deleted: number;
    unknownAttachment: number;
    unknownReference: number;
    scanned: number;
    providerPages: number;
    coveragePartial: boolean;
    skipped: number;
    errors: number;
  };
  stuckProvisioning: {
    candidates: number;
    reported: number;
    recovered: number;
    failed: number;
    destroyed: number;
    skipped: number;
    errors: number;
  };
};

/**
 * Run the bounded Cloud VM observability report.
 *
 * This function intentionally has no provider or repository lifecycle mutation
 * calls. It lists provider volumes, checks live row references, and records
 * usage events for findings. A provider page without a trustworthy continuation
 * signal is treated as partial coverage.
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
    const volumeLimit = resolveLimit(
      input.volumeLimit,
      env.CMUX_VM_REAPER_VOLUME_LIMIT,
      VM_REAPER_DEFAULT_VOLUME_LIMIT,
    );
    const volumeScanLimit = resolveScanLimit(
      input.volumeScanLimit,
      env.CMUX_VM_REAPER_VOLUME_SCAN_LIMIT ?? env.CMUX_VM_REAPER_SCAN_LIMIT,
      volumeLimit,
    );
    const volumeMinAgeMs = (parsePositiveInteger(env.CMUX_VM_REAPER_VOLUME_MIN_AGE_MINUTES) ??
      VM_REAPER_DEFAULT_VOLUME_MIN_AGE_MINUTES) * 60 * 1_000;
    const summary: MutableSummary = {
      reportOnly: true,
      orphanVolumes: {
        candidates: 0,
        reported: 0,
        deleted: 0,
        unknownAttachment: 0,
        unknownReference: 0,
        scanned: 0,
        providerPages: 0,
        coveragePartial: false,
        skipped: 0,
        errors: 0,
      },
      stuckProvisioning: {
        candidates: 0,
        reported: 0,
        recovered: 0,
        failed: 0,
        destroyed: 0,
        skipped: 0,
        errors: 0,
      },
    };

    yield* reportStuckProvisioningRows(repo, summary, {
      now,
      limit: resolveLimit(
        input.provisioningLimit,
        env.CMUX_VM_REAPER_PROVISIONING_LIMIT,
        VM_REAPER_DEFAULT_PROVISIONING_LIMIT,
      ),
      ageMs: resolveDurationOption(input.stuckProvisioningAgeMs, resolveStuckAgeMs(env)),
    });
    yield* reportOrphanVolumes(repo, providers, summary, {
      limit: volumeLimit,
      scanLimit: volumeScanLimit,
      now,
      minAgeMs: volumeMinAgeMs,
    });

    const orphan = summary.orphanVolumes;
    const stuck = summary.stuckProvisioning;
    return {
      reportOnly: true,
      orphanVolumes: orphan,
      stuckProvisioning: stuck,
      candidates: orphan.candidates + stuck.candidates,
      reported: orphan.reported + stuck.reported,
      deleted: 0,
      skipped: orphan.skipped + stuck.skipped,
      errors: orphan.errors + stuck.errors,
    } satisfies VmReaperSummary;
  });
}

/** Alias kept for callers that name the job after its Cloud VM scope. */
export const reapCloudVmResources = reapVmResources;

function reportStuckProvisioningRows(
  repo: VmRepositoryShape,
  summary: MutableSummary,
  input: { readonly now: Date; readonly limit: number; readonly ageMs: number },
): Effect.Effect<void, never> {
  const listCandidates = repo.stuckProvisioningCandidates;
  if (!listCandidates) return Effect.void;
  return Effect.gen(function* () {
    const result = yield* listCandidates({
      before: new Date(input.now.getTime() - input.ageMs),
      // Fetch the full bounded scan window before applying the report limit.
      // This lets a recently reported row make room for the next row.
      limit: VM_REAPER_MAX_BATCH_LIMIT,
    }).pipe(Effect.either);
    if (result._tag === "Left") {
      summary.stuckProvisioning.errors += 1;
      console.error("[VM] reaper could not list stuck provisioning rows", safeErrorMessage(result.left));
      return;
    }

    // The repository orders this query by updatedAt oldest first. Keep only a
    // bounded oldest subset as a defensive measure for alternate
    // implementations that return more rows than requested.
    const eligible = result.right.filter((vm) => isOlderThan(vm.updatedAt, input.now, input.ageMs));
    const scanWindow = selectOldestVmRows(eligible, VM_REAPER_MAX_BATCH_LIMIT);
    if (eligible.length > scanWindow.length) summary.stuckProvisioning.skipped += eligible.length - scanWindow.length;

    const recentKeys = yield* loadRecentReaperReportKeys(
      repo,
      STUCK_PROVISIONING_EVENT,
      scanWindow.map((vm) => vm.id),
      input.now,
      () => {
        summary.stuckProvisioning.errors += 1;
      },
    );
    const unreported = scanWindow.filter((vm) => {
      if (!recentKeys.has(vm.id)) return true;
      summary.stuckProvisioning.skipped += 1;
      console.info("[VM] reaper skipped stuck provisioning row", {
        vmId: vm.id,
        reason: "already_reported",
      });
      return false;
    });
    const candidates = selectOldestVmRows(unreported, input.limit);
    summary.stuckProvisioning.candidates = candidates.length;
    if (unreported.length > candidates.length) summary.stuckProvisioning.skipped += unreported.length - candidates.length;

    for (const vm of candidates) {
      const recorded = yield* recordVmUsageEvent(repo, vm, STUCK_PROVISIONING_EVENT, {
        source: "vm_reaper",
        reason: "age_over_threshold",
        ageMinutes: ageMinutes(vm.updatedAt, input.now),
        thresholdMinutes: Math.ceil(input.ageMs / 60_000),
        providerVmIdPresent: !!vm.providerVmId?.trim(),
      });
      if (recorded) summary.stuckProvisioning.reported += 1;
      else summary.stuckProvisioning.errors += 1;
    }
  });
}

function reportOrphanVolumes(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  summary: MutableSummary,
  input: {
    readonly limit: number;
    readonly scanLimit: number;
    readonly now: Date;
    readonly minAgeMs: number;
  },
): Effect.Effect<void, never> {
  const listVolumes = providers.listVolumes;
  if (!listVolumes) {
    summary.orphanVolumes.coveragePartial = true;
    return Effect.void;
  }

  return Effect.gen(function* () {
    let cursor: string | undefined;
    let exhausted = false;
    const seenCursors = new Set<string>();
    const seenNames = new Set<string>();
    let candidateLimitReached = false;

    const scanStartedAtMs = Date.now();
    while (!exhausted &&
      summary.orphanVolumes.scanned < input.scanLimit &&
      summary.orphanVolumes.providerPages < VM_REAPER_MAX_VOLUME_SCAN_LIMIT) {
      // A provider returning many small or empty pages must not monopolize
      // the cron budget: cap sequential pages and bound the scan wall clock.
      if (summary.orphanVolumes.providerPages >= VM_REAPER_MAX_VOLUME_SCAN_PAGES) {
        summary.orphanVolumes.coveragePartial = true;
        console.info("[VM] reaper stopped at the provider page cap", {
          pages: summary.orphanVolumes.providerPages,
        });
        break;
      }
      if (Date.now() - scanStartedAtMs >= VM_REAPER_SCAN_DEADLINE_MS) {
        summary.orphanVolumes.coveragePartial = true;
        console.info("[VM] reaper stopped at the scan deadline");
        break;
      }
      const remaining = input.scanLimit - summary.orphanVolumes.scanned;
      const requestLimit = Math.max(1, Math.min(VM_REAPER_MAX_BATCH_LIMIT, remaining));
      // The wall-clock budget must bound the in-flight call too, not only
      // loop entry: a hung provider request otherwise runs to the platform
      // limit. Timeout lands in the error branch below as partial coverage.
      const remainingBudgetMs = Math.max(
        1_000,
        VM_REAPER_SCAN_DEADLINE_MS - (Date.now() - scanStartedAtMs),
      );
      const listed = yield* listVolumes("blaxel", {
        limit: requestLimit,
        ...(cursor ? { cursor } : {}),
      }).pipe(
        Effect.timeoutFail({
          duration: remainingBudgetMs,
          onTimeout: () => new Error(
            `provider volume list exceeded the scan deadline (${remainingBudgetMs}ms remaining)`,
          ),
        }),
        Effect.either,
      );
      if (listed._tag === "Left") {
        summary.orphanVolumes.errors += 1;
        summary.orphanVolumes.coveragePartial = true;
        console.error("[VM] reaper could not list provider volumes", safeErrorMessage(listed.left));
        break;
      }

      summary.orphanVolumes.providerPages += 1;
      const page = normalizeVolumeInventory(listed.right, remaining);
      if (page.truncated) summary.orphanVolumes.coveragePartial = true;
      // The inventory is sliced before this point. Sorting is therefore at
      // most the remaining run budget, even for a legacy array response.
      const selected = selectOldestVolumes(page.volumes, remaining);
      summary.orphanVolumes.scanned += selected.length;

      const pageReport = yield* reportVolumePage(
        repo,
        summary,
        selected,
        input.limit,
        seenNames,
        input.now,
        input.minAgeMs,
      );
      candidateLimitReached ||= pageReport.candidateLimitReached;

      const nextCursor = page.nextCursor;
      if (!page.paginated) {
        // An array is the legacy provider contract. It cannot prove that the
        // inventory is complete, so report partial coverage even when short.
        summary.orphanVolumes.coveragePartial = true;
        exhausted = true;
      } else if (!nextCursor) {
        // A provider page with explicit pagination metadata and no cursor is
        // complete. A legacy object without that metadata is not proof of
        // completion, even if it returned fewer than the requested records.
        if (!page.complete) summary.orphanVolumes.coveragePartial = true;
        exhausted = true;
        // Do not retain the previous page's cursor when the inventory is
        // exhausted. A stale cursor would incorrectly turn a complete run
        // into a partial one below.
        cursor = undefined;
      } else if (seenCursors.has(nextCursor)) {
        summary.orphanVolumes.errors += 1;
        summary.orphanVolumes.coveragePartial = true;
        console.error("[VM] reaper stopped repeated provider volume cursor", { cursor: nextCursor });
        exhausted = true;
      } else {
        seenCursors.add(nextCursor);
        cursor = nextCursor;
      }

      // An empty page can still carry a valid continuation cursor. Follow it
      // rather than silently declaring the inventory complete.
      if (selected.length === 0 && !nextCursor) exhausted = true;
    }

    if (!exhausted && (
      cursor ||
      summary.orphanVolumes.scanned >= input.scanLimit ||
      summary.orphanVolumes.providerPages >= VM_REAPER_MAX_VOLUME_SCAN_PAGES
    )) {
      summary.orphanVolumes.coveragePartial = true;
    }
    // The candidate limit is a reporting cap. If an additional eligible
    // candidate was found, the run did not cover all reportable findings.
    if (candidateLimitReached) summary.orphanVolumes.coveragePartial = true;
  });
}

function reportVolumePage(
  repo: VmRepositoryShape,
  summary: MutableSummary,
  volumes: readonly VMVolume[],
  candidateLimit: number,
  seenNames: Set<string>,
  now: Date,
  minAgeMs: number,
): Effect.Effect<{ readonly candidateLimitReached: boolean }, never> {
  return Effect.gen(function* () {
    const free: Array<{ readonly volume: VMVolume; readonly name: string }> = [];
    const unknownAttachment: Array<{ readonly volume: VMVolume; readonly name: string }> = [];
    for (const volume of volumes) {
      const name = normalizedVolumeName(volume);
      if (!name || !isMachineOwnedHomeVolumeName(name)) continue;
      if (seenNames.has(name)) {
        summary.orphanVolumes.skipped += 1;
        continue;
      }
      seenNames.add(name);
      const state = attachmentState(volume);
      if (state === "attached") {
        summary.orphanVolumes.skipped += 1;
        console.info("[VM] reaper skipped attached volume", { volumeName: name });
      } else if (state === "unknown") {
        summary.orphanVolumes.unknownAttachment += 1;
        unknownAttachment.push({ volume, name });
      } else {
        free.push({ volume, name });
      }
    }

    // A persistent unknown state must not append one event per cron run
    // forever: the same 24h dedup window applies, keyed per event type.
    if (unknownAttachment.length > 0) {
      const recentUnknownKeys = yield* loadRecentReaperReportKeys(
        repo,
        ORPHAN_VOLUME_UNKNOWN_ATTACHMENT_EVENT,
        unknownAttachment.map(({ name }) => name),
        now,
        () => {
          summary.orphanVolumes.errors += 1;
        },
      );
      for (const { volume, name } of unknownAttachment) {
        if (recentUnknownKeys.has(name)) {
          summary.orphanVolumes.skipped += 1;
          console.info("[VM] reaper skipped unknown-attachment volume", {
            volumeName: name,
            reason: "already_reported",
          });
          continue;
        }
        const recorded = yield* recordSystemUsageEvent(repo, ORPHAN_VOLUME_UNKNOWN_ATTACHMENT_EVENT, {
          source: "vm_reaper",
          mode: "report",
          action: "report",
          reason: "attachment_state_unknown",
          volumeName: name,
          attachmentState: "unknown",
          attachment: "unknown",
          createdAt: volume.createdAt ?? null,
        });
        if (recorded) summary.orphanVolumes.reported += 1;
        else summary.orphanVolumes.errors += 1;
      }
    }

    if (free.length === 0) return { candidateLimitReached: false };

    const liveReferences = yield* loadLiveReferences(
      repo,
      free.map(({ name }) => name),
      summary,
    );
    if (!liveReferences) {
      const recentUnknownRefKeys = yield* loadRecentReaperReportKeys(
        repo,
        ORPHAN_VOLUME_UNKNOWN_REFERENCE_EVENT,
        free.map(({ name }) => name),
        now,
        () => {
          summary.orphanVolumes.errors += 1;
        },
      );
      for (const { volume, name } of free) {
        summary.orphanVolumes.unknownReference += 1;
        if (recentUnknownRefKeys.has(name)) {
          summary.orphanVolumes.skipped += 1;
          console.info("[VM] reaper skipped unknown-reference volume", {
            volumeName: name,
            reason: "already_reported",
          });
          continue;
        }
        const recorded = yield* recordSystemUsageEvent(repo, ORPHAN_VOLUME_UNKNOWN_REFERENCE_EVENT, {
          source: "vm_reaper",
          mode: "report",
          action: "report",
          reason: "live_reference_unknown",
          volumeName: name,
          attachmentState: "unattached",
          attachment: "unattached",
          liveReference: "unknown",
          createdAt: volume.createdAt ?? null,
        });
        if (recorded) summary.orphanVolumes.reported += 1;
        else summary.orphanVolumes.errors += 1;
      }
      return { candidateLimitReached: false };
    }

    const ageEligible: Array<{ readonly volume: VMVolume; readonly name: string }> = [];
    for (const item of free) {
      const { volume, name } = item;
      if (liveReferences.has(name)) {
        summary.orphanVolumes.skipped += 1;
        console.info("[VM] reaper skipped volume referenced by a live VM", { volumeName: name });
        continue;
      }

      const createdAt = parseVolumeCreatedAt(volume.createdAt);
      if (!createdAt || now.getTime() - createdAt.getTime() < minAgeMs) {
        summary.orphanVolumes.skipped += 1;
        console.info("[VM] reaper skipped orphan volume", {
          volumeName: name,
          reason: "age_unknown_or_below_grace",
        });
        continue;
      }
      ageEligible.push(item);
    }

    const recentKeys = yield* loadRecentReaperReportKeys(
      repo,
      ORPHAN_VOLUME_EVENT,
      ageEligible.map(({ name }) => name),
      now,
      () => {
        summary.orphanVolumes.errors += 1;
      },
    );

    let candidateLimitReached = false;
    for (const { volume, name } of ageEligible) {
      if (recentKeys.has(name)) {
        summary.orphanVolumes.skipped += 1;
        console.info("[VM] reaper skipped orphan volume", {
          volumeName: name,
          reason: "already_reported",
        });
        continue;
      }

      if (summary.orphanVolumes.candidates >= candidateLimit) {
        candidateLimitReached = true;
        summary.orphanVolumes.skipped += 1;
        continue;
      }
      summary.orphanVolumes.candidates += 1;
      const recorded = yield* recordSystemUsageEvent(repo, ORPHAN_VOLUME_EVENT, {
        source: "vm_reaper",
        mode: "report",
        action: "report",
        reason: "unattached_without_live_reference",
        volumeName: name,
        attachmentState: "unattached",
        attachment: "unattached",
        liveReference: false,
        createdAt: volume.createdAt ?? null,
      });
      if (recorded) summary.orphanVolumes.reported += 1;
      else summary.orphanVolumes.errors += 1;
    }
    return { candidateLimitReached };
  });
}

function loadRecentReaperReportKeys(
  repo: VmRepositoryShape,
  eventType: string,
  keys: readonly string[],
  now: Date,
  onError: (error: unknown) => void,
): Effect.Effect<Set<string>, never> {
  if (keys.length === 0) return Effect.succeed(new Set<string>());
  return repo.recentReaperReportKeys({
    eventType,
    keys,
    since: new Date(now.getTime() - VM_REAPER_REPORT_DEDUP_WINDOW_MS),
  }).pipe(
    Effect.map((reportedKeys) => new Set(
      reportedKeys.map((key) => key.trim()).filter(Boolean),
    )),
    Effect.catchAll((error) => Effect.sync(() => {
      onError(error);
      console.error("[VM] reaper could not query recent report keys", {
        eventType,
        error: safeErrorMessage(error),
      });
      return new Set<string>();
    })),
  );
}

function loadLiveReferences(
  repo: VmRepositoryShape,
  names: readonly string[],
  summary: MutableSummary,
): Effect.Effect<Set<string> | null, never> {
  if (!repo.listLiveHomeVolumeNames || names.length === 0) {
    summary.orphanVolumes.errors += 1;
    console.error("[VM] reaper cannot verify live volume references");
    return Effect.succeed(null);
  }
  return repo.listLiveHomeVolumeNames({ provider: "blaxel", volumeNames: names }).pipe(
    Effect.map((liveNames) => new Set(liveNames.map((name) => name.trim()).filter(Boolean))),
    Effect.catchAll((error) => Effect.sync(() => {
      summary.orphanVolumes.errors += 1;
      console.error("[VM] reaper could not load live volume references", safeErrorMessage(error));
      return null;
    })),
  );
}

function recordVmUsageEvent(
  repo: VmRepositoryShape,
  vm: CloudVmRow,
  eventType: string,
  metadata: Record<string, unknown>,
): Effect.Effect<boolean, never> {
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
    Effect.as(true),
    Effect.catchAll((error) => Effect.sync(() => {
      console.error("[VM] reaper could not record VM usage event", {
        vmId: vm.id,
        eventType,
        error: safeErrorMessage(error),
      });
      return false;
    })),
  );
}

function recordSystemUsageEvent(
  repo: VmRepositoryShape,
  eventType: string,
  metadata: Record<string, unknown>,
): Effect.Effect<boolean, never> {
  return repo.recordUsageEvent({
    userId: VM_REAPER_SYSTEM_USER_ID,
    billingTeamId: null,
    billingPlanId: null,
    eventType,
    provider: "blaxel",
    metadata,
  }).pipe(
    Effect.as(true),
    Effect.catchAll((error) => Effect.sync(() => {
      console.error("[VM] reaper could not record volume usage event", {
        eventType,
        volumeName: metadata.volumeName,
        error: safeErrorMessage(error),
      });
      return false;
    })),
  );
}

function normalizeVolumeInventory(value: VMVolumeInventory, limit: number): {
  readonly volumes: readonly VMVolume[];
  readonly nextCursor: string | null;
  readonly paginated: boolean;
  readonly complete: boolean;
  readonly truncated: boolean;
} {
  const boundedLimit = Math.max(1, Math.trunc(limit));
  if (Array.isArray(value)) {
    return {
      volumes: value.slice(0, boundedLimit),
      nextCursor: null,
      paginated: false,
      complete: false,
      truncated: value.length > boundedLimit,
    };
  }
  const page = value as VMVolumePage;
  const rawVolumes = Array.isArray(page.volumes) ? page.volumes : [];
  const truncated = rawVolumes.length > boundedLimit;
  const hasExplicitEnd = Object.prototype.hasOwnProperty.call(page, "nextCursor") &&
    page.nextCursor === null;
  return {
    volumes: rawVolumes.slice(0, boundedLimit),
    nextCursor: typeof page.nextCursor === "string" && page.nextCursor.trim().length > 0
      ? page.nextCursor.trim()
      : null,
    paginated: true,
    // A page is complete only when the provider explicitly says so, or when
    // it explicitly returns a null continuation cursor. A plain object with
    // no pagination metadata must remain partial for safety.
    complete: !truncated && (page.complete === true || (page.complete === undefined && hasExplicitEnd)),
    truncated,
  };
}

/** Sort the already-bounded page so the oldest records are reported first. */
function selectOldestVolumes(
  volumes: readonly VMVolume[],
  limit: number,
): readonly VMVolume[] {
  const boundedLimit = Math.max(1, Math.trunc(limit));
  return [...volumes].slice(0, boundedLimit).sort(compareVolumes);
}

function attachmentState(volume: VMVolume): "attached" | "unattached" | "unknown" {
  if (typeof volume.attachedTo === "string" && volume.attachedTo.trim().length > 0) return "attached";
  if (volume.attachedTo === null) return "unattached";
  if (volume.attachmentState === "attached" ||
    volume.attachmentState === "unattached" ||
    volume.attachmentState === "unknown") {
    return volume.attachmentState;
  }
  return "unknown";
}

function normalizedVolumeName(volume: VMVolume): string | null {
  const name = typeof volume.name === "string" ? volume.name.trim() : "";
  return name || null;
}

function compareVolumes(a: VMVolume, b: VMVolume): number {
  const aCreated = parseVolumeCreatedAt(a.createdAt)?.getTime() ?? Number.POSITIVE_INFINITY;
  const bCreated = parseVolumeCreatedAt(b.createdAt)?.getTime() ?? Number.POSITIVE_INFINITY;
  if (aCreated !== bCreated) return aCreated - bCreated;
  return (normalizedVolumeName(a) ?? "").localeCompare(normalizedVolumeName(b) ?? "");
}

function compareVmRows(a: CloudVmRow, b: CloudVmRow): number {
  const updated = a.updatedAt.getTime() - b.updatedAt.getTime();
  return updated || a.id.localeCompare(b.id);
}

/** Keep the oldest bounded subset of provisioning rows. */
function selectOldestVmRows(rows: readonly CloudVmRow[], limit: number): CloudVmRow[] {
  const boundedLimit = Math.max(1, Math.trunc(limit));
  if (rows.length <= boundedLimit) return [...rows].sort(compareVmRows);
  const selected: CloudVmRow[] = [];
  for (const row of rows) {
    let low = 0;
    let high = selected.length;
    while (low < high) {
      const middle = low + Math.floor((high - low) / 2);
      if (compareVmRows(selected[middle]!, row) <= 0) low = middle + 1;
      else high = middle;
    }
    if (low >= boundedLimit && selected.length >= boundedLimit) continue;
    selected.splice(low, 0, row);
    if (selected.length > boundedLimit) selected.pop();
  }
  return selected;
}

function resolveLimit(value: number | undefined, envValue: string | undefined, fallback: number): number {
  const candidate = typeof value === "number" && Number.isFinite(value)
    ? value
    : parsePositiveInteger(envValue) ?? fallback;
  return Math.max(1, Math.min(VM_REAPER_MAX_BATCH_LIMIT, Math.trunc(candidate)));
}

function resolveScanLimit(value: number | undefined, envValue: string | undefined, candidateLimit: number): number {
  const candidate = typeof value === "number" && Number.isFinite(value)
    ? value
    : parsePositiveInteger(envValue) ?? VM_REAPER_DEFAULT_VOLUME_SCAN_LIMIT;
  return Math.max(
    candidateLimit,
    Math.min(VM_REAPER_MAX_VOLUME_SCAN_LIMIT, Math.max(1, Math.trunc(candidate))),
  );
}

function resolveStuckAgeMs(env: Record<string, string | undefined>): number {
  const raw = env.CMUX_VM_REAPER_STUCK_PROVISIONING_MINUTES ??
    env.CMUX_VM_REAPER_STUCK_THRESHOLD_MINUTES ??
    env.CMUX_VM_REAPER_STUCK_AGE_MINUTES;
  return (parsePositiveInteger(raw) ?? VM_REAPER_DEFAULT_STUCK_PROVISIONING_MINUTES) * 60 * 1_000;
}

function resolveDurationOption(value: number | undefined, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 ? Math.trunc(value) : fallback;
}

function parsePositiveInteger(value: string | undefined): number | null {
  const trimmed = value?.trim();
  if (!trimmed || !/^\d+$/.test(trimmed)) return null;
  const parsed = Number(trimmed);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : null;
}

function parseVolumeCreatedAt(value: unknown): Date | null {
  const parsed = value instanceof Date
    ? new Date(value.getTime())
    : typeof value === "number"
      ? new Date(value)
      : typeof value === "string" && value.trim().length > 0
        ? new Date(value)
        : null;
  return parsed && Number.isFinite(parsed.getTime()) ? parsed : null;
}

function ageMinutes(createdAt: Date, now: Date): number {
  return Math.max(0, Math.round((now.getTime() - createdAt.getTime()) / 60_000));
}

function isOlderThan(createdAt: Date, now: Date, thresholdMs: number): boolean {
  return now.getTime() - createdAt.getTime() > thresholdMs;
}

function safeErrorMessage(error: unknown): string {
  const raw = error instanceof Error ? error.message : String(error);
  return raw.replace(/Bearer\s+\S+/gi, "Bearer [redacted]").slice(0, 500);
}

export const VM_REAPER_ORPHAN_VOLUME_EVENT = ORPHAN_VOLUME_EVENT;
export const VM_REAPER_ORPHAN_VOLUME_UNKNOWN_ATTACHMENT_EVENT = ORPHAN_VOLUME_UNKNOWN_ATTACHMENT_EVENT;
export const VM_REAPER_ORPHAN_VOLUME_UNKNOWN_REFERENCE_EVENT = ORPHAN_VOLUME_UNKNOWN_REFERENCE_EVENT;
export const VM_REAPER_STUCK_PROVISIONING_EVENT = STUCK_PROVISIONING_EVENT;
