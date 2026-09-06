import { createHash, randomUUID } from "node:crypto";
import * as Effect from "effect/Effect";
import * as Either from "effect/Either";
import * as Exit from "effect/Exit";
import type { CreateOptions } from "./drivers/types";
import * as Layer from "effect/Layer";
import type {
  AttachEndpoint,
  AttachOptions,
  ExecResult,
  ProviderId,
  SSHEndpoint,
  VmEdgeRule,
  VMHandle,
  VMStats,
  VMStatus,
} from "./drivers";
import { isProviderId, vmCapabilitiesFor } from "./drivers";
import {
  VmBillingGateway,
  VmBillingGatewayLive,
  type BillingCustomerType,
  type VmCreateCreditGrant,
  type VmCreateCreditReservation,
  type VmBillingGatewayShape,
} from "./billingGateway";
import { vmCreateDisabledReason } from "./config";
import {
  DEFAULT_VM_RESOURCE_RESERVATION,
  VM_DISK_MB_MAX,
  VM_DISK_MB_STEP,
  VM_RESOURCE_RESIZE_PENDING_METADATA_KEY,
  VM_RESOURCE_RESIZE_UNCONFIRMED_METADATA_KEY,
  VM_RESOURCE_FORK_PENDING_METADATA_KEY,
  hasVmResourceReservationMetadata,
  vmResourceReconcileRetryFromMetadata,
  vmResourceReservationForCreate,
  vmResourceReservationFromMetadata,
  vmResourceForkPendingFromMetadata,
  vmResourceResizePendingFromMetadata,
  vmResourceResizeUnconfirmedFromMetadata,
  vmProviderResourceSize,
  type VmResourceReservation,
  type VmResourceResizePending,
  type VmResourceResizeUnconfirmed,
} from "./machineSpec";
import {
  VmBillingError,
  VmAccountDeletionIdentityRevocationError,
  VmAttachTransportUnsupportedError,
  VmCreateDisabledError,
  VmCreateFailedError,
  VmCreateInProgressError,
  VmDatabaseError,
  VmFreeAccessExpiredError,
  VmModelPlaneError,
  VmNotFoundError,
  VmResizeInvalidError,
  VmOperationUnsupportedError,
  VmProviderOperationError,
  VmSnapshotNotFoundError,
  VM_MODEL_PLANE_FAILURE_CODES,
  isVmCreateCreditsInsufficientError,
  isVmLimitExceededError,
  isVmModelPlaneError,
  vmWorkflowErrorCause,
  type VmWorkflowError,
} from "./errors";
import {
  isPaidVmPlan,
  isVmFreeAccessExpired,
  maxActiveVmsForPlan,
  vmFreeAccessWindowDays,
} from "./entitlements";
import { networkSlugForUser, privateNetworkUnavailableReason, resolveOwnerNetwork } from "./privateNetwork";
import { isProviderIdentityNotFoundError, isProviderNotFoundError } from "./providerErrors";
import { VmProviderGateway, VmProviderGatewayLive, type VmProviderGatewayShape } from "./providerGateway";
import { withVmProductAnalytics } from "./productAnalytics";
import {
  PROVIDER_CREATE_UNAVAILABLE_FAILURE_CODE,
  VmRepository,
  vmRepositoryLiveShape,
  type BeginCreateResult,
  type BeginBaseCreateResult,
  type CloudVmBaseGenerationRow,
  type CloudVmBaseRow,
  type CloudVmAccessLeaseRow,
  type CloudVmSessionRow,
  type CloudVmStatus,
  type CloudVmLeaseKind,
  type CloudVmRow,
  type VmRepositoryShape,
  type VmResizeReservation,
} from "./repository";
import { measureVmEffect, type VmTimingSink } from "./timings";

export {
  homeVolumeNameForUser,
  homeVolumeTemplateForUser,
  isMachineOwnedHomeVolumeName,
} from "./volumeNaming";
export {
  deletePrivateNetworkingForAccountDeletion,
  enrollVmTunnel,
  isWireGuardPublicKey,
  listVmTunnels,
  listVmAccessGrants,
  networkSlugForUser,
  readVmTunnel,
  renameVmAccessGrant,
  resolveOwnerNetwork,
  revokeVmAccessGrant,
  revokeVmTunnel,
  tunnelSlugForDevice,
} from "./privateNetwork";
export type { VmTunnelDescriptor } from "./privateNetwork";
export { reapVmResources } from "./reaper";
export type {
  VmReaperOptions,
  VmReaperSummary,
} from "./reaper";
import {
  homeVolumeNameForUser,
  homeVolumeTemplateForUser,
} from "./volumeNaming";

export type VmEntry = {
  readonly providerVmId: string;
  readonly provider: ProviderId;
  readonly image: string;
  readonly imageVersion: string | null;
  readonly status: CloudVmStatus;
  readonly createdAt: number;
  readonly displayName: string | null;
  /** Generated three-word name (services/vms/vmNaming.ts); null on rows older than the column. */
  readonly slug: string | null;
  /** The machine's address on its owner's private network, when it has one. */
  readonly addressIpv4: string | null;
  readonly addressIpv6: string | null;
};

export type BaseVmEntry = VmEntry & {
  readonly baseId: string;
  readonly baseName: string;
  readonly generation: number;
  readonly retainedProviderVmId: string | null;
};

export type CloudVmSessionEntry = CloudVmSessionRow;

/**
 * What the machine gets from the coderouter model plane: guest env (base
 * URLs, placeholder keys, the VM id) and the edge rules that inject the real
 * credential. Provisioned once the VM row exists, before the provider call.
 */
export type VmModelPlaneMaterials = {
  readonly edgeRules: readonly VmEdgeRule[];
};

/**
 * The model-plane seam the routes inject (services/vms/modelPlaneGateway.ts).
 * `provision` rejects with VmModelPlaneError to fail the create; `revoke` is
 * idempotent and called best-effort on destroy and on every create rollback.
 */
export type VmModelPlaneProvisioner = {
  readonly provision: (cloudVmId: string) => Promise<VmModelPlaneMaterials>;
  readonly revoke: (cloudVmId: string) => Promise<void>;
};

/** The revoke half alone, for paths that only end a machine. */
export type VmModelPlaneRevoker = Pick<VmModelPlaneProvisioner, "revoke">;

/**
 * The Postgres repository wrapped so every usage-ledger write also reaches
 * PostHog as a product event (services/vms/productAnalytics.ts).
 */
export const VmRepositoryWithAnalyticsLive = Layer.succeed(
  VmRepository,
  withVmProductAnalytics(vmRepositoryLiveShape),
);

export const VmWorkflowLive = Layer.mergeAll(VmRepositoryWithAnalyticsLive, VmProviderGatewayLive, VmBillingGatewayLive);

const EXPIRED_IDENTITY_REVOKE_BATCH = 5;
const EXPIRED_IDENTITY_REVOKE_RETRY_BACKOFF_MS = 10 * 60 * 1000;
const IDENTITY_REVOKE_PROVIDER_TIMEOUT = "5 seconds";
const ACTIVE_IDENTITY_REVOKE_HOT_PATH_LIMIT = 8;
const ACCOUNT_DELETION_IDENTITY_REVOKE_BATCH = 8;
const VM_STATUS_RECONCILE_BATCH_LIMIT = 200;
const LEGACY_RESOURCE_RECONCILE_BATCH_LIMIT = 50;
const LEGACY_RESOURCE_RECONCILE_CONCURRENCY = 5;
const LEGACY_RESOURCE_RECONCILE_RETRY_AFTER_MS = 5 * 60 * 1000;
// Ten concurrent waves of this batch must leave time for status reconciliation
// in a short-lived cron invocation, even when a provider is fully hung.
const LEGACY_RESOURCE_RECONCILE_PROVIDER_TIMEOUT = "2 seconds";
// Provider stats are advisory on request paths. A stalled provider must not
// keep a snapshot or fork HTTP request open indefinitely.
const FOREGROUND_PROVIDER_STATS_TIMEOUT = "2 seconds";
const RESIZE_PENDING_RECOVERY_AFTER_MS = 15 * 60 * 1000;
const RESIZE_UNCONFIRMED_RECOVERY_AFTER_MS = 30 * 60 * 1000;
const PREVIEW_ENDPOINT_LEASE_TTL_MS = 12 * 60 * 60 * 1000;

type ExistingVmAccessInput = {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
  readonly provider?: ProviderId;
  /** Caller's CURRENT billing plan; access verbs use it for the free window. */
  readonly callerPlanId?: string | null;
};

export type VmProviderStatusReconcileResult = {
  readonly checked: number;
  readonly updated: number;
  readonly destroyed: number;
  readonly skipped: number;
  readonly skippedNoGetStatus: boolean;
};

export async function runVmWorkflow<A>(
  program: Effect.Effect<A, VmWorkflowError, VmRepository | VmProviderGateway | VmBillingGateway>,
): Promise<A> {
  try {
    return await Effect.runPromise(program.pipe(Effect.provide(VmWorkflowLive)));
  } catch (err) {
    throw vmWorkflowErrorCause(err) ?? err;
  }
}

/**
 * A row whose provider is no longer registered belongs to a retired driver.
 * Drivers leave with a code deploy while the rows they wrote survive until an
 * operator runs the matching migration, so every read path must treat such a
 * row as unaddressable instead of asking the registry for a driver it no
 * longer has. The registry throws for an unknown id, and one surviving retired
 * row was enough to turn the whole machine list into a 500 during a provider
 * migration.
 */
export function isRetiredProviderRow(row: Pick<CloudVmRow, "provider">): boolean {
  return !isProviderId(row.provider);
}

export function listUserVms(userId: string, billingTeamId?: string | null) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const rows = yield* repo.listUserVms(userId, billingTeamId);
    return rows
      .filter((row) => row.providerVmId && !isRetiredProviderRow(row))
      .map(vmEntryFromRow);
  });
}

export function getVm(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
}) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const vm = yield* requireUserVm(input);
    const providerVmId = vm.providerVmId ?? input.providerVmId;
    const getStatus = providers.getStatus;
    if (!getStatus) return vmEntryFromRow(vm);

    const providerStatus = yield* getStatus(vm.provider, providerVmId).pipe(
      Effect.catchAll((err) =>
        isProviderNotFoundError(err)
          ? Effect.succeed("destroyed" as const)
          : Effect.fail(err),
      ),
    );
    if (providerStatus !== "creating") {
      const dbStatus = observedDbStatus(vm, providerStatus);
      if (dbStatus !== vm.status) {
        const didUpdate = yield* repo.markProviderObservedStatus({
          id: vm.id,
          providerVmId,
          status: dbStatus,
        });
        if (didUpdate) return vmEntryFromRow({ ...vm, status: dbStatus, updatedAt: new Date() });
      }
    }
    return vmEntryFromRow(vm);
  });
}

/** Sets or clears the user-facing label on a machine the caller owns. The
 * provider VM id stays the machine's address; this is display-only. */
export function renameVm(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
  readonly displayName: string | null;
}) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const vm = yield* requireUserVm(input);
    yield* repo.setDisplayName({ id: vm.id, displayName: input.displayName });
    return vmEntryFromRow({ ...vm, displayName: input.displayName, updatedAt: new Date() });
  });
}

export function reconcileVmProviderStatuses(input: {
  readonly limit?: number;
  /** Revokes coderouter tokens for machines the provider reports gone. */
  readonly modelPlane?: VmModelPlaneRevoker;
} = {}): Effect.Effect<VmProviderStatusReconcileResult, VmWorkflowError, VmRepository | VmProviderGateway> {
  return Effect.gen(function* () {
    const providers = yield* VmProviderGateway;
    const repo = yield* VmRepository;
    // Legacy resource claims are repaired by this background cron. Keeping
    // provider fanout here removes migration work from user-facing creates.
    yield* reconcileLegacyResourceReservations(repo, providers, {
      limit: LEGACY_RESOURCE_RECONCILE_BATCH_LIMIT,
    });
    const getStatus = providers.getStatus;
    if (!getStatus) {
      return {
        checked: 0,
        updated: 0,
        destroyed: 0,
        skipped: 0,
        skippedNoGetStatus: true,
      };
    }

    const candidates = yield* repo.reconciliationCandidates({
      limit: boundedVmStatusReconcileLimit(input.limit),
    });
    const outcomes = yield* Effect.forEach(
      candidates,
      (vm) => reconcileObservedProviderStatus(repo, getStatus, vm, "provider_status_cron", input.modelPlane),
      { concurrency: 10 },
    );
    // Network heal moved here from the create path: re-create the members
    // rule of every owner network this batch touches if it went missing.
    const ensureNetwork = providers.ensureNetwork;
    if (ensureNetwork) {
      const owners = new Map<string, { userId: string; provider: ProviderId }>();
      for (const vm of candidates) {
        if (vm.status === "destroyed" || privateNetworkUnavailableReason(vm.provider, true)) continue;
        owners.set(`${vm.provider}:${vm.userId}`, { userId: vm.userId, provider: vm.provider });
      }
      yield* Effect.forEach(
        [...owners.values()],
        (owner) =>
          ensureNetwork(owner.provider, { slug: networkSlugForUser(owner.userId), heal: true }).pipe(
            Effect.catchAll(() => Effect.void),
          ),
        { concurrency: 4, discard: true },
      );
    }
    let updated = 0;
    let destroyed = 0;
    let skipped = 0;
    for (const outcome of outcomes) {
      if (outcome === "updated") updated += 1;
      else if (outcome === "destroyed") destroyed += 1;
      else if (outcome === "skipped") skipped += 1;
    }
    return {
      checked: candidates.length,
      updated,
      destroyed,
      skipped,
      skippedNoGetStatus: false,
    };
  });
}

/**
 * The home volume a destroyed machine owns exclusively, or null when there is
 * nothing safe to delete. Per-machine volumes are marked at create
 * (`providerMetadata.homeVolumePerMachine`); rows created before that marker
 * existed are recognized by the per-machine naming scheme
 * (`<user-home>-<machine>`). The shared per-user volume never matches: other
 * machines, including future ones, mount it.
 */
export function machineOwnedHomeVolume(
  vm: Pick<CloudVmRow, "userId" | "providerMetadata">,
  providerVmId: string,
): string | null {
  const metadata = vm.providerMetadata ?? {};
  const homeVolume = metadata["homeVolume"];
  if (typeof homeVolume !== "string" || homeVolume.length === 0) return null;
  const sharedName = homeVolumeNameForUser(vm.userId);
  if (homeVolume === sharedName) return null;
  if (metadata["homeVolumePerMachine"] === true) return homeVolume;
  return providerVmId && homeVolume === `${sharedName}-${providerVmId}` ? homeVolume : null;
}

/**
 * Best-effort provider rollback of a just-created machine the workflow could
 * not finalize: the sandbox, and any per-machine home volume the create
 * provisioned (nothing ever reattaches it, but its storage keeps billing). A
 * shared per-user home is never deleted here — the next create reattaches it
 * by name.
 */
function rollbackProviderCreate(
  providers: VmProviderGatewayShape,
  provider: ProviderId,
  handle: VMHandle,
): Effect.Effect<void> {
  return Effect.gen(function* () {
    yield* providers.destroy(provider, handle.providerVmId).pipe(Effect.catchAll(() => Effect.void));
    const metadata = handle.providerMetadata ?? {};
    const homeVolume = metadata["homeVolume"];
    if (
      metadata["homeVolumePerMachine"] === true &&
      typeof homeVolume === "string" &&
      homeVolume.length > 0 &&
      providers.deleteHomeVolume
    ) {
      yield* providers.deleteHomeVolume(provider, homeVolume).pipe(
        Effect.catchAll((err) =>
          Effect.sync(() => {
            console.error(
              `[vm] create rollback leaked home volume ${homeVolume} for ${handle.providerVmId}`,
              errorMessage(err.cause),
            );
          }),
        ),
      );
    }
  });
}

