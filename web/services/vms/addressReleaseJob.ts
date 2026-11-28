import * as Effect from "effect/Effect";
import { isSandboxRunVm } from "../runs/model";
import {
  addressReleaseFromMetadata,
  addressReleaseIneligibleReason,
  addressReleaseRestorable,
  pausedAddressReleaseHours,
  VM_ADDRESS_RELEASE_BATCH_LIMIT,
  VM_ADDRESS_RELEASE_SNAPSHOT_NAME,
  type VmAddressRelease,
} from "./addressRelease";
import { CLOUD_REMOTE_AUTH_METADATA_KEY, cloudRemoteAuthMode } from "./clientGrant";
import { VmProviderGateway, type VmProviderGatewayShape } from "./providerGateway";
import { VmRepository, type CloudVmRow, type VmRepositoryShape } from "./repository";
import { snapshotResourceReservation } from "./workflows";

export type VmAddressReleaseSummary = {
  /** False when CMUX_VM_PAUSED_ADDRESS_RELEASE_HOURS is unset (the default). */
  readonly enabled: boolean;
  readonly checked: number;
  readonly parked: number;
  readonly skipped: number;
  readonly errors: number;
};

type Outcome = "parked" | "skipped" | "error";

/**
 * Park paused machines that have held a private address for longer than the
 * configured hours (addressRelease.ts). Each row is snapshotted, the snapshot
 * verified and recorded, and only then is the provider machine destroyed. Any
 * failure before the destroy leaves the machine exactly as it was.
 */
export function releasePausedAddresses(input: {
  readonly now?: () => number;
  readonly limit?: number;
  readonly env?: Readonly<Record<string, string | undefined>>;
} = {}) {
  return Effect.gen(function* () {
    const hours = pausedAddressReleaseHours(input.env);
    const off: VmAddressReleaseSummary = { enabled: false, checked: 0, parked: 0, skipped: 0, errors: 0 };
    if (hours === null) return off;
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    if (!repo.addressReleaseCandidates || !repo.writeAddressRelease || !providers.snapshot || !providers.listSnapshots || !providers.getPauseState) {
      return off;
    }
    const now = input.now ?? Date.now;
    const rows = yield* repo.addressReleaseCandidates({
      pausedBefore: new Date(now() - hours * 3_600_000),
      limit: input.limit ?? VM_ADDRESS_RELEASE_BATCH_LIMIT,
    });
    let parked = 0;
    let skipped = 0;
    let errors = 0;
    for (const row of rows) {
      const outcome = yield* parkRow(repo, providers, row, now, input.env ?? process.env).pipe(
        Effect.catchAll((error) => {
          console.warn("[VM] address release failed", JSON.stringify({ vmId: row.id, error: String(error) }));
          return Effect.succeed<Outcome>("error");
        }),
      );
      if (outcome === "parked") parked += 1;
      else if (outcome === "skipped") skipped += 1;
      else errors += 1;
    }
    return { enabled: true, checked: rows.length, parked, skipped, errors } satisfies VmAddressReleaseSummary;
  });
}