export function createVm(input: {
  readonly userId: string;
  readonly billingCustomerType: BillingCustomerType;
  readonly billingTeamId: string;
  readonly billingPlanId: string;
  readonly maxActiveVms: number | null;
  readonly provider: ProviderId;
  readonly image: string;
  readonly imageVersion?: string | null;
  readonly idempotencyKey?: string;
  /**
   * "Your computer" semantics: mount a per-user persistent volume as the machine's home so
   * the sandbox is disposable compute around durable data. The volume name is derived from
   * the user id, so recreating the machine (TTL expiry, provider loss) finds the same home.
   */
  readonly persistentHome?: boolean;
  /**
   * Fresh-machine semantics: instead of the single shared user volume, mount a
   * volume derived from the machine's own generated name, so any number of
   * machines (up to the plan limit) each keep their own durable home.
   */
  readonly perMachineHome?: boolean;
  /** Runtime memory requested by the caller, in MB. Providers may ignore it. */
  readonly memoryMb?: number;
  /** See CreateOptions.imageSize: CPU and memory are baked; disk can grow later. */
  readonly imageSize?: CreateOptions["imageSize"];
  /** Override the reservation when cloning an existing machine shape. */
  readonly resourceReservation?: VmResourceReservation;
  /** How the machine came to exist; analytics only. Defaults to `create`. */
  readonly origin?: VmCreateOrigin;
  /**
   * Wires the machine to coderouter. Provisioned after the row exists (its id
   * is the token binding) and before the provider call; a failure fails the
   * create. Omitted only by the local-dev kill switch, which creates an
   * unwired machine.
   */
  readonly modelPlane?: VmModelPlaneProvisioner;
  readonly timing?: VmTimingSink;
}): Effect.Effect<VmEntry, VmWorkflowError, VmRepository | VmProviderGateway | VmBillingGateway> {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const billing = yield* VmBillingGateway;
    // Record paid machine shapes for snapshot, fork, and resize recovery.
    const beginInput = isPaidVmPlan(input.billingPlanId)
      ? {
        ...input,
        // Reserve the logical CPU and memory profile when memoryMb is present,
        // while retaining the baked image's actual disk claim. A direct caller
        // may instead provide only imageSize; in that form the image is the
        // authoritative request.
        resourceReservation: input.resourceReservation ?? vmResourceReservationForCreate({
          memoryMb: input.memoryMb,
          imageSize: input.imageSize,
        }),
      }
      : input;

    // The owner's network row and the create row do not depend on each other,
    // so the request pays the slower of the two reads, not their sum. A network
    // failure after the row was inserted marks that row failed instead of
    // leaving it "creating" forever; the network itself is an account-level
    // resource, so nothing there needs unwinding.
    const [networkResult, create] = yield* Effect.all(
      [
        Effect.either(
          measureVmEffect(
            input.timing,
            "resolve_network",
            resolveOwnerNetwork({ userId: input.userId, provider: input.provider }),
          ),
        ),
        beginCreateWithLazyProviderRefresh(repo, providers, beginInput),
      ],
      { concurrency: 2 },
    );
    if (Either.isLeft(networkResult)) {
      if (create.inserted) {
        yield* repo.markCreateFailed({
          id: create.vm.id,
          code: PROVIDER_CREATE_UNAVAILABLE_FAILURE_CODE,
          message: errorMessage(networkResult.left),
        }).pipe(Effect.catchAll(() => Effect.void));
      }
      return yield* Effect.fail(networkResult.left);
    }
    const network = networkResult.right;

    if (!create.inserted) {
      const existing = create.vm;
      if (existing.status === "failed") {
        return yield* Effect.fail(
          new VmCreateFailedError({
            idempotencyKey: input.idempotencyKey ?? "",
            code: existing.failureCode,
            message: existing.failureMessage ?? "previous VM create failed",
          }),
        );
      }
      if (!existing.providerVmId) {
        return yield* Effect.fail(
          new VmCreateInProgressError({ idempotencyKey: input.idempotencyKey ?? "" }),
        );
      }
      return vmEntryFromRow(existing);
    }

    const creditReservation = yield* reserveCreateCredit(billing, repo, input, create.vm);
    yield* recordCreateRequestedEvents(repo, input, create.vm, creditReservation);

    const materials = yield* measureVmEffect(
      input.timing,
      "model_plane_provision",
      provisionModelPlane(input.modelPlane, create.vm.id),
    ).pipe(
      Effect.tapError((err) =>
        Effect.all([
          refundCredit(billing, repo, create.vm, creditReservation),
          repo.markCreateFailed({
            id: create.vm.id,
            code: VM_MODEL_PLANE_FAILURE_CODES[err.kind],
            message: errorMessage(err.cause),
          }),
          repo.recordUsageEvent({
            userId: input.userId,
            billingTeamId: input.billingTeamId,
            billingPlanId: input.billingPlanId,
            vmId: create.vm.id,
            eventType: "vm.create.failed",
            provider: input.provider,
            imageId: input.image,
            metadata: {
              operation: "model_plane_provision",
              kind: err.kind,
              message: errorMessage(err.cause),
            },
          }),
        ], { discard: true }).pipe(Effect.catchAll(() => Effect.void))
      ),
    );

    const handle = yield* measureVmEffect(
      input.timing,
      "provider_create",
      providers.create(input.provider, {
        image: input.image,
        displayName: create.vm.slug ?? undefined,
        providerMetadata: create.vm.providerMetadata,
        homeVolume: input.perMachineHome
          ? homeVolumeTemplateForUser(input.userId)
          : input.persistentHome
            ? homeVolumeNameForUser(input.userId)
            : undefined,
        memoryMb: input.memoryMb,
        imageSize: input.imageSize,
        edgeRules: materials?.edgeRules,
        network: { id: network.providerNetworkId },
      }),
    ).pipe(
      Effect.tapError((err) =>
        Effect.all([
          revokeModelPlane(input.modelPlane, create.vm.id),
          refundCredit(billing, repo, create.vm, creditReservation),
          repo.markCreateFailed({
            id: create.vm.id,
            // providers.create fails only with VmProviderOperationError, and
            // the caller is told it is retryable (vm_cloud_service_unavailable,
            // retryAfterSeconds ~5), so store the code that lets a same-key
            // retry reach the provider again immediately.
            code: PROVIDER_CREATE_UNAVAILABLE_FAILURE_CODE,
            message: errorMessage(err.cause),
          }),
          repo.recordUsageEvent({
            userId: input.userId,
            billingTeamId: input.billingTeamId,
            billingPlanId: input.billingPlanId,
            vmId: create.vm.id,
            eventType: "vm.create.failed",
            provider: input.provider,
            imageId: input.image,
            metadata: { operation: err.operation, message: errorMessage(err.cause) },
          }),
        ], { discard: true }).pipe(Effect.catchAll(() => Effect.void))
      ),
    );

    const running = yield* measureVmEffect(
      input.timing,
      "mark_running",
      repo.markCreateRunning({
        id: create.vm.id,
        providerVmId: handle.providerVmId,
        image: handle.image,
        imageVersion: input.imageVersion ?? null,
        providerMetadata: handle.providerMetadata ?? create.vm.providerMetadata,
      }),
    ).pipe(
      Effect.catchAll((err) =>
        Effect.gen(function* () {
          yield* rollbackProviderCreate(providers, input.provider, handle);
          yield* revokeModelPlane(input.modelPlane, create.vm.id);
          yield* refundCredit(billing, repo, create.vm, creditReservation);
          yield* repo.markCreateFailed({
            id: create.vm.id,
            code: "database_finalize_failed",
            message: "Cloud VM state update failed.",
          }).pipe(Effect.catchAll(() => Effect.void));
          yield* recordCreateFailureEvent(
            repo,
            input,
            create.vm,
            "database_finalize_failed",
            errorMessage(err.cause),
          ).pipe(Effect.catchAll(() => Effect.void));
          return yield* Effect.fail(err);
        }),
      ),
    );

    yield* recordCreateSuccessEvents(repo, input, running);

    return vmEntryFromRow(running);
  });
}

/**
 * Runs the injected model-plane provisioning for a row that now exists. The
 * gateway rejects with VmModelPlaneError; anything else is treated as
 * coderouter being unavailable so the row is marked with a retryable code.
 */
function provisionModelPlane(
  modelPlane: VmModelPlaneProvisioner | undefined,
  cloudVmId: string,
): Effect.Effect<VmModelPlaneMaterials | null, VmModelPlaneError> {
  if (!modelPlane) return Effect.succeed(null);
  return Effect.tryPromise({
    try: () => modelPlane.provision(cloudVmId),
    catch: (cause) => (isVmModelPlaneError(cause) ? cause : new VmModelPlaneError({ kind: "unavailable", cause })),
  });
}

/**
 * Best-effort token revocation for a machine that is gone or never came up.
 * A failed revoke is logged, never fails the caller: the token stays bound to
 * a VM id no edge will ever inject again, so it is unusable anyway.
 */
function revokeModelPlane(
  modelPlane: VmModelPlaneRevoker | undefined,
  cloudVmId: string,
): Effect.Effect<void> {
  if (!modelPlane) return Effect.void;
  return Effect.tryPromise(() => modelPlane.revoke(cloudVmId)).pipe(
    Effect.catchAll((err) =>
      Effect.sync(() => {
        console.error(`[vm] model-plane revoke failed for ${cloudVmId}`, errorMessage(err));
      })
    ),
  );
}

export function openBaseVm(input: {
  readonly userId: string;
  readonly billingCustomerType: BillingCustomerType;
  readonly billingTeamId: string;
  readonly billingPlanId: string;
  readonly maxActiveVms: number | null;
  readonly provider: ProviderId;
  readonly image: string;
  readonly imageVersion?: string | null;
  readonly baseName?: string;
  readonly timing?: VmTimingSink;
}): Effect.Effect<BaseVmEntry, VmWorkflowError, VmRepository | VmProviderGateway | VmBillingGateway> {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const billing = yield* VmBillingGateway;
    const beginInput = isPaidVmPlan(input.billingPlanId)
      ? {
        ...input,
        resourceReservation: vmResourceReservationForCreate(),
      }
      : input;
    const create = yield* measureVmEffect(
      input.timing,
      "begin_base_open",
      repo.beginBaseOpen(beginInput),
    );
    return yield* finishBaseCreate(repo, providers, billing, input, create);
  });
}

export function resetBaseVm(input: {
  readonly userId: string;
  readonly billingCustomerType: BillingCustomerType;
  readonly billingTeamId: string;
  readonly billingPlanId: string;
  readonly maxActiveVms: number | null;
  readonly provider: ProviderId;
  readonly image: string;
  readonly imageVersion?: string | null;
  readonly baseName?: string;
  readonly reason?: string | null;
  readonly timing?: VmTimingSink;
}): Effect.Effect<BaseVmEntry, VmWorkflowError, VmRepository | VmProviderGateway | VmBillingGateway> {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const billing = yield* VmBillingGateway;
    const beginInput = isPaidVmPlan(input.billingPlanId)
      ? {
        ...input,
        resourceReservation: vmResourceReservationForCreate(),
      }
      : input;
    const create = yield* measureVmEffect(
      input.timing,
      "begin_base_reset",
      repo.beginBaseReset(beginInput),
    );
    return yield* finishBaseCreate(repo, providers, billing, input, create);
  });
}

function finishBaseCreate(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  billing: VmBillingGatewayShape,
  input: {
    readonly userId: string;
    readonly billingCustomerType: BillingCustomerType;
    readonly billingTeamId: string;
    readonly billingPlanId: string;
    readonly maxActiveVms: number | null;
    readonly provider: ProviderId;
    readonly image: string;
    readonly imageVersion?: string | null;
    readonly baseName?: string;
      readonly timing?: VmTimingSink;
  },
  create: BeginBaseCreateResult,
): Effect.Effect<BaseVmEntry, VmWorkflowError, never> {
  return Effect.gen(function* () {
    if (create.kind === "existing") {
      const existing = create.vm;
      if (existing.status === "failed") {
        return yield* Effect.fail(
          new VmCreateFailedError({
            idempotencyKey: existing.idempotencyKey ?? "",
            code: existing.failureCode ?? null,
            message: existing.failureMessage ?? "previous Base create failed",
          }),
        );
      }
      if (!existing.providerVmId) {
        return yield* Effect.fail(
          new VmCreateInProgressError({ idempotencyKey: existing.idempotencyKey ?? "" }),
        );
      }
      const replacement = yield* reopenBaseIfProviderDeleted(
        repo,
        providers,
        input,
        create,
        existing,
        existing.providerVmId,
      );
      if (replacement) {
        return yield* finishBaseCreate(repo, providers, billing, input, replacement);
      }
      return baseVmEntryFromRows(create.base, create.generation, existing, null);
    }

    const idempotencyKey = create.vm.idempotencyKey ?? undefined;
    const creditReservation = yield* reserveCreateCredit(billing, repo, {
      ...input,
      idempotencyKey,
    }, create.vm);
    yield* recordCreateRequestedEvents(repo, {
      ...input,
      idempotencyKey,
    }, create.vm, creditReservation);

    // Base machines join the owner's private network exactly as ad-hoc
    // machines do — Base is the machine most users touch first, so leaving it
    // publicly exposed would make the default machine the least private one.
    // finishBaseCreate receives its services as parameters (it predates the
    // context-based composition), so hand them to the context-reading resolver
    // explicitly instead of widening this function's environment.
    const network = yield* measureVmEffect(
      input.timing,
      "resolve_network",
      resolveOwnerNetwork({ userId: input.userId, provider: input.provider }).pipe(
        Effect.provideService(VmRepository, repo),
        Effect.provideService(VmProviderGateway, providers),
      ),
    );

    const handle = yield* measureVmEffect(
      input.timing,
      "provider_create",
      providers.create(input.provider, {
        image: input.image,
        displayName: create.vm.slug ?? undefined,
        providerMetadata: create.vm.providerMetadata,
        network: { id: network.providerNetworkId },
      }),
    ).pipe(
      Effect.tapError((err) =>
        Effect.all([
          refundCredit(billing, repo, create.vm, creditReservation),
          repo.markBaseCreateFailed({
            baseId: create.base.id,
            generation: create.generation.generation,
            vmId: create.vm.id,
            userId: input.userId,
            code: err.operation,
            message: errorMessage(err.cause),
          }),
          repo.recordUsageEvent({
            userId: input.userId,
            billingTeamId: input.billingTeamId,
            billingPlanId: input.billingPlanId,
            vmId: create.vm.id,
            eventType: "vm.base.create.failed",
            provider: input.provider,
            imageId: input.image,
            metadata: { operation: err.operation, message: errorMessage(err.cause), baseName: input.baseName ?? "base" },
          }),
        ], { discard: true }).pipe(Effect.catchAll(() => Effect.void))
      ),
    );

    const running = yield* measureVmEffect(
      input.timing,
      "mark_base_running",
      repo.markBaseCreateRunning({
        baseId: create.base.id,
        generation: create.generation.generation,
        vmId: create.vm.id,
        providerVmId: handle.providerVmId,
        image: handle.image,
        imageVersion: input.imageVersion ?? null,
        providerMetadata: handle.providerMetadata ?? create.vm.providerMetadata,
        userId: input.userId,
      }),
    ).pipe(
      Effect.catchAll((err) =>
        Effect.gen(function* () {
          yield* rollbackProviderCreate(providers, input.provider, handle);
          yield* refundCredit(billing, repo, create.vm, creditReservation);
          yield* repo.markBaseCreateFailed({
            baseId: create.base.id,
            generation: create.generation.generation,
            vmId: create.vm.id,
            userId: input.userId,
            code: "database_finalize_failed",
            message: "Cloud VM Base state update failed.",
          }).pipe(Effect.catchAll(() => Effect.void));
          yield* recordCreateFailureEvent(
            repo,
            {
              userId: input.userId,
              billingTeamId: input.billingTeamId,
              billingPlanId: input.billingPlanId,
              provider: input.provider,
              image: input.image,
            },
            create.vm,
            "database_finalize_failed",
            errorMessage(err.cause),
          ).pipe(Effect.catchAll(() => Effect.void));
          return yield* Effect.fail(err);
        }),
      ),
    );

    yield* recordCreateSuccessEvents(repo, { ...input, idempotencyKey, origin: "base" }, running);
    yield* repo.recordUsageEvent({
      userId: input.userId,
      billingTeamId: input.billingTeamId,
      billingPlanId: input.billingPlanId,
      vmId: running.id,
      eventType: create.previousVm ? "vm.base.reset" : "vm.base.opened",
      provider: input.provider,
      imageId: input.image,
      metadata: {
        baseName: input.baseName ?? "base",
        generation: create.generation.generation,
        retainedProviderVmId: create.previousVm?.providerVmId ?? null,
      },
    }).pipe(Effect.catchAll(() => Effect.void));

    return baseVmEntryFromRows(
      create.base,
      create.generation,
      running,
      create.previousVm?.providerVmId ?? null,
    );
  });
}

function reopenBaseIfProviderDeleted(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  input: Parameters<VmRepositoryShape["beginBaseOpen"]>[0] & { readonly timing?: VmTimingSink },
  create: Extract<BeginBaseCreateResult, { readonly kind: "existing" }>,
  existing: CloudVmRow,
  providerVmId: string,
): Effect.Effect<BeginBaseCreateResult | null, VmWorkflowError, never> {
  const getStatus = providers.getStatus;
  if (!getStatus) return Effect.succeed(null);
  return getStatus(existing.provider, providerVmId).pipe(
    Effect.as(null),
    Effect.catchAll((err) =>
      isProviderNotFoundError(err)
        ? Effect.gen(function* () {
          const markedDestroyed = yield* repo.markProviderObservedStatus({
            id: existing.id,
            providerVmId,
            status: "destroyed",
          });
          if (!markedDestroyed) {
            return yield* Effect.fail(new VmNotFoundError({ vmId: providerVmId }));
          }
          yield* repo.recordUsageEvent({
            userId: existing.userId,
            billingTeamId: existing.billingTeamId,
            billingPlanId: existing.billingPlanId,
            vmId: existing.id,
            eventType: "vm.destroyed",
            provider: existing.provider,
            imageId: existing.imageId,
            vmCreatedAt: existing.createdAt,
            metadata: {
              source: "base_open_provider_missing",
              baseName: input.baseName ?? "base",
              generation: create.generation.generation,
            },
          }).pipe(Effect.catchAll(() => Effect.void));
          return yield* measureVmEffect(
            input.timing,
            "begin_base_open",
            Effect.suspend(() => repo.beginBaseOpen(
              isPaidVmPlan(input.billingPlanId)
                ? {
                  ...input,
                  resourceReservation: vmResourceReservationForCreate(),
                }
                : input,
            )),
          );
        })
        : Effect.succeed(null)
    ),
  );
}

export function snapshotVm(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
  readonly name?: string;
}) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const vm = yield* requireUserVm(input);
    const snapshot = yield* (providers.snapshot
      ? providers.snapshot(vm.provider, vm.providerVmId ?? input.providerVmId, input.name)
      : Effect.fail(new VmOperationUnsupportedError({
        provider: vm.provider,
        operation: "snapshot",
      })));
    // Read after the provider confirms the snapshot. Grow-only resizes that
    // finish during snapshot creation are then included in the captured claim;
    // a later resize can only make this conservative.
    const snapshotStats = providers.getStats
      ? yield* providers.getStats(vm.provider, vm.providerVmId ?? input.providerVmId).pipe(
        Effect.timeoutFail({
          duration: FOREGROUND_PROVIDER_STATS_TIMEOUT,
          onTimeout: () => new Error(`snapshot stats timed out for ${vm.providerVmId ?? input.providerVmId}`),
        }),
        Effect.map((stats) => ({
          vcpus: vmProviderResourceSize("vcpus", stats.cpus),
          memoryMb: vmProviderResourceSize("memoryMb", stats.memoryTotalMb),
          diskMb: vmProviderResourceSize("diskMb", stats.diskTotalMb),
        })),
        Effect.catchAll(() => Effect.succeed(null)),
      )
      : null;
    const snapshotReservation = snapshotResourceReservation(vm.providerMetadata, snapshotStats);
    yield* repo.recordUsageEvent({
      userId: vm.userId,
      billingTeamId: vm.billingTeamId,
      billingPlanId: vm.billingPlanId,
      vmId: vm.id,
      eventType: "vm.snapshot.created",
      provider: vm.provider,
      imageId: vm.imageId,
      metadata: {
        snapshotId: snapshot.id,
        named: !!input.name,
        name: input.name ?? null,
        // Persist the complete source claim with the snapshot event. Restores
        // can then reserve the captured shape after the source VM is gone or
        // grows. Unknown dimensions already use a fail-closed pool claim.
        vcpus: snapshotReservation.vcpus,
        memoryMb: snapshotReservation.memoryMb,
        diskMb: snapshotReservation.diskMb,
      },
    });
    return snapshot;
  });
}

type SnapshotProviderResources = {
  readonly vcpus: number | null;
  readonly memoryMb: number | null;
  readonly diskMb: number | null;
};

/**
 * Preserve a durable reservation as a floor, while repairing legacy snapshots
 * from provider-confirmed dimensions and failing closed for missing fields.
 */
function snapshotResourceReservation(
  providerMetadata: Record<string, unknown> | null | undefined,
  providerResources: SnapshotProviderResources | null,
): VmResourceReservation {
  const sourceReservation = vmResourceReservationFromMetadata(providerMetadata);
  if (!hasVmResourceReservationMetadata(providerMetadata)) {
    return {
      vcpus: providerResources?.vcpus ?? DEFAULT_VM_RESOURCE_RESERVATION.vcpus,
      memoryMb: providerResources?.memoryMb ?? DEFAULT_VM_RESOURCE_RESERVATION.memoryMb,
      diskMb: providerResources?.diskMb ?? VM_DISK_MB_MAX,
    };
  }
  return {
    vcpus: Math.max(sourceReservation.vcpus, providerResources?.vcpus ?? sourceReservation.vcpus),
    memoryMb: Math.max(sourceReservation.memoryMb, providerResources?.memoryMb ?? sourceReservation.memoryMb),
    diskMb: Math.max(sourceReservation.diskMb, providerResources?.diskMb ?? sourceReservation.diskMb),
  };
}

/** Include the provider's grow-only create target in a captured snapshot claim. */
function restoreResourceReservation(
  snapshotReservation: VmResourceReservation,
): VmResourceReservation {
  const createTarget = vmResourceReservationForCreate({
    memoryMb: snapshotReservation.memoryMb,
  });
  return {
    vcpus: Math.max(snapshotReservation.vcpus, createTarget.vcpus),
    memoryMb: Math.max(snapshotReservation.memoryMb, createTarget.memoryMb),
    diskMb: Math.max(snapshotReservation.diskMb, createTarget.diskMb),
  };
}

export function restoreVm(input: {
  readonly userId: string;
  readonly billingCustomerType: BillingCustomerType;
  readonly billingTeamId: string;
  readonly billingPlanId: string;
  readonly maxActiveVms: number | null;
  readonly provider: ProviderId;
  readonly snapshotId: string;
  readonly idempotencyKey?: string;
  /** Same contract as createVm: the restored machine gets its own token and edge rule. */
  readonly modelPlane?: VmModelPlaneProvisioner;
  readonly timing?: VmTimingSink;
}) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const hasSnapshot = yield* repo.hasOwnedSnapshot({
      userId: input.userId,
      billingTeamId: input.billingTeamId,
      provider: input.provider,
      snapshotId: input.snapshotId,
    });
    if (!hasSnapshot) {
      return yield* Effect.fail(new VmSnapshotNotFoundError({ snapshotId: input.snapshotId }));
    }
    let snapshotReservation: VmResourceReservation | null = null;
    if (isPaidVmPlan(input.billingPlanId) && repo.ownedSnapshotResourceReservation) {
      snapshotReservation = yield* repo.ownedSnapshotResourceReservation({
        userId: input.userId,
        billingTeamId: input.billingTeamId,
        provider: input.provider,
        snapshotId: input.snapshotId,
      });
    }
    const resourceReservation = isPaidVmPlan(input.billingPlanId)
      ? restoreResourceReservation(snapshotReservation ?? {
        ...DEFAULT_VM_RESOURCE_RESERVATION,
        // A snapshot event written before resource metadata existed has no
        // trustworthy shape. Claim the historical machine shape and maximum disk size.
        diskMb: VM_DISK_MB_MAX,
      })
      : undefined;
    return yield* createVm({
      userId: input.userId,
      billingCustomerType: input.billingCustomerType,
      billingTeamId: input.billingTeamId,
      billingPlanId: input.billingPlanId,
      maxActiveVms: input.maxActiveVms,
      provider: input.provider,
      image: input.snapshotId,
      imageVersion: null,
      ...(resourceReservation ? { memoryMb: resourceReservation.memoryMb } : {}),
      idempotencyKey: input.idempotencyKey,
      origin: "restore",
      ...(resourceReservation ? { resourceReservation } : {}),
      modelPlane: input.modelPlane,
      timing: input.timing,
    });
  });
}

/**
 * Resolve the source shape used by a fork. Legacy rows have no durable claim,
 * so forks use provider stats with a legacy fallback for unknown dimensions.
 */
function resourceReservationForFork(
  providers: VmProviderGatewayShape,
  source: CloudVmRow,
  providerVmId: string,
  billingPlanId: string,
): Effect.Effect<VmResourceReservation, VmWorkflowError, never> {
  const reservation = vmResourceReservationFromMetadata(source.providerMetadata);
  if (!isPaidVmPlan(billingPlanId) || hasVmResourceReservationMetadata(source.providerMetadata)) {
    return Effect.succeed(reservation);
  }

  // Unknown legacy dimensions claim the historical machine shape. This keeps the
  // fallback compatible with legacy machines until provider stats arrive.
  const unknownShape = {
    vcpus: DEFAULT_VM_RESOURCE_RESERVATION.vcpus,
    memoryMb: DEFAULT_VM_RESOURCE_RESERVATION.memoryMb,
    diskMb: VM_DISK_MB_MAX,
  } satisfies VmResourceReservation;
  if (!providers.getStats) return Effect.succeed(unknownShape);
  return providers.getStats(source.provider, source.providerVmId ?? providerVmId).pipe(
    Effect.timeoutFail({
      duration: FOREGROUND_PROVIDER_STATS_TIMEOUT,
      onTimeout: () => new Error(`fork source stats timed out for ${source.providerVmId ?? providerVmId}`),
    }),
    Effect.map((stats) => {
      return {
        vcpus: vmProviderResourceSize("vcpus", stats.cpus) ?? unknownShape.vcpus,
        memoryMb: vmProviderResourceSize("memoryMb", stats.memoryTotalMb) ?? unknownShape.memoryMb,
        diskMb: vmProviderResourceSize("diskMb", stats.diskTotalMb) ?? unknownShape.diskMb,
      } satisfies VmResourceReservation;
    }),
    Effect.catchAll(() => Effect.succeed(unknownShape)),
  );
}

function reservationFromProviderStats(
  stats: { readonly cpus?: unknown; readonly memoryTotalMb?: unknown; readonly diskTotalMb?: unknown },
  fallback: VmResourceReservation,
  minimum: VmResourceReservation = fallback,
): VmResourceReservation {
  return {
    vcpus: Math.max(minimum.vcpus, vmProviderResourceSize("vcpus", stats.cpus) ?? fallback.vcpus),
    memoryMb: Math.max(minimum.memoryMb, vmProviderResourceSize("memoryMb", stats.memoryTotalMb) ?? fallback.memoryMb),
    diskMb: Math.max(minimum.diskMb, vmProviderResourceSize("diskMb", stats.diskTotalMb) ?? fallback.diskMb),
  };
}

/** Record a native fork's measured shape and clear its pending marker. */
function finalizeNativeForkReservation(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  input: {
    readonly vm: CloudVmRow;
    readonly providerVmId: string;
    readonly fallbackReservation: VmResourceReservation;
    readonly minimumReservation: VmResourceReservation;
  },
): Effect.Effect<void, VmWorkflowError, never> {
  const setReservation = repo.setResourceReservation;
  const getStats = providers.getStats;
  if (!setReservation || !getStats) return Effect.void;
  // Compare against the stored shape so a stale stats read cannot overwrite
  // a newer resize or reconciliation result.
  const expectedReservation = vmResourceReservationFromMetadata(
    input.vm.providerMetadata,
    input.fallbackReservation,
  );
  return getStats(input.vm.provider, input.providerVmId).pipe(
    Effect.timeoutFail({
      duration: FOREGROUND_PROVIDER_STATS_TIMEOUT,
      onTimeout: () => new Error(`fork copy stats timed out for ${input.providerVmId}`),
    }),
    Effect.map((stats) => reservationFromProviderStats(
      stats,
      input.fallbackReservation,
      input.minimumReservation,
    )),
    // A successful provider fork is still usable when its first stats read is
    // unavailable. Keep the temporary claim and let the bounded reconciler
    // replace it later; never release capacity on an unconfirmed shape.
    Effect.catchAll(() => Effect.succeed(null)),
    Effect.flatMap((reservation) => {
      if (!reservation) return Effect.void;
      return setReservation({
        id: input.vm.id,
        expectedReservation,
        reservation,
      }).pipe(
        Effect.flatMap((replaced) => replaced
          ? Effect.void
          : Effect.fail(new VmDatabaseError({
            operation: "replaceForkResourceReservation",
            cause: new Error("fork reservation generation changed before finalization"),
          }))),
      );
    }),
  );
}