function parkRow(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  row: CloudVmRow,
  now: () => number,
  env: Readonly<Record<string, string | undefined>>,
) {
  return Effect.gen(function* () {
    const writeRelease = repo.writeAddressRelease!;
    const getPauseState = providers.getPauseState!;
    const providerVmId = row.providerVmId;
    const previous = addressReleaseFromMetadata(row.providerMetadata);
    if (!providerVmId) return "skipped" as Outcome;
    if (previous && previous.state !== "parking") return "skipped" as Outcome;
    if (!previous && addressReleaseIneligibleReason(row, isSandboxRunVm(row)) !== null) return "skipped" as Outcome;
    // The same shape recordOwnedSnapshot writes and the restore checks.
    if (!previous && !addressReleaseRestorable(row.billingPlanId, snapshotResourceReservation(row.providerMetadata, null), env)) {
      return "skipped" as Outcome;
    }

    const state = yield* getPauseState(row.provider, providerVmId);
    if (previous && state === "destroyed") {
      // An earlier run destroyed the machine after recording the snapshot
      // but did not get to mark the row parked.
      return (yield* markParked(writeRelease, row, providerVmId, previous, now)) ? "parked" as Outcome : "skipped" as Outcome;
    }
    // Only a machine the provider itself reports paused is snapshotted. A
    // machine that woke (traffic, console) is left for the pause crons.
    if (state !== "paused") return "skipped" as Outcome;

    // A row left `parking` takes a fresh snapshot too: the machine may have
    // run between the first snapshot and now, and the newest state is what
    // the restore must bring back.
    const snapshot = yield* providers.snapshot!(row.provider, providerVmId, VM_ADDRESS_RELEASE_SNAPSHOT_NAME);
    const listed = yield* providers.listSnapshots!(row.provider, providerVmId);
    if (!listed.some((entry) => entry.id === snapshot.id)) return "error" as Outcome;
    yield* recordOwnedSnapshot(repo, row, snapshot.id);

    const release: VmAddressRelease = {
      state: "parking",
      snapshotId: snapshot.id,
      sourceProviderVmId: providerVmId,
      releasedIpv4: typeof row.providerMetadata?.networkIpv4 === "string" ? row.providerMetadata.networkIpv4 : null,
      startedAt: previous?.startedAt ?? now(),
    };
    const fenced = yield* writeRelease({
      id: row.id,
      providerVmId,
      fromStatus: "paused",
      fromState: previous ? "parking" : null,
      updatedAt: row.updatedAt ?? undefined,
      release,
    });
    // Someone resumed, attached or changed the row since it was read; the
    // snapshot stays owned and visible, the machine is untouched.
    if (!fenced) return "skipped" as Outcome;

    // Narrow the window for a resume that began before the fence.
    const stillPaused = yield* getPauseState(row.provider, providerVmId);
    if (stillPaused !== "paused") return "skipped" as Outcome;

    yield* providers.destroy(row.provider, providerVmId, undefined, { strict: true });
    return (yield* markParked(writeRelease, row, providerVmId, release, now)) ? "parked" as Outcome : "skipped" as Outcome;
  });
}

function markParked(
  writeRelease: NonNullable<VmRepositoryShape["writeAddressRelease"]>,
  row: CloudVmRow,
  providerVmId: string,
  release: VmAddressRelease,
  now: () => number,
) {
  return writeRelease({
    id: row.id,
    providerVmId,
    fromStatus: "paused",
    fromState: "parking",
    release: { ...release, state: "parked", parkedAt: now() },
    releaseAddress: true,
  });
}

/** The same `vm.snapshot.created` ownership row a person's own snapshot writes, so restore accepts it. */
function recordOwnedSnapshot(repo: VmRepositoryShape, row: CloudVmRow, snapshotId: string) {
  return Effect.gen(function* () {
    const owned = yield* repo.hasOwnedSnapshot({
      userId: row.userId,
      billingTeamId: row.billingTeamId,
      provider: row.provider,
      snapshotId,
    });
    if (owned) return;
    // No stats read: a paused machine is not woken for one, and the row's
    // own reservation (or the conservative fallback) is what restore claims.
    const reservation = snapshotResourceReservation(row.providerMetadata, null);
    const event = {
      userId: row.userId,
      billingTeamId: row.billingTeamId,
      billingPlanId: row.billingPlanId,
      vmId: row.id,
      eventType: "vm.snapshot.created",
      provider: row.provider,
      imageId: row.imageId,
      metadata: {
        snapshotId,
        named: true,
        name: VM_ADDRESS_RELEASE_SNAPSHOT_NAME,
        addressRelease: true,
        vcpus: reservation.vcpus,
        memoryMb: reservation.memoryMb,
        diskMb: reservation.diskMb,
        [CLOUD_REMOTE_AUTH_METADATA_KEY]: cloudRemoteAuthMode(row.providerMetadata, "trusted-carrier"),
      },
    };
    yield* repo.recordSnapshotUsageEventIfMissing
      ? repo.recordSnapshotUsageEventIfMissing(event)
      : repo.recordUsageEvent(event);
  });
}