export function forkVm(input: {
  readonly userId: string;
  readonly billingCustomerType: BillingCustomerType;
  readonly billingTeamId: string;
  readonly teamIds?: readonly string[];
  readonly billingPlanId: string;
  readonly maxActiveVms: number | null;
  readonly providerVmId: string;
  readonly name?: string;
  readonly idempotencyKey?: string;
  readonly timing?: VmTimingSink;
}) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const billing = yield* VmBillingGateway;
    const source = yield* requireUserVm(input);
    // Kill-switch parity with POST /api/vm: fork provisions a brand-new
    // machine on the source VM's provider and spends the same provider money.
    // The check lives here rather than in the route because the provider is
    // only known once the source VM row is loaded.
    const createDisabledReason = vmCreateDisabledReason(source.provider);
    if (createDisabledReason) {
      return yield* Effect.fail(new VmCreateDisabledError({
        provider: source.provider,
        reason: createDisabledReason,
      }));
    }
    yield* preflightResumeIfSuspended(
      repo,
      providers,
      source,
      input.providerVmId,
      "fork",
      { forceProviderProbe: true, maxActiveVms: input.maxActiveVms },
    );

    const nativeFork = source.provider === "freestyle" && providers.fork !== undefined;
    // The provider owns cloning the source. Record its initial shape and
    // reconcile the copied machine independently after the fork completes.
    const sourceHasReservation = hasVmResourceReservationMetadata(source.providerMetadata);
    const nativeForkReservation = isPaidVmPlan(input.billingPlanId)
      ? sourceHasReservation
        ? vmResourceReservationFromMetadata(source.providerMetadata)
        : {
          vcpus: DEFAULT_VM_RESOURCE_RESERVATION.vcpus,
          memoryMb: DEFAULT_VM_RESOURCE_RESERVATION.memoryMb,
          diskMb: VM_DISK_MB_MAX,
        }
      : undefined;

    if (nativeFork) {
      const sourceReservation = nativeForkReservation ?? DEFAULT_VM_RESOURCE_RESERVATION;
      const create = yield* beginCreateWithLazyProviderRefresh(repo, providers, {
        userId: input.userId,
        billingTeamId: input.billingTeamId,
        provider: source.provider,
        image: source.imageId,
        imageVersion: source.imageVersion,
        maxActiveVms: input.maxActiveVms,
        ...(isPaidVmPlan(input.billingPlanId)
          ? {
            resourceReservation: sourceReservation,
            forkPending: true,
            forkMinimumResourceReservation: sourceHasReservation
              ? sourceReservation
              : { vcpus: 1, memoryMb: 4 * 1024, diskMb: 16 * 1024 },
          }
          : {}),
        billingPlanId: input.billingPlanId,
        idempotencyKey: input.idempotencyKey,
        timing: input.timing,
      });

      if (!create.inserted) {
        const existing = create.vm;
        if (existing.status === "failed") {
          return yield* Effect.fail(
            new VmCreateFailedError({
              idempotencyKey: input.idempotencyKey ?? "",
              code: existing.failureCode ?? null,
              message: existing.failureMessage ?? "previous VM fork failed",
            }),
          );
        }
        if (!existing.providerVmId) {
          return yield* Effect.fail(
            new VmCreateInProgressError({ idempotencyKey: input.idempotencyKey ?? "" }),
          );
        }
        return { snapshot: null, fork: vmEntryFromRow(existing) };
      }

      const creditReservation = yield* reserveCreateCredit(billing, repo, {
        userId: input.userId,
        billingCustomerType: input.billingCustomerType,
        billingTeamId: input.billingTeamId,
        billingPlanId: input.billingPlanId,
        provider: source.provider,
        image: source.imageId,
        imageVersion: source.imageVersion,
        idempotencyKey: input.idempotencyKey,
        timing: input.timing,
      }, create.vm);
      yield* recordCreateRequestedEvents(repo, {
        userId: input.userId,
        billingTeamId: input.billingTeamId,
        billingPlanId: input.billingPlanId,
        provider: source.provider,
        image: source.imageId,
        imageVersion: source.imageVersion,
        idempotencyKey: input.idempotencyKey,
        timing: input.timing,
      }, create.vm, creditReservation);

      const handle = yield* measureVmEffect(
        input.timing,
        "provider_create",
        providers.fork(source.provider, source.providerVmId ?? input.providerVmId),
      ).pipe(
        Effect.tapError((err) =>
          Effect.all([
            refundCredit(billing, repo, create.vm, creditReservation),
            repo.markCreateFailed({
              id: create.vm.id,
              code: err.operation,
              message: errorMessage(err.cause),
            }),
            repo.recordUsageEvent({
              userId: input.userId,
              billingTeamId: input.billingTeamId,
              billingPlanId: input.billingPlanId,
              vmId: create.vm.id,
              eventType: "vm.create.failed",
              provider: source.provider,
              imageId: source.imageId,
              metadata: { operation: err.operation, message: errorMessage(err.cause), sourceProviderVmId: source.providerVmId },
            }),
          ], { discard: true }).pipe(Effect.catchAll(() => Effect.void))
        ),
      );

      const running = yield* Effect.gen(function* () {
        if (isPaidVmPlan(input.billingPlanId)) {
          yield* finalizeNativeForkReservation(repo, providers, {
            vm: create.vm,
            providerVmId: handle.providerVmId,
            fallbackReservation: sourceReservation,
            minimumReservation: sourceHasReservation
              ? sourceReservation
              : { vcpus: 1, memoryMb: 4 * 1024, diskMb: 16 * 1024 },
          });
        }
        return yield* measureVmEffect(
          input.timing,
          "mark_running",
          repo.markCreateRunning({
            id: create.vm.id,
            providerVmId: handle.providerVmId,
            image: source.imageId,
            imageVersion: source.imageVersion,
            providerMetadata: handle.providerMetadata ?? source.providerMetadata,
          }),
        );
      }).pipe(
        Effect.catchAll((err) =>
          Effect.gen(function* () {
            yield* rollbackProviderCreate(providers, source.provider, handle);
            yield* refundCredit(billing, repo, create.vm, creditReservation);
            yield* repo.markCreateFailed({
              id: create.vm.id,
              code: "database_finalize_failed",
              message: "Cloud VM fork state update failed.",
            }).pipe(Effect.catchAll(() => Effect.void));
            yield* recordCreateFailureEvent(
              repo,
              {
                userId: input.userId,
                billingTeamId: input.billingTeamId,
                billingPlanId: input.billingPlanId,
                provider: source.provider,
                image: source.imageId,
              },
              create.vm,
              "database_finalize_failed",
              errorMessage(err.cause),
            ).pipe(Effect.catchAll(() => Effect.void));
            return yield* Effect.fail(err);
          }),
        ),
      );

      yield* recordCreateSuccessEvents(repo, { ...input, origin: "fork" }, running);
      const fork = vmEntryFromRow(running);
      yield* repo.recordUsageEvent({
        userId: source.userId,
        billingTeamId: source.billingTeamId,
        billingPlanId: source.billingPlanId,
        vmId: source.id,
        eventType: "vm.forked",
        provider: source.provider,
        imageId: source.imageId,
        metadata: {
          native: true,
          sourceProviderVmId: source.providerVmId,
          forkProviderVmId: fork.providerVmId,
          idempotencyKeySet: !!input.idempotencyKey,
        },
      }).pipe(Effect.catchAll(() => Effect.void));
      return { snapshot: null, fork };
    }

    const snapshot = yield* snapshotVm({
      userId: input.userId,
      teamIds: input.teamIds,
      billingTeamId: source.billingTeamId,
      providerVmId: input.providerVmId,
      name: input.name,
    });
    // Snapshotting establishes the copy point for providers without a native
    // fork. Read the source shape after that point so a concurrent grow cannot
    // understate the copied machine's claim.
    const sourceReservation = isPaidVmPlan(input.billingPlanId)
      ? yield* resourceReservationForFork(providers, source, input.providerVmId, input.billingPlanId)
      : undefined;
    const fork = yield* createVm({
      userId: input.userId,
      billingCustomerType: input.billingCustomerType,
      billingTeamId: input.billingTeamId,
      billingPlanId: input.billingPlanId,
      maxActiveVms: input.maxActiveVms,
      provider: source.provider,
      image: snapshot.id,
      imageVersion: null,
      ...(sourceReservation ? { resourceReservation: sourceReservation } : {}),
      idempotencyKey: input.idempotencyKey,
      origin: "fork",
      timing: input.timing,
    });
    yield* repo.recordUsageEvent({
      userId: source.userId,
      billingTeamId: source.billingTeamId,
      billingPlanId: source.billingPlanId,
      vmId: source.id,
      eventType: "vm.forked",
      provider: source.provider,
      imageId: source.imageId,
      metadata: {
        snapshotId: snapshot.id,
        forkProviderVmId: fork.providerVmId,
        idempotencyKeySet: !!input.idempotencyKey,
      },
    }).pipe(Effect.catchAll(() => Effect.void));
    return { snapshot, fork };
  });
}

function beginCreateWithLazyProviderRefresh(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  input: {
    readonly userId: string;
    readonly billingTeamId: string;
    readonly modelPlane?: VmModelPlaneRevoker;
    readonly timing?: VmTimingSink;
  } & Parameters<VmRepositoryShape["beginCreate"]>[0],
): Effect.Effect<BeginCreateResult, VmWorkflowError, never> {
  // Refresh provider statuses only when the machine-count allowance is full.
  const beginCreate = Effect.suspend(() =>
    measureVmEffect(input.timing, "begin_create", repo.beginCreate(input))
  );
  return beginCreate.pipe(
    Effect.catchAll((err) => {
      if (!isVmLimitExceededError(err)) return Effect.fail(err);
      const reconcile = refreshActiveLimitProviderStatuses(repo, providers, input);
      return measureVmEffect(
        input.timing,
        "limit_reconcile",
        reconcile,
      ).pipe(
        Effect.catchAll(() => Effect.void),
        Effect.andThen(beginCreate),
      );
    }),
  );
}

/** Backfill legacy claims in a bounded background batch. */
function reconcileLegacyResourceReservations(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  input: {
    readonly userId?: string;
    readonly billingTeamId?: string | null;
    readonly limit?: number;
  },
): Effect.Effect<void, never> {
  const findCandidates = repo.legacyResourceReservationCandidates;
  if (!findCandidates || !repo.setResourceReservation || !providers.getStats) return Effect.void;

  return Effect.gen(function*() {
    const candidates = yield* findCandidates({
      userId: input.userId,
      billingTeamId: input.billingTeamId,
      limit: input.limit ?? LEGACY_RESOURCE_RECONCILE_BATCH_LIMIT,
    }).pipe(Effect.catchAll(() => Effect.succeed([])));
    yield* Effect.forEach(
      candidates,
      (vm) => reconcileLegacyResourceCandidate(repo, providers, vm),
      { concurrency: LEGACY_RESOURCE_RECONCILE_CONCURRENCY, discard: true },
    );
  });
}

/** Defer one candidate with durable backoff when the provider cannot be read. */
function deferLegacyResourceCandidate(
  repo: VmRepositoryShape,
  vm: CloudVmRow,
  requestedAttemptAtMs?: number,
): Effect.Effect<void, never> {
  const defer = repo.deferResourceReservation;
  if (!defer) return Effect.void;
  const nowMs = Date.now();
  const nextAttemptAtMs = Math.max(
    nowMs + LEGACY_RESOURCE_RECONCILE_RETRY_AFTER_MS,
    requestedAttemptAtMs ?? 0,
  );
  return defer({
    id: vm.id,
    nextAttemptAt: new Date(nextAttemptAtMs),
  }).pipe(Effect.catchAll(() => Effect.void));
}

type ResourceReservationWriter = NonNullable<VmRepositoryShape["setResourceReservation"]>;
type ResizeUnconfirmedWriter = NonNullable<VmRepositoryShape["markVmResizeUnconfirmed"]>;

function reservationFromLegacyProviderStats(
  stats: VMStats,
  existing: VmResourceReservation,
  diskMb: number,
  minimumDiskMb: number,
): VmResourceReservation {
  return {
    ...existing,
    vcpus: vmProviderResourceSize("vcpus", stats.cpus) ?? existing.vcpus,
    memoryMb: vmProviderResourceSize("memoryMb", stats.memoryTotalMb) ?? existing.memoryMb,
    diskMb: Math.max(minimumDiskMb, diskMb),
  };
}

function reconcilePendingForkReservation(input: {
  readonly setReservation: ResourceReservationWriter;
  readonly vmId: string;
  readonly stats: VMStats;
  readonly existing: VmResourceReservation;
  readonly minimum: VmResourceReservation;
  readonly diskMb: number;
}) {
  // Replace valid dimensions with the measured copy, retaining the source
  // shape as a floor and the last known value for missing provider dimensions.
  const observedVcpus = vmProviderResourceSize("vcpus", input.stats.cpus);
  const observedMemoryMb = vmProviderResourceSize("memoryMb", input.stats.memoryTotalMb);
  const reservation = {
    vcpus: observedVcpus === null
      ? input.existing.vcpus
      : Math.max(input.minimum.vcpus, observedVcpus),
    memoryMb: observedMemoryMb === null
      ? input.existing.memoryMb
      : Math.max(input.minimum.memoryMb, observedMemoryMb),
    diskMb: Math.max(input.minimum.diskMb, input.diskMb),
  };
  return input.setReservation({
    id: input.vmId,
    reservation,
    expectedReservation: input.existing,
  }).pipe(Effect.asVoid);
}

function recoverIncompletePendingResize(input: {
  readonly repo: VmRepositoryShape;
  readonly markUnconfirmed: ResizeUnconfirmedWriter | undefined;
  readonly vm: CloudVmRow;
  readonly existing: VmResourceReservation;
  readonly pending: VmResourceResizePending;
}) {
  // A worker can die after recording a pending resize but before provider I/O. After
  // the recovery window, retain a maximum claim until stats prove that the
  // requested size exists.
  if (!input.markUnconfirmed || !resizePendingHasExpired(input.pending)) {
    return deferLegacyResourceCandidate(input.repo, input.vm);
  }
  return input.markUnconfirmed({
    id: input.vm.id,
    expectedDiskMb: input.existing.diskMb,
    minimumDiskMb: input.pending.requestedDiskMb,
    previousDiskMb: input.pending.previousDiskMb,
    operationId: input.pending.operationId,
  }).pipe(
    Effect.asVoid,
    Effect.catchAll(() => deferLegacyResourceCandidate(input.repo, input.vm)),
  );
}

function reconcileUnconfirmedResize(input: {
  readonly repo: VmRepositoryShape;
  readonly setReservation: ResourceReservationWriter;
  readonly vm: CloudVmRow;
  readonly stats: VMStats;
  readonly existing: VmResourceReservation;
  readonly unconfirmed: VmResourceResizeUnconfirmed;
  readonly diskMb: number;
}) {
  // Keep the maximum claim while the provider reports a stale size. Clearing
  // the marker before the requested size is observed would undercount the pool.
  if (input.diskMb < input.unconfirmed.requestedDiskMb) {
    if (!unconfirmedResizeRecoveryHasExpired(input.vm, input.unconfirmed)) {
      return deferLegacyResourceCandidate(input.repo, input.vm);
    }
    // The provider stayed below the requested size for the complete recovery
    // window. Assume the resize never applied and release the temporary claim.
    const reservation = reservationFromLegacyProviderStats(
      input.stats,
      input.existing,
      input.diskMb,
      Math.max(
        DEFAULT_VM_RESOURCE_RESERVATION.diskMb,
        input.unconfirmed.previousDiskMb ?? 0,
      ),
    );
    return input.setReservation({
      id: input.vm.id,
      reservation,
      expectedResizeUnconfirmedOperationId: input.unconfirmed.operationId,
    }).pipe(Effect.asVoid);
  }
  const reservation = reservationFromLegacyProviderStats(
    input.stats,
    input.existing,
    input.diskMb,
    input.unconfirmed.requestedDiskMb,
  );
  return input.setReservation({
    id: input.vm.id,
    reservation,
    expectedResizeUnconfirmedOperationId: input.unconfirmed.operationId,
  }).pipe(Effect.asVoid);
}

function reconcileMeasuredLegacyReservation(input: {
  readonly setReservation: ResourceReservationWriter;
  readonly vmId: string;
  readonly stats: VMStats;
  readonly existing: VmResourceReservation;
  readonly pending: VmResourceResizePending | null;
  readonly diskMb: number;
}) {
  const minimumDiskMb = input.pending?.requestedDiskMb ?? DEFAULT_VM_RESOURCE_RESERVATION.diskMb;
  const reservation = reservationFromLegacyProviderStats(
    input.stats,
    input.existing,
    input.diskMb,
    minimumDiskMb,
  );
  return input.setReservation({
    id: input.vmId,
    reservation,
    ...(input.pending ? { expectedResizeOperationId: input.pending.operationId } : {}),
  }).pipe(Effect.asVoid);
}

/** Reconcile one legacy row, keeping provider work outside the request path. */
function reconcileLegacyResourceCandidate(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  vm: CloudVmRow,
): Effect.Effect<void, never> {
  const setReservation = repo.setResourceReservation;
  const markUnconfirmed = repo.markVmResizeUnconfirmed;
  const getStats = providers.getStats;
  const providerVmId = vm.providerVmId;
  if (!providerVmId || !setReservation || !getStats) return Effect.void;

  const metadata = vm.providerMetadata ?? {};
  const hasPendingMarker = Object.prototype.hasOwnProperty.call(
    metadata,
    VM_RESOURCE_RESIZE_PENDING_METADATA_KEY,
  );
  const pending = vmResourceResizePendingFromMetadata(metadata);
  const hasUnconfirmedMarker = Object.prototype.hasOwnProperty.call(
    metadata,
    VM_RESOURCE_RESIZE_UNCONFIRMED_METADATA_KEY,
  );
  const unconfirmed = vmResourceResizeUnconfirmedFromMetadata(metadata);
  const hasForkPendingMarker = Object.prototype.hasOwnProperty.call(
    metadata,
    VM_RESOURCE_FORK_PENDING_METADATA_KEY,
  );
  const forkMinimumReservation = vmResourceForkPendingFromMetadata(metadata);
  const retry = vmResourceReconcileRetryFromMetadata(metadata);
  // The repository filters these rows in SQL. Keep this second boundary for
  // alternate adapters and stale replicas.
  if (retry && retry.nextAttemptAtMs > Date.now()) return Effect.void;
  // A malformed control marker has no safe generation to clear. Keep it and
  // retry later instead of releasing a newer claim by accident.
  if (hasPendingMarker && !pending || hasUnconfirmedMarker && !unconfirmed || hasForkPendingMarker && !forkMinimumReservation) {
    return deferLegacyResourceCandidate(repo, vm);
  }
  // A live pending resize still has an owner that can confirm it. Do not read
  // provider stats and clear the marker while that request may be in flight.
  if (pending && !resizePendingHasExpired(pending)) {
    const recoveryAtMs = pending.createdAtMs === undefined
      ? undefined
      : pending.createdAtMs + RESIZE_PENDING_RECOVERY_AFTER_MS;
    return deferLegacyResourceCandidate(repo, vm, recoveryAtMs);
  }

  const readStats = getStats(vm.provider, providerVmId).pipe(
    // A hung provider read must not hold the cron worker or starve later rows.
    Effect.timeoutFail({
      duration: LEGACY_RESOURCE_RECONCILE_PROVIDER_TIMEOUT,
      onTimeout: () => new Error(`legacy resource stats timed out for ${providerVmId}`),
    }),
  );
  return readStats.pipe(
    Effect.flatMap((stats) => {
      const diskMb = vmProviderResourceSize("diskMb", stats.diskTotalMb);
      if (diskMb === null) return deferLegacyResourceCandidate(repo, vm);
      const existing = vmResourceReservationFromMetadata(metadata);
      if (hasForkPendingMarker && forkMinimumReservation) {
        return reconcilePendingForkReservation({
          setReservation,
          vmId: vm.id,
          stats,
          existing,
          minimum: forkMinimumReservation,
          diskMb,
        });
      }
      if (pending && diskMb < pending.requestedDiskMb) {
        return recoverIncompletePendingResize({
          repo,
          markUnconfirmed,
          vm,
          existing,
          pending,
        });
      }
      if (unconfirmed) {
        return reconcileUnconfirmedResize({
          repo,
          setReservation,
          vm,
          stats,
          existing,
          unconfirmed,
          diskMb,
        });
      }
      return reconcileMeasuredLegacyReservation({
        setReservation,
        vmId: vm.id,
        stats,
        existing,
        pending,
        diskMb,
      });
    }),
    // An unavailable provider leaves the claim conservative and retries later.
    Effect.catchAll(() => deferLegacyResourceCandidate(repo, vm)),
  );
}

function resizePendingHasExpired(
  pending: VmResourceResizePending,
): boolean {
  // Old markers have no reliable start time. Treat them as recoverable so a
  // migration cannot remain blocked forever; new markers carry their own
  // generation timestamp and get the full recovery window.
  if (pending.createdAtMs === undefined) return true;
  const startedAtMs = pending.createdAtMs;
  return Date.now() - startedAtMs >= RESIZE_PENDING_RECOVERY_AFTER_MS;
}

function unconfirmedResizeRecoveryHasExpired(
  vm: Pick<CloudVmRow, "updatedAt">,
  unconfirmed: { readonly markedAtMs?: number },
): boolean {
  const markedAtMs = unconfirmed.markedAtMs ?? vm.updatedAt.getTime();
  return Date.now() - markedAtMs >= RESIZE_UNCONFIRMED_RECOVERY_AFTER_MS;
}

/** Refresh live provider state before retrying a count or shared-resource limit conflict. */
function refreshActiveLimitProviderStatuses(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  input: {
    readonly userId: string;
    readonly billingTeamId: string;
    readonly modelPlane?: VmModelPlaneRevoker;
    readonly limit?: number;
  },
): Effect.Effect<void, VmDatabaseError, never> {
  return Effect.gen(function* () {
    const getStatus = providers.getStatus;
    if (!getStatus || !repo.activeLimitCandidates) return;
    const limit = input.limit ?? VM_STATUS_RECONCILE_BATCH_LIMIT;

    const candidates = yield* repo.activeLimitCandidates({
      userId: input.userId,
      billingTeamId: input.billingTeamId,
      // Keep the synchronous retry bounded. If an account has more rows than
      // this, the database remains conservative until the background reconcile
      // catches up; we never create above the recorded active limit.
      limit,
    });
    // The repository applies the limit in SQL. Keep a second boundary here so
    // alternate repository implementations cannot turn this request path into
    // an unbounded provider sweep.
    yield* Effect.forEach(candidates.slice(0, limit), (vm) => {
      const providerVmId = vm.providerVmId;
      if (!providerVmId) return Effect.void;
      // Provider-agnostic on purpose: the cron reconcile path already refreshes
      // every provider, and this lazy refresh used to skip everything except
      // Freestyle, so a stale `running` row blocked creates for up to a
      // full cron interval. Candidates are `running` rows only, so the
      // gateway's "running" fallback for a driver without getStatus is a
      // harmless no-op rather than a wrong transition.
      return reconcileObservedProviderStatus(repo, getStatus, vm, "provider_status_refresh", input.modelPlane).pipe(
        Effect.asVoid,
      );
    }, { concurrency: 10, discard: true });
  });
}

function dbStatusFromProviderStatus(status: "running" | "paused" | "destroyed"): CloudVmStatus {
  return status;
}

// A provider 404 on a machine with a persistent home volume means the compute is gone but
// the machine is still resurrectable on the next attach — it is asleep, not destroyed.
// Only machines without a durable home actually die with their sandbox.
function observedDbStatus(
  vm: Pick<CloudVmRow, "providerMetadata">,
  providerStatus: "running" | "paused" | "destroyed",
): CloudVmStatus {
  if (providerStatus === "destroyed") {
    const homeVolume = vm.providerMetadata?.["homeVolume"];
    if (typeof homeVolume === "string" && homeVolume.length > 0) return "paused";
  }
  return dbStatusFromProviderStatus(providerStatus);
}

type ProviderStatusReconcileOutcome = "updated" | "destroyed" | "unchanged" | "skipped";

function reconcileObservedProviderStatus(
  repo: VmRepositoryShape,
  getStatus: NonNullable<VmProviderGatewayShape["getStatus"]>,
  vm: CloudVmRow,
  usageEventSource: string,
  modelPlane?: VmModelPlaneRevoker,
): Effect.Effect<ProviderStatusReconcileOutcome, never> {
  return Effect.gen(function* () {
    const providerVmId = vm.providerVmId;
    if (!providerVmId || isRetiredProviderRow(vm)) return "skipped" as const;
    const providerStatus = yield* getStatus(vm.provider, providerVmId).pipe(
      Effect.catchAll((err) =>
        isProviderNotFoundError(err)
          ? Effect.succeed("destroyed" as const)
          : Effect.succeed(null),
      ),
    );
    if (!providerStatus || providerStatus === "creating") return "skipped" as const;
    const dbStatus = observedDbStatus(vm, providerStatus);
    if (dbStatus === vm.status) return "unchanged" as const;
    const didUpdate = yield* repo.markProviderObservedStatus({
      id: vm.id,
      providerVmId,
      status: dbStatus,
    }).pipe(Effect.catchAll(() => Effect.succeed(false)));
    if (!didUpdate) return "skipped" as const;
    if (dbStatus === "destroyed") {
      yield* revokeModelPlane(modelPlane, vm.id);
      yield* repo.recordUsageEvent({
        userId: vm.userId,
        billingTeamId: vm.billingTeamId,
        billingPlanId: vm.billingPlanId,
        vmId: vm.id,
        eventType: "vm.destroyed",
        provider: vm.provider,
        imageId: vm.imageId,
        vmCreatedAt: vm.createdAt,
        metadata: { source: usageEventSource },
      }).pipe(Effect.catchAll(() => Effect.void));
      return "destroyed" as const;
    }
    return "updated" as const;
  });
}

function boundedVmStatusReconcileLimit(limit: number | undefined): number {
  if (limit === undefined || !Number.isFinite(limit)) return VM_STATUS_RECONCILE_BATCH_LIMIT;
  return Math.max(1, Math.min(VM_STATUS_RECONCILE_BATCH_LIMIT, Math.trunc(limit)));
}

const RESUME_STATUS_PROBE_TIMEOUT = "5 seconds";
const RESUME_SETTLE_ATTEMPTS = 10;
const RESUME_SETTLE_INTERVAL = "1 second";
type VmResumeSource = "exec" | "attach" | "ssh" | "fork" | "open_port" | "resize";

type ResumePreflightOptions = {
  /** Resolved billing-scope allowance; null is unlimited, undefined uses the plan default. */
  readonly maxActiveVms?: number | null;
  /**
   * Probe the provider even when Postgres still says `running`. Providers may
   * pause a VM independently (for example after an idle timeout), so an
   * attach/open operation must verify the live state before minting a route.
   * Passive reads intentionally leave this off.
   */
  readonly forceProviderProbe?: boolean;
};

// resume() can legitimately return a not-yet-running handle (Freestyle maps a
// post-start "starting" state to "creating"), so poll briefly until the VM is
// observably running; never record a running transition for a VM that has not
// settled, and fail without a durable write if it does not.
function waitForRunningStatus(
  providers: VmProviderGatewayShape,
  vm: CloudVmRow,
  providerVmId: string,
): Effect.Effect<boolean, never> {
  return Effect.gen(function* () {
    const getStatus = providers.getStatus;
    if (!getStatus) return true;
    for (let attempt = 0; attempt < RESUME_SETTLE_ATTEMPTS; attempt += 1) {
      const status = yield* getStatus(vm.provider, providerVmId).pipe(
        Effect.timeoutFail({
          duration: RESUME_STATUS_PROBE_TIMEOUT,
          onTimeout: () =>
            new VmProviderOperationError({
              provider: vm.provider,
              operation: `getStatus(${providerVmId})`,
              cause: new Error("status probe timed out"),
            }),
        }),
        Effect.catchAll(() => Effect.succeed(null as VMStatus | null)),
      );
      if (status === "running") return true;
      yield* Effect.sleep(RESUME_SETTLE_INTERVAL);
    }
    return false;
  });
}

function bestEffortPause(
  providers: VmProviderGatewayShape,
  vm: CloudVmRow,
  providerVmId: string,
): Effect.Effect<void, never> {
  const pause = providers.pause;
  if (!pause) return Effect.void;
  return pause(vm.provider, providerVmId).pipe(Effect.catchAll(() => Effect.void));
}

function resumeUntilRunning(
  providers: VmProviderGatewayShape,
  vm: CloudVmRow,
  providerVmId: string,
): Effect.Effect<void, VmWorkflowError> {
  return Effect.gen(function* () {
    const resume = providers.resume;
    if (!resume) return;
    const handle = yield* resume(vm.provider, providerVmId);
    if (handle.status === "running") return;
    const settled = yield* waitForRunningStatus(providers, vm, providerVmId);
    if (settled) return;
    // The provider start already happened; roll back so a started-but-
    // unrecorded VM is never left running outside Postgres accounting.
    yield* bestEffortPause(providers, vm, providerVmId);
    return yield* Effect.fail(
      new VmProviderOperationError({
        provider: vm.provider,
        operation: `resume(${providerVmId})`,
        cause: new Error("VM did not reach running after resume"),
      }),
    );
  });
}

function reservePausedResumeIfTeam(
  repo: VmRepositoryShape,
  vm: CloudVmRow,
  providerVmId: string,
  maxActiveVms: number | null = maxActiveVmsForPlan(vm.billingPlanId),
): Effect.Effect<boolean, VmWorkflowError> {
  if (!vm.billingTeamId) return Effect.succeed(false);
  return Effect.gen(function* () {
    const reserved = yield* repo.reservePausedResume({
      id: vm.id,
      userId: vm.userId,
      billingTeamId: vm.billingTeamId,
      providerVmId,
      maxActiveVms,
    });
    if (!reserved) {
      return yield* Effect.fail(new VmNotFoundError({ vmId: providerVmId }));
    }
    if (reserved.status !== "running") {
      return yield* Effect.fail(
        new VmProviderOperationError({
          provider: vm.provider,
          operation: `reservePausedResume(${providerVmId})`,
          cause: new Error(`VM resume reservation returned ${reserved.status}`),
        }),
      );
    }
    return vm.status === "paused";
  });
}

function rollbackPausedResumeReservation(
  repo: VmRepositoryShape,
  vm: CloudVmRow,
  providerVmId: string,
  reserved: boolean,
): Effect.Effect<void, never> {
  if (!reserved) return Effect.void;
  return repo.markProviderObservedStatus({
    id: vm.id,
    providerVmId,
    status: "paused",
  }).pipe(Effect.catchAll(() => Effect.void));
}

function recordResumeUsageEvent(
  repo: VmRepositoryShape,
  vm: CloudVmRow,
  resumeSource: VmResumeSource,
): Effect.Effect<void, never> {
  return repo.recordUsageEvent({
    userId: vm.userId,
    billingTeamId: vm.billingTeamId,
    billingPlanId: vm.billingPlanId,
    vmId: vm.id,
    eventType: "vm.resumed",
    provider: vm.provider,
    imageId: vm.imageId,
    metadata: { source: resumeSource },
  }).pipe(Effect.catchAll(() => Effect.void));
}

// Active-limit note: the control-plane-owned paused-row resume path is
// limit-gated for billing teams by reservePausedResume before the provider
// resume starts. Freestyle can still resume a VM outside the control plane
// (for example from the provider console); those already-running observations
// are reconciled durably here, and beginCreate re-counts provider-running VMs
// before allocating another active slot.
function preflightResumeIfSuspended(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  vm: CloudVmRow,
  providerVmId: string,
  resumeSource: VmResumeSource,
  options: ResumePreflightOptions = {},
): Effect.Effect<boolean, VmWorkflowError> {
  return Effect.gen(function* () {
    const getStatus = providers.getStatus;
    const resume = providers.resume;
    if (!getStatus || !resume) return false;
    const forceProviderProbe = options.forceProviderProbe === true;
    // A passive/exec path can trust the row and let the provider operation
    // perform its own wake. User-open paths opt into a live probe because a
    // provider can idle-pause a VM while Postgres still says `running`.
    if (vm.status === "running" && !forceProviderProbe) return false;

    const status = yield* getStatus(vm.provider, providerVmId).pipe(
      Effect.timeoutFail({
        duration: RESUME_STATUS_PROBE_TIMEOUT,
        onTimeout: () =>
          new VmProviderOperationError({
            provider: vm.provider,
            operation: `getStatus(${providerVmId})`,
            cause: new Error("status probe timed out"),
          }),
      }),
      Effect.catchAll((err) =>
        // Fail closed when the row durably says paused and the probe cannot
        // prove otherwise: minting endpoints against a suspended VM would
        // hand out unusable credentials and record leases/usage for it.
        vm.status === "paused" || forceProviderProbe
          ? Effect.fail(err)
          : Effect.succeed(null as VMStatus | null),
      ),
    );
    if (status === "destroyed") {
      // A live provider read is authoritative for an access operation. Do not
      // mint an endpoint (or start a fork) against an id that Freestyle has
      // already removed; mark the row so the next fleet refresh drops it and
      // return the same not-found contract as ownership checks.
      yield* repo.markProviderObservedStatus({
        id: vm.id,
        providerVmId,
        status: "destroyed",
      }).pipe(Effect.catchAll(() => Effect.succeed(false)));
      return yield* Effect.fail(new VmNotFoundError({ vmId: providerVmId }));
    }
    if (status === "creating") {
      // Another caller's resume is in flight; wait for it rather than
      // minting endpoints or running commands against a not-yet-ready VM.
      const settled = yield* waitForRunningStatus(providers, vm, providerVmId);
      if (!settled) {
        return yield* Effect.fail(
          new VmProviderOperationError({
            provider: vm.provider,
            operation: `getStatus(${providerVmId})`,
            cause: new Error("VM stayed in a resuming state"),
          }),
        );
      }
      // Persist the observed running state ourselves in case the resuming
      // caller dies before its own durable write. An already-running row
      // still matches the update (returns true); false means the row was
      // destroyed or replaced concurrently, so fail closed. No pause
      // rollback here: the caller that started the VM owns compensation.
      const recorded = yield* repo.markProviderObservedStatus({
        id: vm.id,
        providerVmId,
        status: "running",
      });
      if (!recorded) {
        return yield* Effect.fail(new VmNotFoundError({ vmId: providerVmId }));
      }
      return false;
    }
    if (status === "running") {
      // A provider-side action can resume a VM entirely outside the control
      // plane; if the durable row still says paused, record the observed
      // running state so active-limit reconciliation can see the VM.
      if (vm.status === "paused") {
        const recorded = yield* repo.markProviderObservedStatus({
          id: vm.id,
          providerVmId,
          status: "running",
        });
        if (!recorded) {
          return yield* Effect.fail(new VmNotFoundError({ vmId: providerVmId }));
        }
      }
      return false;
    }
    if (status !== "paused") return false;

    const reserved = yield* reservePausedResumeIfTeam(repo, vm, providerVmId, options.maxActiveVms);
    yield* resumeUntilRunning(providers, vm, providerVmId).pipe(
      Effect.tapError(() => rollbackPausedResumeReservation(repo, vm, providerVmId, reserved)),
    );
    yield* recordRunningTransition(
      repo,
      providers,
      vm,
      providerVmId,
      new VmNotFoundError({ vmId: providerVmId }),
    ).pipe(
      Effect.tapError(() => rollbackPausedResumeReservation(repo, vm, providerVmId, reserved)),
    );
    if (reserved) yield* recordResumeUsageEvent(repo, vm, resumeSource);
    return true;
  });
}

function withResumeOnSuspendedAfterFailure<A>(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  vm: CloudVmRow,
  providerVmId: string,
  resumeSource: VmResumeSource,
  op: Effect.Effect<A, VmWorkflowError>,
  maxActiveVms?: number | null,
): Effect.Effect<A, VmWorkflowError> {
  return op.pipe(
    Effect.catchAll((originalError) => {
      const getStatus = providers.getStatus;
      const resume = providers.resume;
      if (!getStatus || !resume) return Effect.fail(originalError);

      return Effect.gen(function* () {
        const status = yield* getStatus(vm.provider, providerVmId).pipe(
          Effect.catchAll(() => Effect.succeed(null as VMStatus | null)),
        );
        if (status === "creating") {
          const settled = yield* waitForRunningStatus(providers, vm, providerVmId);
          if (!settled) return yield* Effect.fail(originalError);
          const recorded = yield* repo.markProviderObservedStatus({
            id: vm.id,
            providerVmId,
            status: "running",
          }).pipe(Effect.catchAll(() => Effect.succeed(false)));
          if (!recorded) return yield* Effect.fail(originalError);
          return yield* op;
        }
        if (status !== "paused") {
          return yield* Effect.fail(originalError);
        }

        const reserved = yield* reservePausedResumeIfTeam(repo, vm, providerVmId, maxActiveVms);
        yield* resumeUntilRunning(providers, vm, providerVmId).pipe(
          Effect.tapError(() => rollbackPausedResumeReservation(repo, vm, providerVmId, reserved)),
          Effect.catchAll(() => Effect.fail(originalError)),
        );
        yield* recordRunningTransition(repo, providers, vm, providerVmId, originalError).pipe(
          Effect.tapError(() => rollbackPausedResumeReservation(repo, vm, providerVmId, reserved)),
        );
        if (reserved) yield* recordResumeUsageEvent(repo, vm, resumeSource);
        return yield* op;
      });
    }),
  );
}

// After a successful provider resume, Postgres must record the running
// transition before the workflow proceeds. When the write fails (or the row
// was destroyed concurrently), roll the provider back to the durable state
// with a best-effort pause so a running VM is never left invisible to
// active-limit accounting; Freestyle's idle auto-suspend (~10s) is the
// backstop if the pause itself fails.
function recordRunningTransition<E extends VmWorkflowError>(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  vm: CloudVmRow,
  providerVmId: string,
  staleRowError: E,
): Effect.Effect<void, VmDatabaseError | E> {
  const rollbackPause = (): Effect.Effect<void, never> => {
    const pause = providers.pause;
    if (!pause) return Effect.void;
    return pause(vm.provider, providerVmId).pipe(Effect.catchAll(() => Effect.void));
  };
  return Effect.gen(function* () {
    const didUpdate = yield* repo.markProviderObservedStatus({
      id: vm.id,
      providerVmId,
      status: "running",
    }).pipe(
      Effect.tapError(() => rollbackPause()),
    );
    if (!didUpdate) {
      yield* rollbackPause();
      return yield* Effect.fail(staleRowError);
    }
  });
}

export function destroyVm(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
  readonly provider?: ProviderId;
  readonly afterProviderDestroy?: () => void;
  /** Revokes the machine's coderouter tokens once the provider machine is gone. */
  readonly modelPlane?: VmModelPlaneRevoker;
  /** Who asked for the destroy; recorded on the ledger row. Defaults to `user_request`. */
  readonly source?: "user_request" | "account_deletion";
}) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const vm = yield* requireUserVm(input);

    yield* revokeActiveIdentities(vm, { failOnCleanupError: true });
    yield* providers.destroy(vm.provider, vm.providerVmId ?? input.providerVmId).pipe(
      Effect.catchAll((err) => {
        if (isProviderNotFoundError(err.cause)) return Effect.void;
        return Effect.fail(err);
      }),
    );
    const destroyedProviderVmId = vm.providerVmId ?? input.providerVmId;
    yield* revokeModelPlane(input.modelPlane, vm.id);
    // This callback is advisory progress reporting. A failure must not skip
    // the mandatory volume cleanup or DB finalization now that the provider
    // machine is gone. Keep the failure observable in the usage ledger, but
    // leave destroy successful because those mandatory operations are the
    // authoritative outcome.
    try {
      input.afterProviderDestroy?.();
    } catch (err) {
      const message = errorMessage(err);
      console.error(
        `[vm] afterProviderDestroy hook failed for ${destroyedProviderVmId}`,
        message,
      );
      yield* repo.recordUsageEvent({
        userId: input.userId,
        billingTeamId: vm.billingTeamId,
        billingPlanId: vm.billingPlanId,
        vmId: vm.id,
        eventType: "vm.destroy.after_provider_destroy_failed",
        provider: vm.provider,
        imageId: vm.imageId,
        metadata: { message },
      }).pipe(Effect.catchAll(() => Effect.void));
    }
    // The sandbox is gone; a per-machine home volume must go with it or its
    // storage bills forever. The volume delete never fails the destroy — the
    // machine is already unrecoverable — but a failed delete is recorded as a
    // usage event so the leaked volume is findable instead of silent.
    const homeVolume = machineOwnedHomeVolume(vm, destroyedProviderVmId);
    let homeVolumeDeleted = false;
    if (homeVolume && providers.deleteHomeVolume) {
      homeVolumeDeleted = yield* providers.deleteHomeVolume(vm.provider, homeVolume).pipe(
        Effect.as(true),
        Effect.catchAll((err) =>
          Effect.gen(function* () {
            console.error(
              `[vm] home volume delete failed for ${destroyedProviderVmId} (${homeVolume})`,
              errorMessage(err.cause),
            );
            yield* repo.recordUsageEvent({
              userId: input.userId,
              billingTeamId: vm.billingTeamId,
              billingPlanId: vm.billingPlanId,
              vmId: vm.id,
              eventType: "vm.home_volume.delete_failed",
              provider: vm.provider,
              imageId: vm.imageId,
              metadata: { homeVolume, message: errorMessage(err.cause) },
            }).pipe(Effect.catchAll(() => Effect.void));
            return false;
          }),
        ),
      );
    }
    // The provider-side machine is gone at this point, so a lost DB write would
    // leave a ghost row counting against the active-VM limit. Retry the write;
    // the provider-status reconciler is the backstop if it still fails.
    yield* repo.markDestroyed(vm.id).pipe(Effect.retry({ times: 2 }));
    yield* repo.recordUsageEvent({
      userId: input.userId,
      billingTeamId: vm.billingTeamId,
      billingPlanId: vm.billingPlanId,
      vmId: vm.id,
      eventType: "vm.destroyed",
      provider: vm.provider,
      imageId: vm.imageId,
      vmCreatedAt: vm.createdAt,
      metadata: {
        source: input.source ?? "user_request",
        ...(homeVolume ? { homeVolume, homeVolumeDeleted } : {}),
      },
    }).pipe(Effect.catchAll(() => Effect.void));
  });
}

export function revokeExpiredIdentityLeases(input: {
  readonly now?: Date;
  readonly limit?: number;
} = {}) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const expiredIdentityLeases = repo.expiredIdentityLeases;
    if (!expiredIdentityLeases) return 0;
    const now = input.now ?? new Date();
    const leases = yield* expiredIdentityLeases({
      now,
      limit: input.limit ?? EXPIRED_IDENTITY_REVOKE_BATCH,
    });
    const revokedIds: string[] = [];
    for (const lease of leases) {
      const identityHandle = lease.providerIdentityHandle;
      if (!identityHandle) continue;
      const retryAfter = new Date(now.getTime() + EXPIRED_IDENTITY_REVOKE_RETRY_BACKOFF_MS);
      yield* (repo.markLeaseRevocationRetry?.({
        id: lease.id,
        retryAfter,
        error: "revoke pending",
      }) ?? Effect.void).pipe(Effect.catchAll(() => Effect.void));
      const revoked = yield* revokeSSHIdentityForCleanup(providers, lease.provider, identityHandle).pipe(
        Effect.as(true),
        Effect.catchAll((err) => {
          if (isProviderIdentityNotFoundError(err.cause)) return Effect.succeed(true);
          return Effect.succeed(false);
        }),
      );
      if (revoked) revokedIds.push(lease.id);
    }
    yield* repo.markLeasesRevoked(revokedIds);
    return revokedIds.length;
  });
}

export function revokeUserIdentityLeasesForAccountDeletion(
  userId: string,
  input: {
    readonly limit?: number;
    readonly afterBatch?: () => Effect.Effect<void, VmWorkflowError>;
  } = {},
) {
  const limit = boundedAccountDeletionIdentityRevokeLimit(input.limit);
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    let revokedCount = 0;
    for (;;) {
      const leases = yield* repo.accountDeletionIdentityLeases({ userId, limit });
      if (leases.length === 0) return revokedCount;

      const revokedIds: string[] = [];
      for (const lease of leases) {
        const identityHandle = lease.providerIdentityHandle;
        if (!identityHandle) {
          revokedIds.push(lease.id);
          continue;
        }
        const revoked = yield* revokeSSHIdentityForCleanup(providers, lease.provider, identityHandle).pipe(
          Effect.as(true),
          Effect.catchAll((err) => {
            if (isProviderIdentityNotFoundError(err.cause)) return Effect.succeed(true);
            return repo.markLeasesRevoked(revokedIds).pipe(
              Effect.catchAll(() => Effect.void),
              Effect.andThen(Effect.fail(new VmAccountDeletionIdentityRevocationError({ cause: err }))),
            );
          }),
        );
        if (revoked) revokedIds.push(lease.id);
      }

      yield* markAccountDeletionLeasesRevoked(repo, revokedIds);
      revokedCount += revokedIds.length;
      if (input.afterBatch) yield* input.afterBatch();
      if (leases.length < limit) return revokedCount;
    }
  });
}

function markAccountDeletionLeasesRevoked(
  repo: VmRepositoryShape,
  revokedIds: readonly string[],
): Effect.Effect<void, VmWorkflowError> {
  return repo.markLeasesRevoked(revokedIds).pipe(
    Effect.catchAll((err): Effect.Effect<never, VmWorkflowError> =>
      Effect.fail(
        revokedIds.length > 0
          ? new VmAccountDeletionIdentityRevocationError({ cause: err })
          : err,
      )
    ),
  );
}

function boundedAccountDeletionIdentityRevokeLimit(limit: number | undefined): number {
  if (typeof limit !== "number" || !Number.isFinite(limit)) return ACCOUNT_DELETION_IDENTITY_REVOKE_BATCH;
  return Math.max(1, Math.min(Math.floor(limit), ACCOUNT_DELETION_IDENTITY_REVOKE_BATCH));
}

export function execVm(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
  /** Current billing-scope machine allowance; null means unlimited. */
  readonly maxActiveVms?: number | null;
  readonly command: string;
  readonly timeoutMs: number;
  /** Caller's CURRENT billing plan; used for the free access window. */
  readonly callerPlanId?: string | null;
}) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const vm = yield* requireAccessibleUserVm(input);
    yield* preflightResumeIfSuspended(
      repo,
      providers,
      vm,
      input.providerVmId,
      "exec",
      { maxActiveVms: input.maxActiveVms },
    );
    const result = yield* providers.exec(vm.provider, input.providerVmId, input.command, {
      timeoutMs: input.timeoutMs,
      providerMetadata: vm.providerMetadata,
    });
    yield* repo.recordUsageEvent({
      userId: input.userId,
      billingTeamId: vm.billingTeamId,
      billingPlanId: vm.billingPlanId,
      vmId: vm.id,
      eventType: "vm.exec",
      provider: vm.provider,
      imageId: vm.imageId,
      metadata: { commandLength: input.command.length, exitCode: result.exitCode },
    }).pipe(Effect.catchAll(() => Effect.void));
    return result satisfies ExecResult;
  });
}

export function getVmStats(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
}) {
  return Effect.gen(function* () {
    const providers = yield* VmProviderGateway;
    const vm = yield* requireUserVm(input);
    // No resume preflight on purpose: a reading must never wake a sleeping machine.
    if (!providers.getStats) {
      return yield* Effect.fail(
        new VmProviderOperationError({
          provider: vm.provider,
          operation: "getStats",
          cause: new Error("machine stats are not supported by this deployment"),
        }),
      );
    }
    return yield* providers.getStats(vm.provider, input.providerVmId);
  });
}

export function resizeVm(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
  readonly storageMb: number;
  /** Current caller/VM plan for paid-machine resize recovery. */
  readonly billingPlanId?: string | null;
  /** Current machine-count allowance, also used when resuming a paused VM. */
  readonly maxActiveVms?: number | null;
}) {
  // oxlint-disable-next-line complexity -- Resize orchestration must keep reservation, provider, rollback, and confirmation order explicit.
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const vm = yield* requireAccessibleUserVm(input);
    if (!providers.resize || !providers.getStats) {
      return yield* Effect.fail(new VmOperationUnsupportedError({ provider: vm.provider, operation: "resize" }));
    }
    yield* preflightResumeIfSuspended(repo, providers, vm, input.providerVmId, "resize", {
      forceProviderProbe: true,
      maxActiveVms: input.maxActiveVms,
    });
    const current = yield* providers.getStats(vm.provider, input.providerVmId);
    const currentMb = vmProviderResourceSize("diskMb", current.diskTotalMb);
    if (currentMb === null) {
      return yield* Effect.fail(new VmOperationUnsupportedError({ provider: vm.provider, operation: "resize" }));
    }
    if (input.storageMb < currentMb) {
      return yield* Effect.fail(new VmResizeInvalidError({
        vmId: input.providerVmId,
        requestedMb: input.storageMb,
        currentMb,
        maxMb: VM_DISK_MB_MAX,
        reason: "below_current",
      }));
    }
    if (input.storageMb > VM_DISK_MB_MAX || input.storageMb % VM_DISK_MB_STEP !== 0) {
      return yield* Effect.fail(new VmResizeInvalidError({
        vmId: input.providerVmId,
        requestedMb: input.storageMb,
        currentMb,
        maxMb: VM_DISK_MB_MAX,
        reason: "above_max",
      }));
    }
    // Claim the new disk size under the same billing-team lock used by create.
    // The live repository always provides this method; test doubles from
    // before resource tracking may omit it and exercise provider behavior
    // without a database.
    let reservation: VmResizeReservation | null = null;
    if (repo.reserveVmResize && isPaidVmPlan(input.billingPlanId ?? vm.billingPlanId ?? "")) {
      reservation = yield* repo.reserveVmResize({
        id: vm.id,
        userId: input.userId,
        billingTeamId: vm.billingTeamId ?? input.billingTeamId,
        providerVmId: input.providerVmId,
        currentDiskMb: currentMb,
        storageMb: input.storageMb,
        maxActiveVms: input.maxActiveVms === undefined ? maxActiveVmsForPlan(vm.billingPlanId) : input.maxActiveVms,
      });
      if (!reservation) {
        return yield* Effect.fail(new VmNotFoundError({ vmId: input.providerVmId }));
      }
    }
    // A no-op request still backfills the durable reservation for legacy rows
    // whose provider metadata predates the resource tracking.
    if (input.storageMb === currentMb) return current;
    const rollbackReservation = () => reservation && repo.restoreVmResize
      ? repo.restoreVmResize({
        id: vm.id,
        expectedDiskMb: reservation.reservedDiskMb,
        previousDiskMb: reservation.previousDiskMb,
        operationId: reservation.operationId,
      }).pipe(Effect.catchAll(() => Effect.void))
      : Effect.void;
    const rollbackIfProviderDidNotGrow = (
      exit: Exit.Exit<void, VmProviderOperationError | VmOperationUnsupportedError>,
    ) => {
      if (!reservation || !repo.restoreVmResize || Exit.isSuccess(exit)) return Effect.void;
      // A provider request can complete and lose its response before the
      // caller observes success. Release the claim only when a fresh provider
      // read proves that the disk is still at its pre-resize size. If the read
      // fails or reports growth, keep the larger claim as a safe upper bound.
      return providers.getStats!(vm.provider, input.providerVmId).pipe(
        Effect.flatMap((stats) => {
          const observedDiskMb = vmProviderResourceSize("diskMb", stats.diskTotalMb);
          return observedDiskMb !== null && observedDiskMb <= currentMb
            ? rollbackReservation()
            : Effect.void;
        }),
        Effect.catchAll(() => Effect.void),
      );
    };
    yield* providers.resize(vm.provider, input.providerVmId, { storageMb: input.storageMb }).pipe(
      Effect.onExit(rollbackIfProviderDidNotGrow),
    );
    const updated = yield* providers.getStats(vm.provider, input.providerVmId).pipe(
      Effect.tapError(() => finalizeUnobservedResize(repo, vm.id, reservation)),
    );
    // The provider can round a requested disk up. Persist the observed claim
    // before returning so later snapshots and forks retain the measured shape.
    // Missing or malformed stats fail closed at the per-VM maximum.
    const confirmedDiskMb = vmProviderResourceSize("diskMb", updated.diskTotalMb) ?? VM_DISK_MB_MAX;
    if (reservation && repo.confirmVmResize) {
      const confirmed = yield* repo.confirmVmResize({
        id: vm.id,
        expectedDiskMb: reservation.reservedDiskMb,
        ...(reservation.requestedDiskMb === undefined
          ? {}
          : { minimumDiskMb: reservation.requestedDiskMb }),
        confirmedDiskMb,
        operationId: reservation.operationId,
      });
      if (!confirmed) {
        return yield* Effect.fail(new VmDatabaseError({
          operation: "confirmVmResize",
          cause: new Error("resize confirmation no longer owns the pending generation"),
        }));
      }
    }
    yield* repo.recordUsageEvent({
      userId: input.userId,
      billingTeamId: vm.billingTeamId,
      billingPlanId: vm.billingPlanId,
      vmId: vm.id,
      eventType: "vm.resize",
      provider: vm.provider,
      imageId: vm.imageId,
      metadata: {
        storageMb: input.storageMb,
        confirmedStorageMb: confirmedDiskMb,
        previousStorageMb: currentMb,
      },
    }).pipe(Effect.catchAll(() => Effect.void));
    return updated;
  });
}

/**
 * A successful provider resize followed by a lost stats response still owns
 * its reservation. Replace the active marker with an unconfirmed marker so a
 * later reconcile can lower the conservative claim without blocking new work.
 */
function finalizeUnobservedResize(
  repo: VmRepositoryShape,
  vmId: string,
  reservation: VmResizeReservation | null,
): Effect.Effect<void, never> {
  if (!reservation || !repo.markVmResizeUnconfirmed) return Effect.void;
  return repo.markVmResizeUnconfirmed({
    id: vmId,
    expectedDiskMb: reservation.reservedDiskMb,
    ...(reservation.requestedDiskMb === undefined
      ? {}
      : { minimumDiskMb: reservation.requestedDiskMb }),
    previousDiskMb: reservation.previousDiskMb,
    operationId: reservation.operationId,
  }).pipe(
    Effect.asVoid,
    Effect.catchAll((err) =>
      Effect.sync(() => {
        console.error(`[vm] could not finalize unobserved resize for ${vmId}`, errorMessage(err));
      }),
    ),
  );
}

export function openVmPort(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
  /** Current billing-scope machine allowance; null means unlimited. */
  readonly maxActiveVms?: number | null;
  readonly port: number;
  /** Caller's CURRENT billing plan; used for the free access window. */
  readonly callerPlanId?: string | null;
}) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const vm = yield* requireAccessibleUserVm(input);
    // The live gateway always exposes an `openPort` adapter, even when the
    // selected driver does not. Check the driver capability before the resume
    // preflight so an unsupported request cannot wake a paused VM or record a
    // misleading resume event.
    if (!providers.openPort || !vmCapabilitiesFor(vm.provider).ports) {
      return yield* Effect.fail(
        new VmOperationUnsupportedError({
          provider: vm.provider,
          operation: "openPort",
        }),
      );
    }
    yield* preflightResumeIfSuspended(
      repo,
      providers,
      vm,
      input.providerVmId,
      "open_port",
      { forceProviderProbe: true, maxActiveVms: input.maxActiveVms },
    );
    const endpoint = yield* providers.openPort(vm.provider, input.providerVmId, input.port);
    // Keep the preview token in the same revocation ledger as terminal/RPC
    // endpoints. The raw token is never persisted; only its hash is needed to
    // identify and invalidate this account's lease during sign-out.
    yield* repo.recordLease({
      vmId: vm.id,
      userId: input.userId,
      kind: "preview",
      tokenHash: hashToken(endpoint.token),
      expiresAt: new Date(Date.now() + PREVIEW_ENDPOINT_LEASE_TTL_MS),
      transport: "https",
      metadata: { port: input.port },
    }).pipe(
      Effect.catchAll((err) => {
        const cleanup = providers.revokeEndpointLeases
          ? providers.revokeEndpointLeases(vm.provider, input.providerVmId).pipe(Effect.catchAll(() => Effect.void))
          : Effect.void;
        return cleanup.pipe(Effect.andThen(Effect.fail(err)));
      }),
    );
    yield* repo.recordUsageEvent({
      userId: input.userId,
      billingTeamId: vm.billingTeamId,
      billingPlanId: vm.billingPlanId,
      vmId: vm.id,
      eventType: "vm.open_port",
      provider: vm.provider,
      imageId: vm.imageId,
      metadata: { port: input.port },
    }).pipe(Effect.catchAll(() => Effect.void));
    return endpoint;
  });
}

/**
 * Attach through the cmux-tui remote daemon — the only session transport on
 * machines (other providers still serve the legacy websocket/SSH attach). The ingress
 * token lands in the same lease ledger as previews so sign-out revokes it; session
 * auth is the daemon's device enrollment, which the client completes with
 * approveVmCmuxRemoteEnrollment.
 */
export function openVmCmuxRemote(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
  /** Current billing-scope machine allowance; null means unlimited. */
  readonly maxActiveVms?: number | null;
  readonly deviceFingerprint?: string;
  readonly clientCapabilities?: readonly string[];
  /** Caller's CURRENT billing plan; the free access window applies to cmux-tui attaches too. */
  readonly callerPlanId?: string | null;
}) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const vm = yield* requireAccessibleUserVm(input);
    if (!providers.openCmuxRemote) {
      return yield* Effect.fail(
        new VmProviderOperationError({
          provider: vm.provider,
          operation: "openCmuxRemote",
          cause: new Error("the cmux-tui remote daemon is not supported by this deployment"),
        }),
      );
    }
    yield* preflightResumeIfSuspended(
      repo,
      providers,
      vm,
      input.providerVmId,
      "attach",
      { forceProviderProbe: true, maxActiveVms: input.maxActiveVms },
    );
    const endpoint = yield* withResumeOnSuspendedAfterFailure(
      repo,
      providers,
      vm,
      input.providerVmId,
      "attach",
      providers.openCmuxRemote(vm.provider, input.providerVmId, {
        deviceFingerprint: input.deviceFingerprint,
        clientCapabilities: input.clientCapabilities,
        providerMetadata: vm.providerMetadata,
      }),
      input.maxActiveVms,
    );
    yield* repo.recordLease({
      vmId: vm.id,
      userId: input.userId,
      kind: "preview",
      tokenHash: hashToken(endpoint.token),
      expiresAt: new Date(endpoint.expiresAtUnix * 1000),
      transport: "cmux-remote",
      metadata: { session: endpoint.session, invited: false, trustedCarrier: endpoint.trustedCarrier },
    }).pipe(
      Effect.catchAll((err) => {
        const cleanup = providers.revokeEndpointLeases
          ? providers.revokeEndpointLeases(vm.provider, input.providerVmId).pipe(Effect.catchAll(() => Effect.void))
          : Effect.void;
        return cleanup.pipe(Effect.andThen(Effect.fail(err)));
      }),
    );
    yield* repo.recordUsageEvent({
      userId: input.userId,
      billingTeamId: vm.billingTeamId,
      billingPlanId: vm.billingPlanId,
      vmId: vm.id,
      eventType: "vm.attach",
      provider: vm.provider,
      imageId: vm.imageId,
      metadata: { transport: "cmux-remote", invited: false, trustedCarrier: endpoint.trustedCarrier },
    }).pipe(Effect.catchAll(() => Effect.void));
    // Backfill: machines created before address recording learn their private
    // address on first attach, so "Copy IP Address" appears for them too.
    const learned = endpoint.networkAddresses;
    if (learned && repo.mergeProviderMetadata) {
      const metadata = vm.providerMetadata ?? {};
      const patch = {
        ...(learned.ipv4 && metadata["networkIpv4"] !== learned.ipv4 ? { networkIpv4: learned.ipv4 } : {}),
        ...(learned.ipv6 && metadata["networkIpv6"] !== learned.ipv6 ? { networkIpv6: learned.ipv6 } : {}),
      };
      if (Object.keys(patch).length) {
        yield* repo.mergeProviderMetadata({ id: vm.id, patch }).pipe(Effect.catchAll(() => Effect.void));
      }
    }
    return endpoint;
  });
}

export function approveVmCmuxRemoteEnrollment(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
  readonly invitationId: string;
  readonly callerPlanId?: string | null;
}) {
  return Effect.gen(function* () {
    const providers = yield* VmProviderGateway;
    const vm = yield* requireAccessibleUserVm(input);
    if (!providers.approveCmuxRemoteEnrollment) {
      return yield* Effect.fail(
        new VmProviderOperationError({
          provider: vm.provider,
          operation: "approveCmuxRemoteEnrollment",
          cause: new Error("the cmux-tui remote daemon is not supported by this deployment"),
        }),
      );
    }
    return yield* providers.approveCmuxRemoteEnrollment(vm.provider, input.providerVmId, input.invitationId, {
      providerMetadata: vm.providerMetadata,
    });
  });
}

export type VmAccessRevocationResult = {
  readonly revoked: number;
  readonly cleanupFailures: number;
};

/**
 * Invalidates endpoint credentials issued to one signed-in account.
 *
 * Lease rows are account-scoped even when the VM itself is team-owned. This
 * keeps signing out one team member from revoking another member's session,
 * while the provider hook closes the concrete daemon/preview credentials that
 * were already handed to this client.
 */
export function revokeUserVmAccess(input: { readonly userId: string }) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const loadLeases = repo.activeAccessLeasesForUser;
    if (!loadLeases) return { revoked: 0, cleanupFailures: 0 } satisfies VmAccessRevocationResult;

    const leases = yield* loadLeases(input.userId);
    const byVm = new Map<string, CloudVmAccessLeaseRow[]>();
    for (const lease of leases) {
      const existing = byVm.get(lease.vmId) ?? [];
      existing.push(lease);
      byVm.set(lease.vmId, existing);
    }

    let cleanupFailures = 0;
    if (providers.revokeEndpointLeases) {
      for (const vmLeases of byVm.values()) {
        const first = vmLeases[0];
        if (!first) continue;
        yield* providers.revokeEndpointLeases(first.provider, first.providerVmId).pipe(
          Effect.catchAll(() =>
            Effect.sync(() => {
              cleanupFailures += 1;
            })
          ),
        );
      }
    }

    const leaseIDs = leases.map((lease) => lease.id);
    yield* repo.markLeasesRevoked(leaseIDs);
    return {
      revoked: leaseIDs.length,
      cleanupFailures,
    } satisfies VmAccessRevocationResult;
  });
}

type OpenAttachEndpointInput = {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
  /** Current billing-scope machine allowance; null means unlimited. */
  readonly maxActiveVms?: number | null;
  readonly options?: AttachOptions;
  readonly sessionTitle?: string | null;
  /** Caller's CURRENT billing plan; used for the free access window. */
  readonly callerPlanId?: string | null;
};

export function openAttachEndpoint(input: OpenAttachEndpointInput) {
  return Effect.gen(function* () {
    const result = yield* openAttachEndpointResult(input);
    return result.endpoint;
  });
}

export function openVmSession(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
  /** Current billing-scope machine allowance; null means unlimited. */
  readonly maxActiveVms?: number | null;
  readonly sessionId?: string;
  readonly attachmentId?: string;
  readonly title?: string | null;
  /** Caller's CURRENT billing plan; used for the free access window. */
  readonly callerPlanId?: string | null;
}) {
  const sessionId = input.sessionId?.trim() || `session-${randomUUID()}`;
  const attachmentId = input.attachmentId?.trim() || `attach-${randomUUID()}`;
  return openAttachEndpointResult({
    userId: input.userId,
    billingTeamId: input.billingTeamId,
    teamIds: input.teamIds,
    providerVmId: input.providerVmId,
    callerPlanId: input.callerPlanId,
    maxActiveVms: input.maxActiveVms,
    sessionTitle: input.title,
    options: {
      requireDaemon: true,
      sessionId,
      attachmentId,
    },
  });
}

export function listVmSessions(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
  /** Caller's CURRENT billing plan; used for the free access window. */
  readonly callerPlanId?: string | null;
}) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const vm = yield* requireAccessibleUserVm(input);
    return yield* repo.listVmSessions({ userId: input.userId, vmId: vm.id });
  });
}

function openAttachEndpointResult(input: OpenAttachEndpointInput) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const vm = yield* requireAccessibleUserVm(input);
    // A provider that only runs the cmux-tui daemon cannot serve the legacy
    // websocket/SSH attach at all; say so before waking or mutating anything.
    const supportedTransports = providers.attachTransports?.(vm.provider);
    if (supportedTransports && !supportedTransports.some((t) => t === "websocket" || t === "ssh")) {
      return yield* Effect.fail(
        new VmAttachTransportUnsupportedError({
          provider: vm.provider,
          vmId: input.providerVmId,
          requested: "websocket",
          supported: supportedTransports,
        }),
      );
    }
    yield* preflightResumeIfSuspended(
      repo,
      providers,
      vm,
      input.providerVmId,
      "attach",
      { forceProviderProbe: true, maxActiveVms: input.maxActiveVms },
    );
    // Once preflight records the VM as running, that state is externally
    // visible to concurrent attach/SSH requests. Later cleanup failures must
    // fail closed without pausing a VM another request may have attached to.
    yield* revokeActiveIdentities(vm, { failOnCleanupError: true });
    const endpoint = yield* withResumeOnSuspendedAfterFailure(
      repo,
      providers,
      vm,
      input.providerVmId,
      "attach",
      providers.openAttach(vm.provider, input.providerVmId, {
        ...(input.options ?? {}),
        providerMetadata: vm.providerMetadata,
      }),
      input.maxActiveVms,
    );
    yield* storeEndpointLeases(vm, endpoint).pipe(
      Effect.catchAll((err) =>
        revokeEndpointIdentity(vm.provider, endpoint).pipe(
          Effect.andThen(Effect.fail(err)),
        ),
      ),
    );
    yield* repo.recordUsageEvent({
      userId: input.userId,
      billingTeamId: vm.billingTeamId,
      billingPlanId: vm.billingPlanId,
      vmId: vm.id,
      eventType: "vm.attach",
      provider: vm.provider,
      imageId: vm.imageId,
      metadata: {
        transport: endpoint.transport,
        requireDaemon: input.options?.requireDaemon === true,
        requestedSessionId: input.options?.sessionId ?? null,
        daemonAvailable: endpoint.transport === "websocket" && !!endpoint.daemon,
      },
    }).pipe(Effect.catchAll(() => Effect.void));
    const session = endpoint.transport === "websocket"
      ? yield* repo.upsertVmSession({
        vmId: vm.id,
        userId: input.userId,
        providerSessionId: endpoint.sessionId,
        title: input.sessionTitle ?? null,
        status: "running",
        attachmentCount: 1,
        metadata: {
          transport: endpoint.transport,
          daemonAvailable: !!endpoint.daemon,
          attachmentId: endpoint.attachmentId,
        },
      })
      : undefined;
    return { endpoint, session };
  });
}

/// Access-verb variant of requireUserVm: a free-plan machine older than the
/// free access window is preserved but unreachable until the caller upgrades.
/// List/status/rename/delete deliberately keep using requireUserVm so the
/// machine stays visible and disposable while locked.
function requireAccessibleUserVm(input: ExistingVmAccessInput) {
  return Effect.gen(function* () {
    const vm = yield* requireUserVm(input);
    if (isVmFreeAccessExpired(input.callerPlanId, vm.createdAt ?? undefined)) {
      return yield* Effect.fail(new VmFreeAccessExpiredError({
        vmId: input.providerVmId,
        windowDays: vmFreeAccessWindowDays(),
      }));
    }
    return vm;
  });
}

function requireUserVm(input: ExistingVmAccessInput) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const vm = yield* repo.findUserVm({
      userId: input.userId,
      billingTeamId: input.billingTeamId,
      providerVmId: input.providerVmId,
      provider: input.provider,
    });
    if (!vm || !vm.providerVmId || isRetiredProviderRow(vm)) {
      return yield* Effect.fail(new VmNotFoundError({ vmId: input.providerVmId }));
    }
    if (!callerStillOwnsBillingScope(input, vm)) {
      return yield* Effect.fail(new VmNotFoundError({ vmId: input.providerVmId }));
    }
    return vm;
  });
}

function callerStillOwnsBillingScope(input: ExistingVmAccessInput, vm: CloudVmRow): boolean {
  const billingTeamId = vm.billingTeamId?.trim();
  if (!billingTeamId) return true;
  if (billingTeamId === input.userId) return true;
  if (!input.teamIds) return false;
  return new Set(input.teamIds).has(billingTeamId);
}

function revokeActiveIdentities(
  vm: CloudVmRow,
  options: { readonly failOnCleanupError?: boolean; readonly limit?: number } = {},
) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const leases = yield* repo.activeIdentityLeases(
      vm.id,
      options.failOnCleanupError ? ACTIVE_IDENTITY_REVOKE_HOT_PATH_LIMIT + 1 : options.limit,
    );
    if (options.failOnCleanupError && leases.length > ACTIVE_IDENTITY_REVOKE_HOT_PATH_LIMIT) {
      return yield* Effect.fail(new VmProviderOperationError({
        provider: vm.provider,
        operation: "revokeSSHIdentity",
        cause: new Error(`too many active identity leases pending cleanup: ${leases.length}`),
      }));
    }
    const revokedIds: string[] = [];
    for (const lease of leases) {
      const identityHandle = lease.providerIdentityHandle;
      if (!identityHandle) continue;
      const revoked = yield* revokeSSHIdentityForCleanup(providers, vm.provider, identityHandle).pipe(
        Effect.as(true),
        Effect.catchAll((err) => {
          if (isProviderIdentityNotFoundError(err.cause)) return Effect.succeed(true);
          if (!options.failOnCleanupError) return Effect.succeed(false);
          return repo.markLeasesRevoked(revokedIds).pipe(
            Effect.andThen(Effect.fail(err)),
          );
        }),
      );
      if (revoked) revokedIds.push(lease.id);
    }
    yield* repo.markLeasesRevoked(revokedIds);
  });
}

function revokeSSHIdentityForCleanup(
  providers: VmProviderGatewayShape,
  provider: ProviderId,
  identityHandle: string,
): Effect.Effect<void, VmProviderOperationError> {
  return providers.revokeSSHIdentity(provider, identityHandle).pipe(
    Effect.timeoutFail({
      duration: IDENTITY_REVOKE_PROVIDER_TIMEOUT,
      onTimeout: () =>
        new VmProviderOperationError({
          provider,
          operation: "revokeSSHIdentity",
          cause: new Error("identity revoke timed out"),
        }),
    }),
  );
}

function storeEndpointLeases(vm: CloudVmRow, endpoint: AttachEndpoint | SSHEndpoint) {
  return Effect.gen(function* () {
    if (endpoint.transport === "ssh") {
      yield* recordEndpointLease(vm, {
        kind: "ssh",
        token: sshCredentialToken(endpoint),
        expiresAt: new Date(Date.now() + 15 * 60 * 1000),
        providerIdentityHandle: endpoint.identityHandle || undefined,
        transport: "ssh",
        metadata: { credentialKind: endpoint.credential.kind },
      });
      if (endpoint.daemon) {
        yield* recordEndpointLease(vm, {
          kind: "rpc",
          token: endpoint.daemon.token,
          expiresAt: new Date(endpoint.daemon.expiresAtUnix * 1000),
          sessionId: endpoint.daemon.sessionId,
          transport: "websocket",
        });
      }
      return;
    }

    yield* recordEndpointLease(vm, {
      kind: "pty",
      token: endpoint.token,
      expiresAt: new Date(endpoint.expiresAtUnix * 1000),
      sessionId: endpoint.sessionId,
      transport: "websocket",
    });
    if (endpoint.daemon) {
      yield* recordEndpointLease(vm, {
        kind: "rpc",
        token: endpoint.daemon.token,
        expiresAt: new Date(endpoint.daemon.expiresAtUnix * 1000),
        sessionId: endpoint.daemon.sessionId,
        transport: "websocket",
      });
    }
  });
}

function recordCreditEvent(
  repo: VmRepositoryShape,
  vm: CloudVmRow,
  eventType: string,
  reservation: VmCreateCreditReservation,
) {
  if (reservation.kind === "none") return Effect.void;
  return repo.recordUsageEvent({
    userId: vm.userId,
    billingTeamId: vm.billingTeamId,
    billingPlanId: vm.billingPlanId,
    vmId: vm.id,
    eventType,
    provider: vm.provider,
    imageId: vm.imageId,
    metadata: {
      itemId: reservation.itemId,
      amount: reservation.amount,
      customerType: reservation.customerType,
      customerIdSet: !!reservation.customerId,
    },
  });
}

function reserveCreateCredit(
  billing: VmBillingGatewayShape,
  repo: VmRepositoryShape,
  input: {
    readonly userId: string;
    readonly billingCustomerType: BillingCustomerType;
    readonly billingTeamId: string;
    readonly billingPlanId: string;
    readonly provider: ProviderId;
    readonly image: string;
    readonly imageVersion?: string | null;
    readonly idempotencyKey?: string;
    readonly timing?: VmTimingSink;
  },
  vm: CloudVmRow,
) {
  return measureVmEffect(
    input.timing,
    "billing",
    Effect.gen(function* () {
      yield* seedInitialCreateCredits(billing, repo, input, vm).pipe(
        Effect.catchAll((err) =>
          repo.recordUsageEvent({
            userId: input.userId,
            billingTeamId: input.billingTeamId,
            billingPlanId: input.billingPlanId,
            vmId: vm.id,
            eventType: "vm.create.credit.grant_failed",
            provider: input.provider,
            imageId: input.image,
            metadata: {
              idempotencyKeySet: !!input.idempotencyKey,
              imageVersion: input.imageVersion ?? null,
              message: errorMessage(err),
            },
          }).pipe(Effect.catchAll(() => Effect.void))
        ),
      );

      const creditReservation = yield* billing.reserveCreate({
        userId: input.userId,
        billingCustomerType: input.billingCustomerType,
        billingTeamId: input.billingTeamId,
        billingPlanId: input.billingPlanId,
        provider: input.provider,
        image: input.image,
        imageVersion: input.imageVersion ?? null,
        vmId: vm.id,
        idempotencyKey: input.idempotencyKey,
      }).pipe(
        Effect.tapError((err) =>
          Effect.all([
            repo.markCreateFailed({
              id: vm.id,
              code: isVmCreateCreditsInsufficientError(err)
                ? "billing_credits_insufficient"
                : "billing_reserve_failed",
              message: errorMessage(err),
            }),
            repo.recordUsageEvent({
              userId: input.userId,
              billingTeamId: input.billingTeamId,
              billingPlanId: input.billingPlanId,
              vmId: vm.id,
              eventType: "vm.create.billing_failed",
              provider: input.provider,
              imageId: input.image,
              metadata: {
                idempotencyKeySet: !!input.idempotencyKey,
                imageVersion: input.imageVersion ?? null,
                errorTag: typeof err === "object" && err !== null && "_tag" in err
                  ? String((err as { _tag?: unknown })._tag)
                  : null,
              },
            }),
          ], { discard: true }).pipe(Effect.catchAll(() => Effect.void))
        ),
      );
      return creditReservation;
    }),
  );
}

function recordCreateRequestedEvents(
  repo: VmRepositoryShape,
  input: {
    readonly userId: string;
    readonly billingTeamId: string;
    readonly billingPlanId: string;
    readonly provider: ProviderId;
    readonly image: string;
    readonly imageVersion?: string | null;
    readonly idempotencyKey?: string;
    readonly timing?: VmTimingSink;
  },
  requestedVm: CloudVmRow,
  creditReservation: VmCreateCreditReservation,
) {
  return measureVmEffect(
    input.timing,
    "usage_events",
    repo.recordUsageEvents([
      ...(creditReservation.kind === "none"
        ? []
        : [creditUsageEvent(requestedVm, "vm.create.credit.reserved", creditReservation)]),
      {
        userId: input.userId,
        billingTeamId: input.billingTeamId,
        billingPlanId: input.billingPlanId,
        vmId: requestedVm.id,
        eventType: "vm.create.requested",
        provider: input.provider,
        imageId: input.image,
        metadata: {
          idempotencyKeySet: !!input.idempotencyKey,
          imageVersion: input.imageVersion ?? null,
        },
      },
    ]).pipe(Effect.catchAll(() => Effect.void)),
  );
}

export type VmCreateOrigin = "create" | "restore" | "fork" | "base";

function recordCreateSuccessEvents(
  repo: VmRepositoryShape,
  input: {
    readonly idempotencyKey?: string;
    readonly timing?: VmTimingSink;
    readonly origin?: VmCreateOrigin;
    readonly memoryMb?: number;
    readonly persistentHome?: boolean;
    readonly perMachineHome?: boolean;
    readonly imageSize?: CreateOptions["imageSize"];
  },
  running: CloudVmRow,
) {
  return measureVmEffect(
    input.timing,
    "usage_events",
    repo.recordUsageEvents([
      {
        userId: running.userId,
        billingTeamId: running.billingTeamId,
        billingPlanId: running.billingPlanId,
        vmId: running.id,
        eventType: "vm.created",
        provider: running.provider,
        imageId: running.imageId,
        metadata: {
          idempotencyKeySet: !!input.idempotencyKey,
          imageVersion: running.imageVersion,
          // Machine shape and origin, so analytics can size the fleet by plan
          // and tell a fresh create from a restore, fork or base open.
          origin: input.origin ?? "create",
          ...(input.memoryMb !== undefined ? { memoryMb: input.memoryMb } : {}),
          ...(input.imageSize ? { imageSize: input.imageSize.name } : {}),
          ...(input.persistentHome !== undefined ? { persistentHome: input.persistentHome } : {}),
          ...(input.perMachineHome !== undefined ? { perMachineHome: input.perMachineHome } : {}),
        },
      },
    ]).pipe(Effect.catchAll(() => Effect.void)),
  );
}

function recordCreateFailureEvent(
  repo: VmRepositoryShape,
  input: {
    readonly userId: string;
    readonly billingTeamId: string;
    readonly billingPlanId: string;
    readonly provider: ProviderId;
    readonly image: string;
  },
  requestedVm: CloudVmRow,
  operation: string,
  message: string,
) {
  return repo.recordUsageEvent({
    userId: input.userId,
    billingTeamId: input.billingTeamId,
    billingPlanId: input.billingPlanId,
    vmId: requestedVm.id,
    eventType: "vm.create.failed",
    provider: input.provider,
    imageId: input.image,
    metadata: { operation, message },
  });
}

function creditUsageEvent(
  vm: CloudVmRow,
  eventType: string,
  reservation: Exclude<VmCreateCreditReservation, { readonly kind: "none" }>,
) {
  return {
    userId: vm.userId,
    billingTeamId: vm.billingTeamId,
    billingPlanId: vm.billingPlanId,
    vmId: vm.id,
    eventType,
    provider: vm.provider,
    imageId: vm.imageId,
    metadata: {
      itemId: reservation.itemId,
      amount: reservation.amount,
      customerType: reservation.customerType,
      customerIdSet: !!reservation.customerId,
    },
  };
}

function seedInitialCreateCredits(
  billing: VmBillingGatewayShape,
  repo: VmRepositoryShape,
  input: {
    readonly userId: string;
    readonly billingCustomerType: BillingCustomerType;
    readonly billingTeamId: string;
    readonly billingPlanId: string;
    readonly provider: ProviderId;
  },
  vm: CloudVmRow,
) {
  return Effect.gen(function* () {
    const grant = yield* Effect.try({
      try: () => billing.resolveInitialCreateCreditGrant(input),
      catch: (cause) => new VmBillingError({ operation: "resolveInitialCreateCreditGrant", cause }),
    });
    if (grant.kind === "none") return;

    const claim = yield* repo.claimBillingGrant({
      billingCustomerType: grant.customerType,
      billingCustomerId: grant.customerId,
      billingPlanId: input.billingPlanId,
      itemId: grant.itemId,
      amount: grant.amount,
      reason: grant.reason,
    });
    if (claim.kind !== "inserted") return;

    yield* billing.applyCreateCreditGrant(grant).pipe(
      Effect.tapError(() =>
        repo.deleteBillingGrant(claim.grantId).pipe(Effect.catchAll(() => Effect.void))
      ),
    );
    yield* repo.markBillingGrantApplied(claim.grantId).pipe(Effect.catchAll(() => Effect.void));
    yield* recordGrantEvent(repo, vm, "vm.create.credit.granted", grant)
      .pipe(Effect.catchAll(() => Effect.void));
  });
}

function recordGrantEvent(
  repo: VmRepositoryShape,
  vm: CloudVmRow,
  eventType: string,
  grant: VmCreateCreditGrant,
) {
  if (grant.kind === "none") return Effect.void;
  return repo.recordUsageEvent({
    userId: vm.userId,
    billingTeamId: vm.billingTeamId,
    billingPlanId: vm.billingPlanId,
    vmId: vm.id,
    eventType,
    provider: vm.provider,
    imageId: vm.imageId,
    metadata: {
      itemId: grant.itemId,
      amount: grant.amount,
      reason: grant.reason,
      customerType: grant.customerType,
      customerIdSet: !!grant.customerId,
    },
  });
}

function refundCredit(
  billing: VmBillingGatewayShape,
  repo: VmRepositoryShape,
  vm: CloudVmRow,
  reservation: VmCreateCreditReservation,
) {
  return billing.refundCreate(reservation).pipe(
    Effect.andThen(recordCreditEvent(repo, vm, "vm.create.credit.refunded", reservation)),
    Effect.catchAll(() => Effect.void),
  );
}

function recordEndpointLease(
  vm: CloudVmRow,
  input: {
    readonly kind: CloudVmLeaseKind;
    readonly token: string;
    readonly expiresAt: Date;
    readonly providerIdentityHandle?: string;
    readonly sessionId?: string;
    readonly transport?: string;
    readonly metadata?: Record<string, unknown>;
  },
) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    yield* repo.recordLease({
      vmId: vm.id,
      userId: vm.userId,
      kind: input.kind,
      tokenHash: hashToken(input.token),
      expiresAt: input.expiresAt,
      providerIdentityHandle: input.providerIdentityHandle,
      sessionId: input.sessionId,
      transport: input.transport,
      metadata: input.metadata,
    });
  });
}

function revokeEndpointIdentity(provider: ProviderId, endpoint: AttachEndpoint | SSHEndpoint) {
  return Effect.gen(function* () {
    if (endpoint.transport !== "ssh" || !endpoint.identityHandle) return;
    const providers = yield* VmProviderGateway;
    yield* providers.revokeSSHIdentity(provider, endpoint.identityHandle).pipe(Effect.catchAll(() => Effect.void));
  });
}

function vmEntryFromRow(row: CloudVmRow): VmEntry {
  if (!row.providerVmId) {
    throw new Error(`VM row has no provider VM id: ${row.id}`);
  }
  const metadata = row.providerMetadata ?? {};
  const addressIpv4 = metadata["networkIpv4"];
  const addressIpv6 = metadata["networkIpv6"];
  return {
    providerVmId: row.providerVmId,
    provider: row.provider,
    image: row.imageId,
    imageVersion: row.imageVersion,
    status: row.status,
    createdAt: row.createdAt.getTime(),
    displayName: row.displayName ?? null,
    slug: row.slug ?? null,
    addressIpv4: typeof addressIpv4 === "string" && addressIpv4 ? addressIpv4 : null,
    addressIpv6: typeof addressIpv6 === "string" && addressIpv6 ? addressIpv6 : null,
  };
}

function baseVmEntryFromRows(
  base: CloudVmBaseRow,
  generation: CloudVmBaseGenerationRow,
  row: CloudVmRow,
  retainedProviderVmId: string | null,
): BaseVmEntry {
  return {
    ...vmEntryFromRow(row),
    baseId: base.id,
    baseName: base.name,
    generation: generation.generation,
    retainedProviderVmId,
  };
}

function sshCredentialToken(endpoint: SSHEndpoint): string {
  return endpoint.credential.kind === "password"
    ? endpoint.credential.value
    : endpoint.credential.privateKeyPem;
}

function hashToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

function errorMessage(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause);
}
