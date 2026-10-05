import { compileNetworkPolicy, storedNetworkPolicy, type NetworkPolicy, type NetworkRulePlan } from "./networkPolicy";
import { createHash, randomUUID } from "node:crypto";
import {
  applyVmResourceUsage,
  VM_RESOURCE_USAGE_KEY,
  VM_RESOURCE_USAGE_MAX_AGE_MS,
  shouldReadVmResourceStatsDirectly,
} from "./resourceUsage";
import * as Cause from "effect/Cause";
import * as Effect from "effect/Effect";
import * as Either from "effect/Either";
import * as Exit from "effect/Exit";
import * as Fiber from "effect/Fiber";
import * as ManagedRuntime from "effect/ManagedRuntime";
import * as Option from "effect/Option";
import { eq } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { cloudVms } from "../../db/schema";
import type { CreateOptions } from "./drivers/types";
import * as Layer from "effect/Layer";
import type {
  AttachEndpoint,
  AttachOptions,
  ExecResult,
  VMFileContents,
  VMFileEntry,
  VMFileStat,
  VMFirewallEndpoint,
  VMFirewallRule,
  VMFirewallRuleInput,
  ProviderId,
  SnapshotRef,
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
  type VmComputeResources,
  type VmResourceReservation,
  type VmResourceResizePending,
  type VmResourceResizeUnconfirmed,
} from "./machineSpec";
import {
  VmBillingError,
  VmMemoryPlanError,
  VmAccountDeletionIdentityRevocationError,
  VmAttachTransportUnsupportedError,
  VmCreateDisabledError,
  VmCreateFailedError,
  VmCreateInProgressError,
  VmDatabaseError,
  VmFreeAccessExpiredError,
  VmFileNotFoundError,
  VmFirewallRuleNotFoundError,
  VmFirewallRuleInvalidError,
  VmFirewallRuleLimitError,
  VmModelPlaneError,
  VmNotFoundError,
  VmResizeInvalidError,
  VmResizePlanLimitError,
  VmResizeInProgressError,
  VmOperationUnsupportedError,
  VmProviderOperationError,
  VmPrivateNetworkUnavailableError,
  VmSnapshotNotFoundError,
  VmSnapshotInProgressError,
  VmSnapshotIdempotencyConflictError,
  VmUsageLimitExceededError,
  VmGoShapeError,
  VM_MODEL_PLANE_FAILURE_CODES,
  isVmCreateCreditsInsufficientError,
  isVmLimitExceededError,
  isVmResourcePoolExceededError,
  isVmModelPlaneError,
  type VmWorkflowError,
} from "./errors";
import {
  isPaidVmPlan,
  isVmFreeAccessExpired,
  maxActiveVmsForPlan,
  maxDiskMbForPlan,
  maxMemoryMbForPlan,
  maxVcpusForPlan,
  legacyPoolReservationForPlan,
  resourcePoolPolicyForPlan,
  VM_PLAN_MEMORY_MB_PER_VCPU,
  vmFreeAccessWindowDays,
} from "./entitlements";
import { getGoVmUsage, GO_INCLUDED_VM_HOURS } from "./goUsage";
import { GO_PAUSE_INTENT_KEY, pauseGoVm } from "./goPause";
import { networkSlugForTeam, networkSlugForUser, privateNetworkUnavailableReason, resolveOwnerNetwork } from "./privateNetwork";
import { listTeamMemberIdsWithTimeout, type VmTeamDirectory } from "./teamDirectory";
import { detachNetworkTunnels } from "./teamNetworkAccess";
import { isProviderDeletionConfirmed, isProviderIdentityNotFoundError, isProviderNotFoundError } from "./providerErrors";
import { VmProviderGateway, VmProviderGatewayLive, type VmProviderGatewayShape } from "./providerGateway";
import { isProviderCreateCleanupError } from "./drivers/providerCreateCleanup";
import {
  VM_CREATE_ABANDONED_AFTER_MS,
  VM_PREVIEW_LEASE_RETENTION_MS,
} from "./operationTimeouts";
import { withVmProductAnalytics, type VmDestroySource } from "./productAnalytics";
import {
  CREATE_CLEANUP_PROVIDER_VM_ID_KEY,
  OBSERVED_DESTROY_CLEANUP_METADATA_KEY,
  PROVIDER_CREATE_CLEANUP_PENDING_FAILURE_CODE,
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
  type VmObservedDestroyCleanup,
  type VmObservedDestroyCleanupCandidate,
  type VmObservedDestroyCleanupStep,
  type VmResizeReservation,
  type VmUsageEventInput,
} from "./repository";
import { measureVmEffect, type VmTimingSink } from "./timings";
import { guestPromptInstallCommand, vmPromptIdentity } from "./guestPrompt";
import { vmAgentUpdatesFromRow, type VmAgentUpdatesSetting } from "./agentUpdates";
import { guestAgentUpdatesCommand } from "./guestAgentUpdates";

export {
  homeVolumeNameForUser,
  homeVolumeTemplateForUser,
  isMachineOwnedHomeVolumeName,
} from "./volumeNaming";
export {
  deletePrivateNetworkingForAccountDeletion,
  enrollVmTunnel,
  attachVmTunnelNetwork,
  detachVmTunnelNetwork,
  isWireGuardPublicKey,
  listVmTunnels,
  listVmAccessGrants,
  networkSlugForUser,
  networkSlugForTeam,
  readVmTunnel,
  reapStaleVmTunnels,
  renameVmAccessGrant,
  resolveOwnerNetwork,
  revokeVmAccessGrant,
  revokeVmTunnel,
  rotateVmTunnelKey,
  tunnelSlugForDevice,
} from "./privateNetwork";
export type { VmTunnelDescriptor, VmTunnelReapResult } from "./privateNetwork";
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
  /**
   * The account that made the machine. A team's list is scoped by owner team,
   * not by member, so without this a shared account is a pile of generated
   * names with no way to tell whose is whose. It is an opaque id; the name to
   * show for it comes from `services/vms/creators.ts`. Never null:
   * `cloud_vms.user_id` is NOT NULL and has been there since the table was
   * created (20260425062520_keen_kronos).
   */
  readonly createdByUserId: string;
  /**
   * The team that owns the machine, or the creator's own id for a personal
   * machine. Creator names resolve only for current members of this team.
   */
  readonly ownerTeamId: string;
  /** The machine's address on its owner's private network, when it has one. */
  readonly addressIpv4: string | null;
  readonly addressIpv6: string | null;
  /**
   * The image's cmux-tui attach contract (`"snapshot-v2"`: baked daemon with
   * the trusted private-network listener). With a private address, it is
   * everything a client needs to dial the daemon, so the create response can
   * carry it and New Machine skips the separate attach request.
   */
  readonly cmuxTuiContract: string | null;
  /** Coding agents: "image" keeps the baked pins, "latest" updates them on attach. */
  readonly agentUpdates: VmAgentUpdatesSetting;
  /**
   * The machine's recorded share of the shared vCPU/memory pool, or null for a
   * legacy row without a valid reservation marker (the pool counts those at
   * the plan's default machine size).
   */
  readonly resourceReservation?: VmComputeResources | null;
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
const MODEL_PLANE_REVOKE_TIMEOUT = "5 seconds";
const ACTIVE_IDENTITY_REVOKE_HOT_PATH_LIMIT = 8;
const ACCOUNT_DELETION_IDENTITY_REVOKE_BATCH = 8;
const VM_STATUS_RECONCILE_BATCH_LIMIT = 200;
const CREATE_CLEANUP_CONCURRENCY = 4;
const CREATE_CLEANUP_PROVIDER_TIMEOUT = "15 seconds";
const CREATE_CLEANUP_LEASE_MS = 60 * 1000;
const CREATE_CLEANUP_BACKOFF_BASE_MS = 5 * 1000;
const CREATE_CLEANUP_BACKOFF_MAX_MS = 15 * 60 * 1000;
const CREATE_CLEANUP_BATCH_LIMIT = 20;
const OBSERVED_DESTROY_CLEANUP_BATCH_LIMIT = 20;
const OBSERVED_DESTROY_CLEANUP_TIMEOUT = "15 seconds";
const ABANDONED_CREATE_BATCH_LIMIT = 20;
const ABANDONED_CREATE_CONCURRENCY = 4;
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
const PREVIEW_LEASE_PRUNE_BATCH = 5_000;

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

/** A VM control-plane program: typed failures, live services provided by {@link vmWorkflowRuntime}. */
export type VmWorkflowProgram<A> = Effect.Effect<
  A,
  VmWorkflowError,
  VmRepository | VmProviderGateway | VmBillingGateway
>;

/**
 * One process-wide runtime for {@link VmWorkflowLive}. The layer is built on
 * first use and shared by every request, so routes stop re-providing services
 * per call and every program runs with the same services and fiber refs.
 */
export const vmWorkflowRuntime = ManagedRuntime.make(VmWorkflowLive);

/**
 * Run a program to its `Exit`. Routes branch on the exit: a typed failure maps
 * to an HTTP response through the responder table in `routeHelpers`, a defect
 * is a bug and propagates as a thrown error.
 */
export function runVmWorkflowExit<A>(program: VmWorkflowProgram<A>): Promise<Exit.Exit<A, VmWorkflowError>> {
  return vmWorkflowRuntime.runPromiseExit(program);
}

/**
 * Promise adapter for callers outside the route layer (cron, account
 * deletion, tests). Throws the typed workflow error itself, never a
 * FiberFailure, so `catch` blocks match on `_tag` directly.
 */
export async function runVmWorkflow<A>(program: VmWorkflowProgram<A>): Promise<A> {
  const exit = await runVmWorkflowExit(program);
  if (Exit.isSuccess(exit)) return exit.value;
  throw vmWorkflowExitError(exit.cause);
}

/** The value a failed program throws: its typed failure, or the squashed defect. */
export function vmWorkflowExitError(cause: Cause.Cause<VmWorkflowError>): unknown {
  const failure = Cause.failureOption(cause);
  return Option.isSome(failure) ? failure.value : Cause.squash(cause);
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
  /** Revokes coderouter tokens when this read is what finds the machine gone. */
  readonly modelPlane?: VmModelPlaneRevoker;
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
      const dbStatus = observedDbStatus(providerStatus);
      if (dbStatus !== vm.status) {
        const didUpdate = yield* applyObservedProviderStatus(repo, providers, vm, {
          providerVmId,
          providerStatus,
          usageEventSource: "provider_status_read",
          modelPlane: input.modelPlane,
        });
        if (didUpdate) return vmEntryFromRow({ ...vm, status: dbStatus, updatedAt: new Date() });
      }
    }
    return vmEntryFromRow(vm);
  });
}

/** Sets or clears the label and refreshes the guest prompt. Routing ids stay stable. */
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
    // Read the committed row so a concurrent rename and attach carry the
    // database's revision, not the request's start time.
    const updated = yield* requireUserVm(input);
    if (updated.status === "running") {
      const providers = yield* VmProviderGateway;
      yield* providers.exec(updated.provider, input.providerVmId, guestPromptInstallCommand(vmPromptIdentity(updated)), {
        timeoutMs: 10_000,
        providerMetadata: updated.providerMetadata,
      }).pipe(
        Effect.flatMap((result) => result.exitCode === 0 ? Effect.void : Effect.fail(new Error(`prompt update exited ${result.exitCode}`))),
        // A saved rename must remain available when a guest is unreachable.
        // The next attach repairs it; paused machines are never woken here.
        Effect.catchAll((error) => Effect.logWarning("Cloud prompt update deferred until attach", { vmId: updated.id, error })),
      );
    }
    return vmEntryFromRow(updated);
  });
}

/**
 * Detach tunnels from team networks their owner no longer belongs to. Freestyle
 * is the record of both the team networks (found by slug) and their attached
 * tunnels; candidate teams come from the live machines billed to them.
 *
 * This is the backstop. The Stack webhook (`app/api/webhooks/stack`) detaches
 * a removed member at once; this pass catches missed or failed deliveries.
 */
function reconcileTeamTunnelAttachments(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  directory: VmTeamDirectory,
  timeoutMs = 3000,
  pageSize = 50,
  budgetMs = 60_000,
  now: () => number = Date.now,
): Effect.Effect<void, never> {
  const reconcileTeam = (owner: { readonly teamId: string; readonly provider: ProviderId }) =>
    Effect.gen(function* () {
      const network = yield* providers.getNetwork!(owner.provider, networkSlugForTeam(owner.teamId));
      if (!network) return;
      const membersResult = yield* listTeamMemberIdsWithTimeout(directory, owner.teamId, timeoutMs);
      if ("error" in membersResult) return;
      const members = membersResult.memberIds ? new Set(membersResult.memberIds) : null;
      // Tunnels with no row are skipped inside detachNetworkTunnels; failed
      // detaches are retried by the next run.
      yield* detachNetworkTunnels({
        repo: { findTunnelsByProviderTunnelIds: repo.findTunnelsByProviderTunnelIds! },
        providers: { listNetworkTunnelIds: providers.listNetworkTunnelIds!, detachTunnelNetwork: providers.detachTunnelNetwork! },
        provider: owner.provider,
        networkId: network.id,
        select: (row) => members === null || row.revokedAt !== null || !members.has(row.userId),
      });
    }).pipe(Effect.catchAll(() => Effect.void));
  return Effect.gen(function* () {
    const startedAt = now();
    let after: { teamId: string; provider: ProviderId } | undefined;
    for (let pageNumber = 0; pageNumber < 100; pageNumber += 1) {
      if (now() - startedAt >= budgetMs) {
        yield* Effect.logInfo("Cloud team tunnel reconciliation budget exhausted", {
          skippedTeamsInPage: 0,
          remainingPagesUnread: true,
        });
        break;
      }
      const page = yield* repo.listActiveTeamVmOwners!({ limit: pageSize, after }).pipe(Effect.catchAll(() => Effect.succeed([])));
      if (page.length === 0) break;
      for (const [index, owner] of page.entries()) {
        if (now() - startedAt >= budgetMs) {
          // Count only fetched teams; further pages remain unread for the next run.
          yield* Effect.logInfo("Cloud team tunnel reconciliation budget exhausted", {
            skippedTeamsInPage: page.length - index,
            remainingPagesUnread: page.length === pageSize,
          });
          return;
        }
        yield* reconcileTeam(owner);
      }
      if (page.length < pageSize) break;
      after = page[page.length - 1];
      if (!after) break;
    }
  }).pipe(Effect.catchAllCause(() => Effect.void));
}

export function reconcileVmProviderStatuses(input: {
  readonly limit?: number;
  readonly teamDirectory?: VmTeamDirectory;
  readonly directoryTimeoutMs?: number;
  readonly teamNetworkPageSize?: number;
  readonly teamReconcileBudgetMs?: number;
  readonly now?: () => number;
  /** Revokes coderouter tokens for machines the provider reports gone. */
  readonly modelPlane?: VmModelPlaneRevoker;
} = {}): Effect.Effect<VmProviderStatusReconcileResult, VmWorkflowError, VmRepository | VmProviderGateway> {
  return Effect.gen(function* () {
    const providers = yield* VmProviderGateway;
    const repo = yield* VmRepository;
    yield* reconcileAbandonedProvisioningCreates(repo, {
      before: new Date((input.now?.() ?? Date.now()) - VM_CREATE_ABANDONED_AFTER_MS),
      limit: Math.min(boundedVmStatusReconcileLimit(input.limit), ABANDONED_CREATE_BATCH_LIMIT),
      modelPlane: input.modelPlane,
    });
    // Legacy resource claims are repaired by this background cron. Keeping
    // provider fanout here removes migration work from user-facing creates.
    yield* reconcileLegacyResourceReservations(repo, providers, {
      limit: LEGACY_RESOURCE_RECONCILE_BATCH_LIMIT,
    });
    yield* reconcilePendingCreateCleanups(repo, providers, {
      // At four concurrent 15-second provider calls, twenty rows fit inside
      // the five-minute cron budget while leaving time for status probes.
      limit: Math.min(boundedVmStatusReconcileLimit(input.limit), CREATE_CLEANUP_BATCH_LIMIT),
    });
    yield* reconcileObservedDestroyCleanups(
      repo,
      providers,
      input.modelPlane,
      boundedVmStatusReconcileLimit(input.limit),
    );
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
      (vm) => reconcileObservedProviderStatus(repo, providers, getStatus, vm, "provider_status_cron", input.modelPlane),
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
        // Freestyle returns 429 when several VPC rule heals run together.
        // One owner at a time keeps healing bounded.
        { concurrency: 1, discard: true },
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
    if (
      input.teamDirectory && repo.listActiveTeamVmOwners && repo.findTunnelsByProviderTunnelIds &&
      providers.getNetwork && providers.listNetworkTunnelIds && providers.detachTunnelNetwork
    ) {
      yield* reconcileTeamTunnelAttachments(
        repo, providers, input.teamDirectory, input.directoryTimeoutMs,
        input.teamNetworkPageSize, input.teamReconcileBudgetMs, input.now,
      );
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
 * A provider allocation retained after a failed create is not a normal VM row:
 * its public provider id is intentionally absent until deletion is confirmed.
 * Reconcile those ids before ordinary status probing so a failed provider
 * cleanup cannot remain reserved forever or block the next Base generation.
 */
function reconcilePendingCreateCleanups(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  input: { readonly limit: number },
): Effect.Effect<void, never> {
  const listCandidates = repo.pendingCreateCleanupCandidates;
  const claimCleanup = repo.claimCreateCleanup;
  const deferCleanup = repo.deferCreateCleanup;
  const resolveCleanup = repo.resolveCreateCleanup;
  if (!listCandidates || !claimCleanup || !deferCleanup || !resolveCleanup) return Effect.void;
  return Effect.gen(function* () {
    const candidates = yield* listCandidates({ limit: input.limit }).pipe(
      Effect.catchAll(() => Effect.succeed([] as CloudVmRow[])),
    );
    yield* Effect.forEach(
      candidates,
      (vm) => {
        // The row can outlive its provider driver. Never pass a retired
        // provider or a coderouter/model-plane failure to the cleanup worker.
        if (isRetiredProviderRow(vm) || vm.failureCode !== PROVIDER_CREATE_CLEANUP_PENDING_FAILURE_CODE) {
          return Effect.void;
        }
        const rawProviderVmId = vm.providerMetadata?.[CREATE_CLEANUP_PROVIDER_VM_ID_KEY];
        if (typeof rawProviderVmId !== "string" || rawProviderVmId.trim().length === 0) return Effect.void;
        const providerVmId = rawProviderVmId.trim();
        const leaseId = randomUUID();
        const now = new Date();
        const leaseExpiresAt = new Date(now.getTime() + CREATE_CLEANUP_LEASE_MS);
        return claimCleanup({
          id: vm.id,
          providerVmId,
          leaseId,
          now,
          leaseExpiresAt,
        }).pipe(
          Effect.flatMap((claim) => {
            if (!claim) return Effect.void;
            const destroy = providers.destroy(vm.provider, providerVmId).pipe(
              Effect.timeoutFail({
                duration: CREATE_CLEANUP_PROVIDER_TIMEOUT,
                onTimeout: () => new Error("provider cleanup deadline"),
              }),
              Effect.catchAll((error) => isProviderDeletionConfirmed(error)
                ? Effect.succeed("confirmed" as const)
                : Effect.fail(error)),
            );
            return destroy.pipe(
              Effect.flatMap(() => resolveCleanup({ id: vm.id, providerVmId, leaseId })),
              Effect.asVoid,
              Effect.catchAll(() => {
                const backoff = Math.min(
                  CREATE_CLEANUP_BACKOFF_MAX_MS,
                  CREATE_CLEANUP_BACKOFF_BASE_MS * 2 ** Math.min(20, Math.max(0, claim.attempt - 1)),
                );
                return deferCleanup({
                  id: vm.id,
                  providerVmId,
                  leaseId,
                  nextAttemptAt: new Date(Date.now() + backoff),
                  now: new Date(),
                }).pipe(Effect.asVoid, Effect.catchAll(() => Effect.void));
              }),
            );
          }),
          Effect.catchAll(() => Effect.void),
        );
      },
      { concurrency: CREATE_CLEANUP_CONCURRENCY, discard: true },
    );
  });
}

/**
 * Reclaims a create row that never received a provider id. The repository
 * performs the compare-and-set transition and Base rollback in one transaction;
 * this layer only records the normal failure event for rows it actually won.
 */
function reconcileAbandonedProvisioningCreates(
  repo: VmRepositoryShape,
  input: {
    readonly before: Date;
    readonly limit: number;
    readonly modelPlane?: VmModelPlaneRevoker;
  },
): Effect.Effect<void, never> {
  const listCandidates = repo.abandonedProvisioningCandidates;
  const markAbandoned = repo.markCreateAbandoned;
  if (!listCandidates || !markAbandoned) return Effect.void;
  return Effect.gen(function* () {
    const candidates = yield* listCandidates({ before: input.before, limit: input.limit }).pipe(
      Effect.catchAll(() => Effect.succeed([] as CloudVmRow[])),
    );
    yield* Effect.forEach(candidates, (candidate) => Effect.gen(function* () {
      const now = new Date();
      const abandoned = yield* markAbandoned({
        id: candidate.id,
        before: input.before,
        now,
        code: "create_abandoned",
        message: "Cloud VM create exceeded the provider deadline without an allocation.",
      }).pipe(Effect.catchAll(() => Effect.succeed(null)));
      if (!abandoned) return;
      const vm = abandoned.vm;
      yield* revokeModelPlane(input.modelPlane, vm.id);
      yield* repo.recordUsageEvent({
        userId: vm.userId,
        billingTeamId: vm.billingTeamId,
        billingPlanId: vm.billingPlanId,
        vmId: vm.id,
        eventType: abandoned.isBase ? "vm.base.create.failed" : "vm.create.failed",
        provider: vm.provider,
        imageId: vm.imageId,
        metadata: {
          operation: "create_abandoned",
          source: "vm_reconcile",
          ageMinutes: Math.max(0, Math.round((now.getTime() - vm.createdAt.getTime()) / 60_000)),
          thresholdMinutes: Math.ceil(VM_CREATE_ABANDONED_AFTER_MS / 60_000),
        },
      }).pipe(Effect.catchAll(() => Effect.void));
    }), { concurrency: ABANDONED_CREATE_CONCURRENCY, discard: true });
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

type PendingObservedDestroyCleanup = {
  readonly modelPlane?: true;
  readonly homeVolume?: string;
};

function observedDestroyCleanupFromMetadata(
  metadata: Readonly<Record<string, unknown>> | null,
): PendingObservedDestroyCleanup | null {
  const raw = metadata?.[OBSERVED_DESTROY_CLEANUP_METADATA_KEY];
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const marker = raw as Record<string, unknown>;
  const modelPlane = marker.modelPlane === true ? true : undefined;
  const homeVolume = marker.homeVolume;
  const normalizedHomeVolume = typeof homeVolume === "string" && homeVolume.length > 0
    ? homeVolume
    : undefined;
  if (!modelPlane && !normalizedHomeVolume) return null;
  return {
    ...(modelPlane ? { modelPlane } : {}),
    ...(normalizedHomeVolume ? { homeVolume: normalizedHomeVolume } : {}),
  };
}

function completeObservedDestroyCleanupStep(
  repo: VmRepositoryShape,
  vmId: string,
  step: VmObservedDestroyCleanupStep,
): Effect.Effect<void, never> {
  const complete = repo.completeObservedDestroyCleanup;
  if (!complete) return Effect.void;
  return complete({ id: vmId, step }).pipe(
    Effect.asVoid,
    Effect.catchAll((err) =>
      Effect.sync(() => {
        console.error(`[vm] could not acknowledge observed-destroy ${step} cleanup for ${vmId}`, errorMessage(err));
      })
    ),
  );
}

function deferObservedDestroyCleanupStep(
  repo: VmRepositoryShape,
  vmId: string,
  step: VmObservedDestroyCleanupStep,
): Effect.Effect<void, never> {
  const defer = repo.deferObservedDestroyCleanup;
  if (!defer) return Effect.void;
  return defer({ id: vmId, step }).pipe(
    Effect.asVoid,
    Effect.catchAll(() => Effect.void),
  );
}

/**
 * Drain transactionally-recorded cleanup after a provider-observed destroy.
 * Both side effects are idempotent, so a crash after the side effect but
 * before its acknowledgement is safe: the terminal-row reconciler repeats it.
 */
function drainObservedDestroyCleanup(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  modelPlane: VmModelPlaneRevoker | undefined,
  vm: VmObservedDestroyCleanupCandidate,
  cleanup: PendingObservedDestroyCleanup,
): Effect.Effect<void, never> {
  return Effect.gen(function* () {
    if (cleanup.modelPlane) {
      const revoked = modelPlane
        ? yield* attemptModelPlaneRevoke(modelPlane, vm.id)
        : false;
      if (revoked) yield* completeObservedDestroyCleanupStep(repo, vm.id, "modelPlane");
      else yield* deferObservedDestroyCleanupStep(repo, vm.id, "modelPlane");
    }
    if (cleanup.homeVolume && providers.deleteHomeVolume) {
      const deleted = yield* providers.deleteHomeVolume(vm.provider, cleanup.homeVolume).pipe(
        Effect.timeoutFail({
          duration: OBSERVED_DESTROY_CLEANUP_TIMEOUT,
          onTimeout: () => new Error("observed-destroy volume cleanup deadline"),
        }),
        Effect.as(true),
        Effect.catchAll((err) => isProviderDeletionConfirmed(err)
          ? Effect.succeed(true)
          : Effect.sync(() => {
            console.error(
              `[vm] observed-destroy home volume cleanup failed for ${vm.id} (${cleanup.homeVolume})`,
              errorMessage(err.cause),
            );
            return false;
          })
        ),
      );
      if (deleted) yield* completeObservedDestroyCleanupStep(repo, vm.id, "homeVolume");
      else yield* deferObservedDestroyCleanupStep(repo, vm.id, "homeVolume");
    } else if (cleanup.homeVolume) {
      yield* deferObservedDestroyCleanupStep(repo, vm.id, "homeVolume");
    }
  });
}

function reconcileObservedDestroyCleanups(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  modelPlane: VmModelPlaneRevoker | undefined,
  limit: number,
): Effect.Effect<void, never> {
  const listCandidates = repo.observedDestroyCleanupCandidates;
  if (!listCandidates) return Effect.void;
  return Effect.gen(function* () {
    const candidates = yield* listCandidates({
      limit: Math.min(limit, OBSERVED_DESTROY_CLEANUP_BATCH_LIMIT),
    }).pipe(Effect.catchAll(() => Effect.succeed([] as VmObservedDestroyCleanupCandidate[])));
    yield* Effect.forEach(candidates, (vm) => {
      const cleanup = observedDestroyCleanupFromMetadata(vm.providerMetadata);
      return cleanup
        ? drainObservedDestroyCleanup(repo, providers, modelPlane, vm, cleanup)
        : Effect.void;
    }, { concurrency: 4, discard: true });
  });
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

function isFailedVmCreate(vm: Pick<CloudVmRow, "status" | "failureCode">): boolean {
  return vm.status === "failed" || vm.failureCode === PROVIDER_CREATE_CLEANUP_PENDING_FAILURE_CODE;
}

/** Check the copied or requested shape before provisioning side effects. */
function requireMemoryPlan(planId: string, memoryMb: number | null) {
  const maxMemoryMb = maxMemoryMbForPlan(planId);
  if (memoryMb === null ? maxMemoryMb < 65536 : memoryMb > maxMemoryMb) {
    return Effect.fail(new VmMemoryPlanError({ planId, memoryMb, maxMemoryMb }));
  }
  return Effect.void;
}

/**
 * A machine larger than the caller's plan (created before a plan change, or
 * on a plan the caller left) stays listed and deletable, but access verbs
 * refuse it. CPU above the plan counts as the ladder memory that carries it.
 * Rows without recorded resources are left to the create-time checks.
 */
function requireMachineFitsPlan(planId: string, metadata: Record<string, unknown>) {
  if (!hasVmResourceReservationMetadata(metadata)) return Effect.void;
  const shape = vmResourceReservationFromMetadata(metadata);
  const maxMemoryMb = maxMemoryMbForPlan(planId);
  if (shape.memoryMb <= maxMemoryMb && shape.vcpus <= maxVcpusForPlan(planId)) return Effect.void;
  const memoryMb = Math.max(shape.memoryMb, shape.vcpus * VM_PLAN_MEMORY_MB_PER_VCPU);
  return Effect.fail(new VmMemoryPlanError({ planId, memoryMb, maxMemoryMb }));
}

function requestedCreateMemory(input: { memoryMb?: number; imageSize?: { memoryMb: number }; resourceReservation?: { memoryMb: number } }) {
  return Math.max(input.memoryMb ?? 0, input.imageSize?.memoryMb ?? 0, input.resourceReservation?.memoryMb ?? 0);
}

const GO_VM_RESERVATION = { vcpus: 2, memoryMb: 4096, diskMb: 16384 } as const;
function requireGoShape(planId: string | null | undefined, shape: VmResourceReservation | null) {
  return planId === "go" && (!shape || shape.vcpus !== GO_VM_RESERVATION.vcpus || shape.memoryMb !== GO_VM_RESERVATION.memoryMb || shape.diskMb !== GO_VM_RESERVATION.diskMb)
    ? Effect.fail(new VmGoShapeError()) : Effect.void;
}

function requireGoCreate(input: Pick<Parameters<typeof createVm>[0], "billingPlanId" | "userId" | "imageSize" | "resourceReservation">) {
  return Effect.gen(function* () {
    if (input.billingPlanId === "go") {
      yield* requireGoShape("go", input.resourceReservation ?? (input.imageSize ? {
        vcpus: input.imageSize.cpu, memoryMb: input.imageSize.memoryMb, diskMb: input.imageSize.storageMb,
      } : null));
      const usage = yield* Effect.tryPromise({
        try: () => getGoVmUsage(input.userId),
        catch: (cause) => new VmBillingError({ operation: "go_runtime", cause }),
      });
      if (usage && usage.remainingSeconds <= 0) {
        return yield* Effect.fail(new VmUsageLimitExceededError({ includedHours: GO_INCLUDED_VM_HOURS, usedHours: GO_INCLUDED_VM_HOURS }));
      }
      if (!usage) return yield* Effect.fail(new VmBillingError({ operation: "go_runtime", cause: "Go subscription is not active" }));
      return usage.remainingSeconds;
    }
  });
}

function requireGoMetadataShape(planId: string, metadata: Record<string, unknown>) {
  return requireGoShape(planId, hasVmResourceReservationMetadata(metadata) ? vmResourceReservationFromMetadata(metadata) : null);
}

type CreateVmInput = {
  readonly userId: string;
  readonly billingCustomerType: BillingCustomerType;
  readonly billingTeamId: string;
  readonly billingPlanId: string;
  readonly maxActiveVms: number | null;
  readonly provider: ProviderId;
  readonly image: string;
  readonly imageVersion?: string | null;
  readonly idempotencyKey?: string;
  /** Stored before provisioning so the first guest prompt already has its chosen name. */
  readonly displayName?: string | null;
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
  /**
   * Outbound network policy chosen at create. Absent: full Internet. Stored on
   * the row before the provider call and installed by the create itself, so a
   * restricted machine is never briefly open.
   */
  readonly networkPolicy?: NetworkPolicy;
  /** "latest" opts the machine into coding-agent updates on attach; absent keeps the image's pins. */
  readonly agentUpdates?: VmAgentUpdatesSetting;
  /** Set only when the requesting client routes team networks. */
  readonly teamDirectory?: VmTeamDirectory;
  readonly timing?: VmTimingSink;
  /**
   * Runs best-effort work after the response has been sent (the route passes
   * `runAfterResponse`). createVm uses it only for the `vm.created` ledger
   * row, which is written after the machine is already usable and whose
   * failure is already ignored. Without it the row is written inline.
   */
  readonly deferAfterResponse?: (work: Effect.Effect<void>) => void;
};

function createVmBeginInput(input: CreateVmInput): CreateVmInput & Pick<Parameters<VmRepositoryShape["beginCreate"]>[0], "resourcePool" | "resourcePoolPhase"> {
  if (!isPaidVmPlan(input.billingPlanId)) return input;
  return {
    ...input,
    // Reserve the logical CPU and memory profile when memoryMb is present,
    // while retaining the baked image's actual disk claim. A direct caller
    // may instead provide only imageSize; in that form the image is the
    // authoritative request.
    resourceReservation: input.resourceReservation ?? (input.billingPlanId === "go"
      ? GO_VM_RESERVATION
      : vmResourceReservationForCreate({ memoryMb: input.memoryMb, imageSize: input.imageSize })),
    // The machine draws from the billing scope's shared vCPU/memory pool.
    resourcePool: resourcePoolPolicyForPlan(input.billingPlanId, input.maxActiveVms),
    resourcePoolPhase: input.origin === "fork" ? "fork" : "create",
  };
}

export function createVm(input: CreateVmInput): Effect.Effect<VmEntry, VmWorkflowError, VmRepository | VmProviderGateway | VmBillingGateway> {
  return Effect.gen(function* () {
    const runtimeBudgetSeconds = yield* requireGoCreate(input);
    yield* requireMemoryPlan(input.billingPlanId, requestedCreateMemory(input as { memoryMb?: number; imageSize?: { memoryMb: number }; resourceReservation?: { memoryMb: number } }));
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const billing = yield* VmBillingGateway;
    // Record paid machine shapes for snapshot, fork, and resize recovery.
    const beginInput = createVmBeginInput(input);

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
            resolveOwnerNetwork({ userId: input.userId, provider: input.provider, billingTeamId: input.billingTeamId, teamDirectory: input.teamDirectory }),
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
      if (isFailedVmCreate(existing)) {
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

    const networkRules = yield* recordCreateNetworkPolicy(repo, providers, input, create.vm.id);

    const creditReservation = yield* reserveCreateCredit(billing, repo, input, create.vm);
    // The requested-events write depends on nothing below, so it runs beside
    // model-plane provisioning and the provider call instead of in front of
    // them (~20 ms off every create). It is joined before any failure event
    // and before success, so the ledger keeps requested -> failed/created
    // order and the row is written before the response leaves.
    const requestedEvents = yield* Effect.fork(
      recordCreateRequestedEvents(repo, input, create.vm, creditReservation),
    );
    const awaitRequestedEvents = Fiber.join(requestedEvents);

    const materials = yield* measureVmEffect(
      input.timing,
      "model_plane_provision",
      provisionModelPlane(input.modelPlane, create.vm.id),
    ).pipe(
      Effect.tapError((err) =>
        awaitRequestedEvents.pipe(Effect.andThen(Effect.all([
          refundCredit(billing, repo, create.vm, creditReservation),
          recordCreateFailureAfterMark(repo, repo.markCreateFailed({
            id: create.vm.id,
            code: VM_MODEL_PLANE_FAILURE_CODES[err.kind],
            message: errorMessage(err.cause),
          }), {
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
        ], { discard: true })), Effect.catchAll(() => Effect.void))
      ),
    );

    const handle = yield* measureVmEffect(
      input.timing,
      "provider_create",
      providers.create(input.provider, {
        image: input.image,
        // The display label is reserved with the row before provider work starts.
        // Passing it here makes the first guest prompt correct and removes the
        // blocking post-create rename on current backends.
        displayName: create.vm.displayName ?? create.vm.slug ?? undefined,
        promptIdentity: vmPromptIdentity(create.vm),
        providerMetadata: create.vm.providerMetadata,
        homeVolume: input.perMachineHome
          ? homeVolumeTemplateForUser(input.userId)
          : input.persistentHome
            ? homeVolumeNameForUser(input.userId)
            : undefined,
        runtimeBudgetSeconds,
        memoryMb: input.memoryMb,
        imageSize: input.imageSize ?? (input.billingPlanId === "go" ? { name: "sm", cpu: 2, memoryMb: 4096, storageMb: 16384 } : undefined),
        edgeRules: materials?.edgeRules,
        networkRules,
        network: { id: network.providerNetworkId, memberIngress: network.memberIngress },
      }),
    ).pipe(
      Effect.tapError((err) =>
        awaitRequestedEvents.pipe(Effect.andThen(Effect.all([
          revokeModelPlane(input.modelPlane, create.vm.id),
          refundCredit(billing, repo, create.vm, creditReservation),
          recordCreateFailureAfterMark(repo, repo.markCreateFailed({
            id: create.vm.id,
            // An unconfirmed rollback remains owned by this failed row. Keep
            // its provider id and make same-key retries wait for reconciliation
            // instead of allocating a duplicate machine.
            ...(isProviderCreateCleanupError(err.cause)
              ? { code: PROVIDER_CREATE_CLEANUP_PENDING_FAILURE_CODE, cleanupProviderVmId: err.cause.providerVmId }
              : { code: PROVIDER_CREATE_UNAVAILABLE_FAILURE_CODE }),
            message: isProviderCreateCleanupError(err.cause)
              ? `${errorMessage(err.cause.cause)}; cleanup: ${errorMessage(err.cause.cleanupCause)}`
              : errorMessage(err.cause),
          }), {
            userId: input.userId,
            billingTeamId: input.billingTeamId,
            billingPlanId: input.billingPlanId,
            vmId: create.vm.id,
            eventType: "vm.create.failed",
            provider: input.provider,
            imageId: input.image,
            metadata: { operation: err.operation, message: errorMessage(err.cause) },
          }),
        ], { discard: true })), Effect.catchAll(() => Effect.void))
      ),
    );

    yield* markCreateNetworkPolicyApplied(repo, input, create.vm.id);

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
          yield* awaitRequestedEvents;
          yield* rollbackProviderCreate(providers, input.provider, handle);
          yield* revokeModelPlane(input.modelPlane, create.vm.id);
          yield* refundCredit(billing, repo, create.vm, creditReservation);
          const markedFailed = yield* repo.markCreateFailed({
            id: create.vm.id,
            code: "database_finalize_failed",
            message: "Cloud VM state update failed.",
          }).pipe(Effect.catchAll(() => Effect.succeed(false)));
          if (markedFailed) {
            yield* recordCreateFailureEvent(
              repo,
              input,
              create.vm,
              "database_finalize_failed",
              errorMessage(err.cause),
            ).pipe(Effect.catchAll(() => Effect.void));
          }
          return yield* Effect.fail(err);
        }),
      ),
    );

    yield* awaitRequestedEvents;
    if (input.deferAfterResponse) {
      // The machine is usable once mark_running commits; the `vm.created`
      // ledger row is analytics and its failure was already ignored. Writing
      // it after the response keeps it off New Machine's critical path.
      input.deferAfterResponse(
        repo.recordUsageEvents(createSuccessUsageEvents(input, running)).pipe(Effect.catchAll(() => Effect.void)),
      );
    } else {
      yield* recordCreateSuccessEvents(repo, input, running);
    }
    yield* schedulePromptIdentityPush(providers, running, input.deferAfterResponse);
    // The create response carries the first connection, so openVmCmuxRemote
    // never runs for it; start the opted-in updater here, after the response.
    if (vmAgentUpdatesFromRow(running) === "latest") {
      yield* scheduleGuestAgentUpdates(providers, running, "latest", input.deferAfterResponse);
    }

    return vmEntryFromRow(running);
  });
}

/**
 * Publishes a new machine's prompt name (`cmux@<slug>`) into the guest once,
 * after the create response, with the same command a rename uses.
 *
 * The guest also pulls its name from https://reflection.cmux.internal/name
 * through the Freestyle edge, but the edge can only reach a public origin: a
 * private backend (every tailnet dev stack) never answers it, so dev machines
 * kept the baked `cmux@cmux`. This push is the path that works everywhere.
 * It is never on New Machine's critical path (NO-WORK INVARIANT in
 * drivers/freestyle.ts): it runs after the response when the route provides
 * the hook, detached otherwise, and a failure leaves reflection to publish
 * the name. cmux-prompt-sync redraws the prompt when the name file changes.
 */
function schedulePromptIdentityPush(
  providers: VmProviderGatewayShape,
  row: CloudVmRow,
  defer: ((work: Effect.Effect<void>) => void) | undefined,
): Effect.Effect<void> {
  const providerVmId = row.providerVmId;
  if (!providerVmId || row.status !== "running") return Effect.void;
  const push = Effect.suspend(() =>
    providers.exec(row.provider, providerVmId, guestPromptInstallCommand(vmPromptIdentity(row)), {
      timeoutMs: 10_000,
      providerMetadata: row.providerMetadata,
    })
  ).pipe(
    Effect.flatMap((result) => result.exitCode === 0 ? Effect.void : Effect.fail(new Error(`prompt push exited ${result.exitCode}`))),
    Effect.catchAllCause((cause) => Effect.logWarning("Cloud prompt push deferred to reflection", { vmId: row.id, cause })),
  );
  if (defer) {
    defer(push);
    return Effect.void;
  }
  return Effect.asVoid(Effect.forkDaemon(push));
}

/**
 * Tells the guest its coding-agent update setting and, for "latest", starts
 * the detached updater (services/vms/guestAgentUpdates.ts). The exec only
 * writes one file and forks, and it runs after the response, so neither
 * attach nor a setting change waits on the guest or GitHub. A
 * failure is logged and repaired by the next attach.
 */
function scheduleGuestAgentUpdates(
  providers: VmProviderGatewayShape,
  row: CloudVmRow,
  setting: VmAgentUpdatesSetting,
  defer: ((work: Effect.Effect<void>) => void) | undefined,
): Effect.Effect<void> {
  const providerVmId = row.providerVmId;
  if (!providerVmId) return Effect.void;
  const push = Effect.suspend(() =>
    providers.exec(row.provider, providerVmId, guestAgentUpdatesCommand(setting), {
      timeoutMs: 10_000,
      providerMetadata: row.providerMetadata,
    })
  ).pipe(
    Effect.flatMap((result) => result.exitCode === 0 ? Effect.void : Effect.fail(new Error(`agent updates exec exited ${result.exitCode}`))),
    Effect.catchAllCause((cause) => Effect.logWarning("Cloud agent updates deferred until next attach", { vmId: row.id, cause })),
  );
  if (defer) {
    defer(push);
    return Effect.void;
  }
  return Effect.asVoid(Effect.forkDaemon(push));
}

/**
 * Store a machine's coding-agent update setting. A running machine hears it
 * right away (best effort, after the response); a paused one is not woken and
 * picks it up on its next attach, which re-sends "latest" every time.
 */
export function setVmAgentUpdates(input: ExistingVmAccessInput & {
  readonly agentUpdates: VmAgentUpdatesSetting;
  readonly deferAfterResponse?: (work: Effect.Effect<void>) => void;
}): VmWorkflowProgram<VmEntry> {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const vm = yield* requireAccessibleUserVm(input);
    if (!repo.setAgentUpdates) {
      return yield* Effect.fail(new VmDatabaseError({ operation: "setAgentUpdates", cause: new Error("repository cannot store agent updates") }));
    }
    yield* repo.setAgentUpdates({ id: vm.id, agentUpdates: input.agentUpdates });
    const updated = { ...vm, agentUpdates: input.agentUpdates === "latest" ? "latest" as const : null, updatedAt: new Date() };
    if (updated.status === "running") {
      yield* scheduleGuestAgentUpdates(providers, updated, input.agentUpdates, input.deferAfterResponse);
    }
    return vmEntryFromRow(updated);
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
 * Best-effort token revocation for create rollback paths. Terminal destroy
 * transitions use attemptModelPlaneRevoke plus the durable cleanup marker
 * instead, so a failure there remains retryable.
 */
function revokeModelPlane(
  modelPlane: VmModelPlaneRevoker | undefined,
  cloudVmId: string,
): Effect.Effect<void> {
  if (!modelPlane) return Effect.void;
  return attemptModelPlaneRevoke(modelPlane, cloudVmId).pipe(Effect.asVoid);
}

function attemptModelPlaneRevoke(
  modelPlane: VmModelPlaneRevoker,
  cloudVmId: string,
): Effect.Effect<boolean, never> {
  return Effect.tryPromise(() => modelPlane.revoke(cloudVmId)).pipe(
    Effect.timeoutFail({
      duration: MODEL_PLANE_REVOKE_TIMEOUT,
      onTimeout: () => new Error("model-plane revoke deadline"),
    }),
    Effect.as(true),
    Effect.catchAll((err) =>
      Effect.sync(() => {
        console.error(`[vm] model-plane revoke failed for ${cloudVmId}`, errorMessage(err));
        return false;
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
  readonly imageSize?: CreateOptions["imageSize"];
  readonly baseName?: string;
  readonly modelPlane?: VmModelPlaneProvisioner;
  /** Set only when the requesting client routes team networks. */
  readonly teamDirectory?: VmTeamDirectory;
  readonly timing?: VmTimingSink;
}): Effect.Effect<BaseVmEntry, VmWorkflowError, VmRepository | VmProviderGateway | VmBillingGateway> {
  return Effect.gen(function* () {
    yield* requireGoShape(input.billingPlanId, input.imageSize ? {
      vcpus: input.imageSize.cpu, memoryMb: input.imageSize.memoryMb, diskMb: input.imageSize.storageMb,
    } : null);
    const runtimeBudgetSeconds = yield* requireGoCreate(input);
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const billing = yield* VmBillingGateway;
    const beginInput = isPaidVmPlan(input.billingPlanId)
      ? {
        ...input,
        resourceReservation: input.billingPlanId === "go" ? GO_VM_RESERVATION : vmResourceReservationForCreate({ imageSize: input.imageSize }),
        resourcePool: resourcePoolPolicyForPlan(input.billingPlanId, input.maxActiveVms),
      }
      : input;
    const create = yield* measureVmEffect(
      input.timing,
      "begin_base_open",
      repo.beginBaseOpen(beginInput),
    );
    return yield* finishBaseCreate(repo, providers, billing, { ...input, runtimeBudgetSeconds }, create);
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
  readonly imageSize?: CreateOptions["imageSize"];
  readonly baseName?: string;
  readonly reason?: string | null;
  readonly modelPlane?: VmModelPlaneProvisioner;
  readonly timing?: VmTimingSink;
}): Effect.Effect<BaseVmEntry, VmWorkflowError, VmRepository | VmProviderGateway | VmBillingGateway> {
  return Effect.gen(function* () {
    yield* requireGoShape(input.billingPlanId, input.imageSize ? {
      vcpus: input.imageSize.cpu, memoryMb: input.imageSize.memoryMb, diskMb: input.imageSize.storageMb,
    } : null);
    const runtimeBudgetSeconds = yield* requireGoCreate(input);
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const billing = yield* VmBillingGateway;
    const beginInput = isPaidVmPlan(input.billingPlanId)
      ? {
        ...input,
        resourceReservation: input.billingPlanId === "go" ? GO_VM_RESERVATION : vmResourceReservationForCreate({ imageSize: input.imageSize }),
        resourcePool: resourcePoolPolicyForPlan(input.billingPlanId, input.maxActiveVms),
      }
      : input;
    const create = yield* measureVmEffect(
      input.timing,
      "begin_base_reset",
      repo.beginBaseReset(beginInput),
    );
    return yield* finishBaseCreate(repo, providers, billing, { ...input, runtimeBudgetSeconds }, create);
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
    readonly imageSize?: CreateOptions["imageSize"];
    readonly runtimeBudgetSeconds?: number;
    readonly baseName?: string;
    readonly modelPlane?: VmModelPlaneProvisioner;
    readonly teamDirectory?: VmTeamDirectory;
    readonly timing?: VmTimingSink;
  },
  create: BeginBaseCreateResult,
): Effect.Effect<BaseVmEntry, VmWorkflowError, never> {
  return Effect.gen(function* () {
    if (create.kind === "existing") {
      const existing = create.vm;
      if (isFailedVmCreate(existing)) {
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
      baseGeneration: { baseId: create.base.id, generation: create.generation.generation },
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
      resolveOwnerNetwork({ userId: input.userId, provider: input.provider, billingTeamId: input.billingTeamId, teamDirectory: input.teamDirectory }).pipe(
        Effect.provideService(VmRepository, repo),
        Effect.provideService(VmProviderGateway, providers),
      ),
    ).pipe(
      // Unlike createVm, this runs after the credit is reserved, so the
      // reservation has to go back. resolveOwnerNetwork resolves a shared
      // network rather than creating one, so there is nothing to unwind there,
      // but the base and its generation exist by now and markBaseCreateFailed
      // is the mark on this path that releases them: the ad-hoc markCreateFailed
      // does not call restoreBaseAfterCreateFailure.
      Effect.tapError((err) =>
        Effect.all([
          refundCredit(billing, repo, create.vm, creditReservation),
          recordCreateFailureAfterMark(repo, repo.markBaseCreateFailed({
            baseId: create.base.id,
            generation: create.generation.generation,
            vmId: create.vm.id,
            userId: input.userId,
            code: PROVIDER_CREATE_UNAVAILABLE_FAILURE_CODE,
            message: errorMessage(err),
          }), {
            userId: input.userId,
            billingTeamId: input.billingTeamId,
            billingPlanId: input.billingPlanId,
            vmId: create.vm.id,
            eventType: "vm.base.create.failed",
            provider: input.provider,
            imageId: input.image,
            metadata: { operation: "resolve_network", message: errorMessage(err) },
          }),
        ], { discard: true }).pipe(Effect.catchAll(() => Effect.void)),
      ),
    );

    const materials = yield* measureVmEffect(
      input.timing,
      "model_plane_provision",
      provisionModelPlane(input.modelPlane, create.vm.id),
    ).pipe(
      Effect.tapError((err) =>
        Effect.all([
          refundCredit(billing, repo, create.vm, creditReservation),
          recordCreateFailureAfterMark(repo, repo.markBaseCreateFailed({
            baseId: create.base.id,
            generation: create.generation.generation,
            vmId: create.vm.id,
            userId: input.userId,
            code: VM_MODEL_PLANE_FAILURE_CODES[err.kind],
            message: errorMessage(err.cause),
          }), {
            userId: input.userId,
            billingTeamId: input.billingTeamId,
            billingPlanId: input.billingPlanId,
            vmId: create.vm.id,
            eventType: "vm.base.create.failed",
            provider: input.provider,
            imageId: input.image,
            metadata: { operation: "model_plane_provision", message: errorMessage(err.cause) },
          }),
        ], { discard: true }).pipe(Effect.catchAll(() => Effect.void)),
      ),
    );

    const handle = yield* measureVmEffect(
      input.timing,
      "provider_create",
      providers.create(input.provider, {
        image: input.image,
        imageSize: input.imageSize,
        runtimeBudgetSeconds: input.runtimeBudgetSeconds,
        displayName: create.vm.slug ?? undefined,
        promptIdentity: vmPromptIdentity(create.vm),
        providerMetadata: create.vm.providerMetadata,
        edgeRules: materials?.edgeRules,
        network: { id: network.providerNetworkId, memberIngress: network.memberIngress },
      }),
    ).pipe(
      Effect.tapError((err) =>
        Effect.all([
          refundCredit(billing, repo, create.vm, creditReservation),
          revokeModelPlane(input.modelPlane, create.vm.id),
          recordCreateFailureAfterMark(repo, repo.markBaseCreateFailed({
            baseId: create.base.id,
            generation: create.generation.generation,
            vmId: create.vm.id,
            userId: input.userId,
            ...(isProviderCreateCleanupError(err.cause)
              ? { code: PROVIDER_CREATE_CLEANUP_PENDING_FAILURE_CODE, cleanupProviderVmId: err.cause.providerVmId }
              : { code: err.operation }),
            message: errorMessage(err.cause),
          }), {
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
          yield* revokeModelPlane(input.modelPlane, create.vm.id);
          yield* refundCredit(billing, repo, create.vm, creditReservation);
          const markedFailed = yield* repo.markBaseCreateFailed({
            baseId: create.base.id,
            generation: create.generation.generation,
            vmId: create.vm.id,
            userId: input.userId,
            code: "database_finalize_failed",
            message: "Cloud VM Base state update failed.",
          }).pipe(Effect.catchAll(() => Effect.succeed(false)));
          if (markedFailed) {
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
          }
          return yield* Effect.fail(err);
        }),
      ),
    );

    yield* recordCreateSuccessEvents(repo, { ...input, idempotencyKey, origin: "base" }, running);
    yield* schedulePromptIdentityPush(providers, running, undefined);
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
  input: Parameters<VmRepositoryShape["beginBaseOpen"]>[0] & {
    readonly timing?: VmTimingSink;
    readonly imageSize?: CreateOptions["imageSize"];
    readonly modelPlane?: VmModelPlaneRevoker;
  },
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
          // forceStatus, the one caller that overrides the mapping. Everywhere
          // else a missing provider machine follows the shared observation
          // mapping. Here the override makes the Base generation's terminal
          // requirement explicit: beginBaseOpen below only allocates a
          // replacement once this row can no longer be opened.
          //
          // The home volume is not lost by this. beginBaseOpen retains the old
          // generation rather than deleting it, which is the same place a
          // normal reset leaves it.
          const markedDestroyed = yield* applyObservedProviderStatus(repo, providers, existing, {
            providerVmId,
            providerStatus: "destroyed",
            forceStatus: "destroyed",
            usageEventSource: "base_open_provider_missing",
            modelPlane: input.modelPlane,
            usageEventMetadata: {
              baseName: input.baseName ?? "base",
              generation: create.generation.generation,
            },
          });
          if (!markedDestroyed) {
            return yield* Effect.fail(new VmNotFoundError({ vmId: providerVmId }));
          }
          return yield* measureVmEffect(
            input.timing,
            "begin_base_open",
            Effect.suspend(() => repo.beginBaseOpen(
              isPaidVmPlan(input.billingPlanId)
                ? {
                  ...input,
                  resourceReservation: input.billingPlanId === "go" ? GO_VM_RESERVATION : vmResourceReservationForCreate({ imageSize: input.imageSize }),
                  resourcePool: resourcePoolPolicyForPlan(input.billingPlanId, input.maxActiveVms),
                }
                : input,
            )),
          );
        })
        : Effect.succeed(null)
    ),
  );
}

/**
 * A pending snapshot request older than this belongs to an attempt that died
 * without finishing (the route budget is 600 s), so a retry may take it over.
 */
export const SNAPSHOT_REQUEST_STALE_MS = 15 * 60 * 1000;

export function snapshotVm(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
  readonly name?: string;
  /** Idempotency-Key of the request: a retry with the same key returns the first snapshot. */
  readonly idempotencyKey?: string;
}) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const vm = yield* requireUserVm(input);
    const key = input.idempotencyKey;
    if (key) {
      if (!repo.beginSnapshotRequest || !repo.finishSnapshotRequest) {
        return yield* Effect.fail(new VmOperationUnsupportedError({ provider: vm.provider, operation: "snapshotIdempotency" }));
      }
      const begin = yield* repo.beginSnapshotRequest({
        vmId: vm.id,
        idempotencyKey: key,
        name: input.name ?? null,
        staleBefore: new Date(Date.now() - SNAPSHOT_REQUEST_STALE_MS),
      });
      if (begin.kind === "succeeded") return begin.snapshot;
      if (begin.kind === "in_progress") return yield* Effect.fail(new VmSnapshotInProgressError({ vmId: vm.id }));
      if (begin.kind === "conflict") return yield* Effect.fail(new VmSnapshotIdempotencyConflictError({ vmId: vm.id }));
    }
    const finish = repo.finishSnapshotRequest;
    const takeSnapshot: Effect.Effect<SnapshotRef, VmProviderOperationError | VmOperationUnsupportedError> = providers.snapshot
      ? providers.snapshot(vm.provider, vm.providerVmId ?? input.providerVmId, input.name)
      : Effect.fail(new VmOperationUnsupportedError({
        provider: vm.provider,
        operation: "snapshot",
      }));
    // A failed attempt frees the key so the same request can retry. The
    // original error wins over a failure to free it.
    const freeKey: Effect.Effect<void> = key && finish
      ? Effect.ignore(finish({ vmId: vm.id, idempotencyKey: key, outcome: { kind: "failed" } }))
      : Effect.void;
    const snapshot = yield* Effect.tapError(takeSnapshot, () => freeKey);
    if (key && finish) {
      // The snapshot exists now. A failed write here leaves the row pending;
      // a retry then waits for the stale window instead of failing this call.
      yield* Effect.ignore(finish({ vmId: vm.id, idempotencyKey: key, outcome: { kind: "succeeded", snapshot } }));
    }
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

/**
 * The machine as the Mac-facing reflection route reads it (`cmux vm self <m>`):
 * the owned row itself, so the route can build the same reflection context a
 * machine gets from inside. List/status semantics (`requireUserVm`): a locked
 * free-window machine still describes itself.
 */
export function reflectVm(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
}) {
  return Effect.gen(function* () {
    const vm: CloudVmRow = yield* requireUserVm(input);
    return vm;
  });
}

/** Every snapshot taken from a machine the caller owns, newest first (`cmux vm snapshot ls`). */
export function listVmSnapshots(input: {
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
    if (!providers.listSnapshots) {
      return yield* Effect.fail(new VmOperationUnsupportedError({ provider: vm.provider, operation: "listSnapshots" }));
    }
    const snapshots = yield* providers.listSnapshots(vm.provider, providerVmId);
    // A provider delete can commit before its final ledger write. Inventory is
    // authoritative: repair that final write when the pending snapshot is gone.
    const pending = yield* repo.pendingSnapshotDeletions({ vmId: vm.id, provider: vm.provider });
    for (const snapshotId of pending) {
      if (!snapshots.some((snapshot) => snapshot.id === snapshotId)) {
        yield* repo.recordUsageEvent(snapshotDeletionEvent(vm, snapshotId, "vm.snapshot.deleted")).pipe(Effect.retry({ times: 2 }));
      }
    }
    return [...snapshots].sort((a, b) => b.createdAt - a.createdAt);
  });
}

function snapshotDeletionEvent(vm: CloudVmRow, snapshotId: string, eventType: string) {
  return {
    userId: vm.userId, billingTeamId: vm.billingTeamId, billingPlanId: vm.billingPlanId,
    vmId: vm.id, eventType, provider: vm.provider, imageId: vm.imageId,
    metadata: { snapshotId },
  };
}

export type VmSnapshotDeleteResult = {
  readonly id: string;
  readonly deleted: true;
};

/**
 * Delete one snapshot of a machine the caller owns (`cmux vm snapshot rm`).
 * Scoped to the machine: the provider refuses a snapshot taken from another
 * VM as not-found, which the route answers as 404 vm_snapshot_not_found. The
 * ledger records the deletion so `hasOwnedSnapshot` stops offering it to restore.
 */
export function deleteVmSnapshot(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
  readonly snapshotId: string;
}) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const vm = yield* requireUserVm(input);
    const providerVmId = vm.providerVmId ?? input.providerVmId;
    if (!providers.deleteSnapshot) {
      return yield* Effect.fail(new VmOperationUnsupportedError({ provider: vm.provider, operation: "deleteSnapshot" }));
    }
    const pending = yield* repo.pendingSnapshotDeletions({ vmId: vm.id, provider: vm.provider });
    if (!pending.includes(input.snapshotId)) {
      if (!providers.listSnapshots) {
        return yield* Effect.fail(new VmOperationUnsupportedError({ provider: vm.provider, operation: "listSnapshots" }));
      }
      const snapshots = yield* providers.listSnapshots(vm.provider, providerVmId);
      if (!snapshots.some((snapshot) => snapshot.id === input.snapshotId)) {
        return yield* Effect.fail(new VmSnapshotNotFoundError({ snapshotId: input.snapshotId }));
      }
      // Persist before the irreversible mutation. A crash or final-write failure
      // leaves a durable intent that prevents restore and is safe to retry.
      yield* repo.recordUsageEvent(snapshotDeletionEvent(vm, input.snapshotId, "vm.snapshot.delete_requested")).pipe(Effect.retry({ times: 2 }));
    }
    yield* providers.deleteSnapshot(vm.provider, providerVmId, input.snapshotId).pipe(
      Effect.catchAll((err) => isProviderNotFoundError(err) ? Effect.void : Effect.fail(err)),
    );
    yield* repo.recordUsageEvent(snapshotDeletionEvent(vm, input.snapshotId, "vm.snapshot.deleted")).pipe(Effect.retry({ times: 2 }));
    const result: VmSnapshotDeleteResult = { id: input.snapshotId, deleted: true };
    return result;
  });
}

export type VmPauseResumeResult = {
  readonly id: string;
  readonly status: "paused" | "running";
};

/**
 * Park a machine: its compute stops billing while the persistent home and the
 * daemon's durable session survive; `resumeVm` (or any open/exec) brings it
 * back. Idempotent — pausing a paused machine is a no-op success. Providers
 * without a pause operation fail with the unsupported error the route turns
 * into a 501, so a caller can tell "cannot" from "did not".
 */
export function pauseVm(input: {
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
    if (vm.status === "destroyed") {
      return yield* Effect.fail(new VmNotFoundError({ vmId: input.providerVmId }));
    }
    if (vm.status === "paused") {
      return { id: providerVmId, status: "paused" } satisfies VmPauseResumeResult;
    }
    const pause = providers.pause;
    if (!pause) {
      return yield* Effect.fail(new VmOperationUnsupportedError({ provider: vm.provider, operation: "pause" }));
    }
    if (vm.billingPlanId === "go") yield* setRuntimeBudget(providers, vm, providerVmId, 0);
    yield* pause(vm.provider, providerVmId);
    const recorded = yield* repo.markProviderObservedStatus({ id: vm.id, providerVmId, status: "paused" });
    if (!recorded) {
      return yield* Effect.fail(new VmNotFoundError({ vmId: input.providerVmId }));
    }
    yield* repo.recordUsageEvent({
      userId: vm.userId,
      billingTeamId: vm.billingTeamId,
      billingPlanId: vm.billingPlanId,
      vmId: vm.id,
      eventType: "vm.paused",
      provider: vm.provider,
      imageId: vm.imageId,
      metadata: { source: "user" },
    }).pipe(Effect.catchAll(() => Effect.void));
    return { id: providerVmId, status: "paused" } satisfies VmPauseResumeResult;
  });
}

/**
 * Wake a parked machine through the same suspended-resume path every open and
 * exec uses, so plan limits (`reservePausedResume`) and the free window apply
 * and a provider-side pause the row never saw is handled too. Idempotent — a
 * running machine answers `running` without touching the provider beyond the
 * status probe. Providers without resume fail with the unsupported error.
 */
export function resumeVm(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
  readonly maxActiveVms?: number | null;
  readonly callerPlanId?: string | null;
  readonly modelPlane?: VmModelPlaneRevoker;
}) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const vm = yield* requireAccessibleUserVm(input);
    const providerVmId = vm.providerVmId ?? input.providerVmId;
    if (vm.status === "destroyed") {
      return yield* Effect.fail(new VmNotFoundError({ vmId: input.providerVmId }));
    }
    if (!providers.resume || !providers.getStatus) {
      if (vm.status === "running") return { id: providerVmId, status: "running" } satisfies VmPauseResumeResult;
      return yield* Effect.fail(new VmOperationUnsupportedError({ provider: vm.provider, operation: "resume" }));
    }
    yield* preflightResumeIfSuspended(
      repo,
      providers,
      vm,
      providerVmId,
      "user",
      { forceProviderProbe: true, maxActiveVms: input.maxActiveVms, callerPlanId: input.callerPlanId, modelPlane: input.modelPlane },
    );
    return { id: providerVmId, status: "running" } satisfies VmPauseResumeResult;
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
  /** Set only when the requesting client routes team networks. */
  readonly teamDirectory?: VmTeamDirectory;
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
    const resourceReservation = input.billingPlanId === "go" ? snapshotReservation ?? undefined : isPaidVmPlan(input.billingPlanId)
      ? restoreResourceReservation(snapshotReservation ?? {
        ...DEFAULT_VM_RESOURCE_RESERVATION,
        // A snapshot event written before resource metadata existed has no
        // trustworthy shape. Claim the historical machine shape and maximum disk size.
        diskMb: VM_DISK_MB_MAX,
      })
      : undefined;
    yield* requireGoShape(input.billingPlanId, snapshotReservation);
    yield* requireMemoryPlan(input.billingPlanId, snapshotReservation?.memoryMb ?? null);
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
      teamDirectory: input.teamDirectory,
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

function requireForkMemoryPlan(source: CloudVmRow, providers: VmProviderGatewayShape, providerVmId: string, planId: string) {
  return Effect.gen(function* () {
    const sourceMemoryMb = hasVmResourceReservationMetadata(source.providerMetadata)
      ? vmResourceReservationFromMetadata(source.providerMetadata).memoryMb
      : yield* (providers.getStats
        ? providers.getStats(source.provider, source.providerVmId ?? providerVmId).pipe(
            Effect.timeout("5 seconds"),
            Effect.map((stats) => vmProviderResourceSize("memoryMb", stats.memoryTotalMb)),
            Effect.catchAll(() => Effect.succeed(null)),
          )
        : Effect.succeed(null));
    yield* requireMemoryPlan(planId, sourceMemoryMb);
  });
}

function nativeForkOperation(providers: VmProviderGatewayShape, provider: ProviderId, modelPlane?: VmModelPlaneProvisioner) {
  if (modelPlane || !(providers.capabilities?.(provider).fork ?? vmCapabilitiesFor(provider).fork)) return undefined;
  return providers.fork;
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
  readonly modelPlane?: VmModelPlaneProvisioner;
  /** Set only when the requesting client routes team networks. */
  readonly teamDirectory?: VmTeamDirectory;
  readonly timing?: VmTimingSink;
}) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const billing = yield* VmBillingGateway;
    const source = yield* requireAccessibleUserVm({ ...input, callerPlanId: input.billingPlanId });
    yield* requireGoMetadataShape(input.billingPlanId, source.providerMetadata);
    yield* requireForkMemoryPlan(source, providers, input.providerVmId, input.billingPlanId);
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
    // A paused VM is a valid snapshot source. Only native forks require a
    // running provider VM; waking a paused source adds avoidable startup time.
    const sourceNetworkPolicy = restrictedNetworkPolicy(source.networkPolicy);
    const nativeFork = sourceNetworkPolicy ? undefined : nativeForkOperation(providers, source.provider, input.modelPlane);
    yield* preflightResumeIfSuspended(
      repo,
      providers,
      source,
      input.providerVmId,
      "fork",
      {
        forceProviderProbe: true,
        allowPausedSnapshot: !nativeFork,
        maxActiveVms: input.maxActiveVms,
        callerPlanId: input.billingPlanId,
        modelPlane: input.modelPlane,
      },
    );

    // A native fork has no way to accept the new row's edge rules. Use the
    // snapshot/create path for a model-plane machine so it receives its own
    // VM-bound credential instead of inheriting an unrouteable alias.
    // A fork keeps its source's outbound policy. The native provider fork
    // copies no rules, so a restricted source always takes the create path,
    // which installs the policy before the copy boots.
    // The provider owns cloning the source. Record its initial shape and
    // reconcile the copied machine independently after the fork completes.
    const sourceHasReservation = hasVmResourceReservationMetadata(source.providerMetadata);
    const nativeForkReservation = isPaidVmPlan(input.billingPlanId)
      ? sourceHasReservation
        ? vmResourceReservationFromMetadata(source.providerMetadata)
        : {
          // A legacy source draws from the pool at the plan's default machine
          // size until the copy is measured (finalizeNativeForkReservation).
          ...legacyPoolReservationForPlan(input.billingPlanId),
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
            resourcePool: resourcePoolPolicyForPlan(input.billingPlanId, input.maxActiveVms),
            resourcePoolPhase: "fork" as const,
            forkPending: true,
            forkMinimumResourceReservation: sourceHasReservation
              ? sourceReservation
              : { vcpus: 1, memoryMb: 4 * 1024, diskMb: 16 * 1024 },
          }
          : {}),
        billingPlanId: input.billingPlanId,
        idempotencyKey: input.idempotencyKey,
        agentUpdates: vmAgentUpdatesFromRow(source),
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
        nativeFork(source.provider, source.providerVmId ?? input.providerVmId),
      ).pipe(
        Effect.tapError((err) =>
          Effect.all([
            refundCredit(billing, repo, create.vm, creditReservation),
            recordCreateFailureAfterMark(repo, repo.markCreateFailed({
              id: create.vm.id,
              code: err.operation,
              message: errorMessage(err.cause),
            }), {
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
            const markedFailed = yield* repo.markCreateFailed({
              id: create.vm.id,
              code: "database_finalize_failed",
              message: "Cloud VM fork state update failed.",
            }).pipe(Effect.catchAll(() => Effect.succeed(false)));
            if (markedFailed) {
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
            }
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
      modelPlane: input.modelPlane,
      ...(sourceNetworkPolicy ? { networkPolicy: sourceNetworkPolicy } : {}),
      agentUpdates: vmAgentUpdatesFromRow(source),
      teamDirectory: input.teamDirectory,
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
      // A full pool can also be held by a machine the provider already
      // deleted, so the same status refresh applies before one retry.
      if (!isVmLimitExceededError(err) && !isVmResourcePoolExceededError(err)) return Effect.fail(err);
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

/** A provider resize is successful only if its resource claim is still current. */
function confirmResizedResourceReservation(
  write: ResourceReservationWriter,
  input: Parameters<ResourceReservationWriter>[0],
  providerVmId: string,
): Effect.Effect<void, VmDatabaseError | VmResizeInProgressError> {
  return write(input).pipe(Effect.flatMap((confirmed) => confirmed
    ? Effect.void
    : Effect.fail(new VmResizeInProgressError({ vmId: providerVmId }))));
}

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
      return reconcileObservedProviderStatus(repo, providers, getStatus, vm, "provider_status_refresh", input.modelPlane).pipe(
        Effect.asVoid,
      );
    }, { concurrency: 10, discard: true });
  });
}

function dbStatusFromProviderStatus(status: "running" | "paused" | "destroyed"): CloudVmStatus {
  return status;
}

function observedDbStatus(
  providerStatus: "running" | "paused" | "destroyed",
): CloudVmStatus {
  return dbStatusFromProviderStatus(providerStatus);
}

/**
 * The one place an observed provider status becomes the row's status. A write
 * that lands on `destroyed` atomically records the ledger row plus an external
 * cleanup outbox. The normal lookup and status-reconcile queries exclude the
 * terminal row, but the cleanup reconciler keeps retrying credential revoke
 * and any exclusively-owned volume deletion until each is acknowledged.
 *
 * The status is derived here rather than taken from the caller, so every
 * entrypoint agrees about what the provider observed. A provider-reported
 * pause remains recoverable. Missing or destroyed compute is terminal even
 * when a detached home volume remains; there is no workflow that can attach
 * that volume to a replacement machine, so keeping the row live would strand
 * quota and credentials indefinitely.
 */
function applyObservedProviderStatus(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  vm: CloudVmRow,
  input: {
    readonly providerVmId: string;
    readonly providerStatus: "running" | "paused" | "destroyed";
    readonly usageEventSource: VmDestroySource;
    readonly modelPlane?: VmModelPlaneRevoker;
    readonly usageEventMetadata?: Record<string, string | number | boolean | null>;
    readonly forceStatus?: CloudVmStatus;
  },
): Effect.Effect<boolean, VmDatabaseError> {
  return Effect.gen(function* () {
    const status = input.forceStatus ?? observedDbStatus(input.providerStatus);
    const usageEvent: VmUsageEventInput | undefined = status === "destroyed"
      ? {
        userId: vm.userId,
        billingTeamId: vm.billingTeamId,
        billingPlanId: vm.billingPlanId,
        vmId: vm.id,
        eventType: "vm.destroyed",
        provider: vm.provider,
        imageId: vm.imageId,
        vmCreatedAt: vm.createdAt,
        metadata: { source: input.usageEventSource, ...input.usageEventMetadata },
      }
      : undefined;
    const homeVolume = status === "destroyed"
      ? machineOwnedHomeVolume(vm, input.providerVmId)
      : null;
    const cleanup: VmObservedDestroyCleanup | undefined = status === "destroyed"
      ? {
        modelPlane: true,
        ...(homeVolume ? { homeVolume } : {}),
      }
      : undefined;
    const didUpdate = yield* repo.markProviderObservedStatus({
      id: vm.id,
      providerVmId: input.providerVmId,
      status,
      ...(usageEvent ? { usageEvent } : {}),
      ...(cleanup ? { cleanup } : {}),
    });
    if (!didUpdate || status !== "destroyed" || !cleanup) return didUpdate;
    yield* drainObservedDestroyCleanup(repo, providers, input.modelPlane, vm, cleanup);
    return true;
  });
}

type ProviderStatusReconcileOutcome = "updated" | "destroyed" | "unchanged" | "skipped";

function reconcileObservedProviderStatus(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  getStatus: NonNullable<VmProviderGatewayShape["getStatus"]>,
  vm: CloudVmRow,
  usageEventSource: VmDestroySource,
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
    const dbStatus = observedDbStatus(providerStatus);
    if (dbStatus === vm.status) return "unchanged" as const;
    const didUpdate = yield* applyObservedProviderStatus(repo, providers, vm, {
      providerVmId,
      providerStatus,
      usageEventSource,
      modelPlane,
    }).pipe(Effect.catchAll(() => Effect.succeed(false)));
    if (!didUpdate) return "skipped" as const;
    return dbStatus === "destroyed" ? "destroyed" as const : "updated" as const;
  });
}

function boundedVmStatusReconcileLimit(limit: number | undefined): number {
  if (limit === undefined || !Number.isFinite(limit)) return VM_STATUS_RECONCILE_BATCH_LIMIT;
  return Math.max(1, Math.min(VM_STATUS_RECONCILE_BATCH_LIMIT, Math.trunc(limit)));
}

const RESUME_STATUS_PROBE_TIMEOUT = "5 seconds";
const RESUME_SETTLE_ATTEMPTS = 10;
const RESUME_SETTLE_INTERVAL = "1 second";
type VmResumeSource = "exec" | "attach" | "ssh" | "scp" | "fork" | "open_port" | "resize" | "user";

type ResumePreflightOptions = {
  /** Resolved billing-scope allowance; null is unlimited, undefined uses the plan default. */
  readonly maxActiveVms?: number | null;
  /** The caller's current plan, whose shared pool a resumed machine draws from. */
  readonly callerPlanId?: string | null;
  /** Revokes coderouter tokens if the provider reports that compute is gone. */
  readonly modelPlane?: VmModelPlaneRevoker;
  /**
   * Probe the provider even when Postgres still says `running`. Providers may
   * pause a VM independently (for example after an idle timeout), so an
   * attach/open operation must verify the live state before minting a route.
   * Passive reads intentionally leave this off.
   */
  readonly forceProviderProbe?: boolean;
  /** Snapshot-based forks can copy a paused VM directly without waking it. */
  readonly allowPausedSnapshot?: boolean;
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

function setRuntimeBudget(providers: VmProviderGatewayShape, vm: CloudVmRow, vmId: string, seconds: number | null) {
  if (!providers.setRuntimeBudget) return Effect.fail(new VmOperationUnsupportedError({ provider: vm.provider, operation: "runtime limits" }));
  return providers.setRuntimeBudget(vm.provider, vmId, seconds);
}

function bestEffortPause(
  providers: VmProviderGatewayShape,
  vm: CloudVmRow,
  providerVmId: string,
): Effect.Effect<void, never> {
  const pause = providers.pause;
  if (!pause) return Effect.void;
  return Effect.gen(function* () {
    if (vm.billingPlanId === "go") yield* setRuntimeBudget(providers, vm, providerVmId, 0);
    yield* pause(vm.provider, providerVmId);
  }).pipe(Effect.catchAll(() => Effect.void));
}

function resumeUntilRunning(
  providers: VmProviderGatewayShape,
  vm: CloudVmRow,
  providerVmId: string,
): Effect.Effect<void, VmWorkflowError> {
  return Effect.gen(function* () {
    const resume = providers.resume;
    if (!resume) return;
    if (vm.billingPlanId === "go") {
      const usage = yield* Effect.tryPromise({ try: () => getGoVmUsage(vm.userId), catch: (cause) => new VmBillingError({ operation: "go_runtime", cause }) });
      if (usage && usage.remainingSeconds <= 0) return yield* Effect.fail(new VmUsageLimitExceededError({ includedHours: 40, usedHours: 40 }));
      yield* setRuntimeBudget(providers, vm, providerVmId, usage?.remainingSeconds ?? null);
    }
    const handle = yield* resume(vm.provider, providerVmId).pipe(Effect.tapError(() => bestEffortPause(providers, vm, providerVmId)));
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
  planId: string | null | undefined = vm.billingPlanId,
): Effect.Effect<boolean, VmWorkflowError> {
  if (!vm.billingTeamId) return Effect.succeed(false);
  return Effect.gen(function* () {
    const reserved = yield* repo.reservePausedResume({
      id: vm.id,
      userId: vm.userId,
      billingTeamId: vm.billingTeamId,
      providerVmId,
      maxActiveVms,
      // A resumed machine draws from the caller's current pool again.
      resourcePool: resourcePoolPolicyForPlan(planId || vm.billingPlanId, maxActiveVms),
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
    if (vm.billingPlanId === "go") {
      const usage = yield* Effect.tryPromise({
        try: () => getGoVmUsage(vm.userId),
        catch: (cause) => new VmBillingError({ operation: "go_runtime", cause }),
      });
      if (usage && usage.remainingSeconds <= 0) {
        yield* pauseGoVm(repo, providers, vm, providerVmId, usage.usedSeconds);
        return yield* Effect.fail(new VmUsageLimitExceededError({ includedHours: GO_INCLUDED_VM_HOURS, usedHours: GO_INCLUDED_VM_HOURS }));
      }
    }
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
      // already removed; record what the probe saw and return the same
      // not-found contract as ownership checks.
      //
      // A detached home volume does not make missing compute resumable: no
      // workflow can create replacement compute around it. Retire the row so
      // it stops consuming quota, and revoke its model-plane credentials.
      yield* applyObservedProviderStatus(repo, providers, vm, {
        providerVmId,
        providerStatus: "destroyed",
        usageEventSource: "provider_status_access",
        modelPlane: options.modelPlane,
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
    if (options.allowPausedSnapshot) return false;

    const reserved = yield* reservePausedResumeIfTeam(repo, vm, providerVmId, options.maxActiveVms, options.callerPlanId);
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
  /** The caller's current plan, whose shared pool a resumed machine draws from. */
  callerPlanId?: string | null,
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

        const reserved = yield* reservePausedResumeIfTeam(repo, vm, providerVmId, maxActiveVms, callerPlanId);
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
    const modelPlaneRevoked = input.modelPlane
      ? yield* attemptModelPlaneRevoke(input.modelPlane, vm.id)
      : true;
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
    const pendingHomeVolume = homeVolume && !homeVolumeDeleted ? homeVolume : undefined;
    const cleanup: VmObservedDestroyCleanup | undefined = !modelPlaneRevoked
      ? { modelPlane: true, ...(pendingHomeVolume ? { homeVolume: pendingHomeVolume } : {}) }
      : pendingHomeVolume
        ? { homeVolume: pendingHomeVolume }
        : undefined;
    yield* repo.markDestroyed(vm.id, cleanup).pipe(Effect.retry({ times: 2 }));
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
    yield* (repo.pruneExpiredPreviewLeases?.({
      before: new Date(now.getTime() - VM_PREVIEW_LEASE_RETENTION_MS),
      limit: PREVIEW_LEASE_PRUNE_BATCH,
    }) ?? Effect.succeed(0)).pipe(Effect.catchAll(() => Effect.succeed(0)));
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
  readonly modelPlane?: VmModelPlaneRevoker;
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
      { maxActiveVms: input.maxActiveVms, callerPlanId: input.callerPlanId, modelPlane: input.modelPlane },
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

type VmFirewallInput = {
  readonly userId: string;
  readonly provider?: ProviderId;
  /** The account scope that owns the VMs named by vmId (new VMs are team-owned). */
  readonly billingTeamId?: string | null;
};

function firewallProvider(input: VmFirewallInput) {
  return Effect.gen(function* () {
    const provider = input.provider ?? "freestyle";
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const network = yield* resolveOwnerNetwork({ userId: input.userId, provider });
    return { provider, providers, repo, network };
  });
}

const FIREWALL_IDENTITY_KEYS = ["vmId", "vpcId", "tunnelId"] as const;
const FIREWALL_ENDPOINT_KEYS: ReadonlySet<string> = new Set([...FIREWALL_IDENTITY_KEYS, "cidr", "public", "port", "protocol"]);

/** Whether the caller owns the resource one endpoint names; a CIDR or public end names none. */
function ownsFirewallEndpoint(repo: VmRepositoryShape, input: VmFirewallInput, networkId: string, endpoint: VMFirewallEndpoint) {
  return Effect.gen(function* () {
    const provider = input.provider ?? "freestyle";
    // The provider adds selectors as new optional fields; one this code does not know could name
    // another tenant's resource, so it makes the endpoint not the caller's.
    if (Object.keys(endpoint).some((key) => !FIREWALL_ENDPOINT_KEYS.has(key))) return false;
    if (endpoint.vpcId && endpoint.vpcId !== networkId) return false;
    if (endpoint.vmId) {
      if (!repo.findUserVm) return yield* Effect.fail(new VmPrivateNetworkUnavailableError({ provider, reason: "firewall VM ownership lookup is unavailable" }));
      const vm = yield* repo.findUserVm({ userId: input.userId, billingTeamId: input.billingTeamId, providerVmId: endpoint.vmId, provider });
      // The firewall edits the caller's own network, which holds only the VMs the caller created;
      // a teammate's VM in the same team scope is on the teammate's network.
      if (!vm || vm.userId !== input.userId) return false;
    }
    if (endpoint.tunnelId) {
      if (!repo.findTunnelsByProviderTunnelIds) return yield* Effect.fail(new VmPrivateNetworkUnavailableError({ provider, reason: "firewall tunnel ownership lookup is unavailable" }));
      const [tunnel] = yield* repo.findTunnelsByProviderTunnelIds(provider, [endpoint.tunnelId]);
      if (!tunnel || tunnel.userId !== input.userId || tunnel.revokedAt) return false;
    }
    return true;
  });
}

/**
 * The provider account is shared by every cmux user, so the provider cannot say whose a rule is.
 * A rule is the caller's (to read or delete) when it names at least one resource and every
 * resource it names is the caller's. Creation is stricter: see createVmFirewallRule.
 */
function ownsFirewallRule(repo: VmRepositoryShape, input: VmFirewallInput, networkId: string, rule: Pick<VMFirewallRule, "source" | "destination">) {
  return Effect.gen(function* () {
    if (!FIREWALL_IDENTITY_KEYS.some((key) => rule.source[key] || rule.destination[key])) return false;
    return (yield* ownsFirewallEndpoint(repo, input, networkId, rule.source)) && (yield* ownsFirewallEndpoint(repo, input, networkId, rule.destination));
  });
}

/** Fails VmNotFoundError naming the endpoint's resource when the caller does not own it. */
function ensureOwnedFirewallEndpoint(repo: VmRepositoryShape, input: VmFirewallInput, networkId: string, endpoint: VMFirewallEndpoint) {
  return Effect.gen(function* () {
    if (yield* ownsFirewallEndpoint(repo, input, networkId, endpoint)) return;
    return yield* Effect.fail(new VmNotFoundError({ vmId: endpoint.vmId ?? endpoint.vpcId ?? endpoint.tunnelId ?? "endpoint" }));
  });
}

/** Most rules one caller may hold on the shared provider account. */
export const VM_FIREWALL_RULE_LIMIT = 100;
/** Most VMs an unfiltered list reads (one provider call each); older VMs list with ?vmId. */
export const VM_FIREWALL_LIST_VM_LIMIT = 10;

/** The caller's live provider VM ids in the account scope, newest first, at most the list limit. */
function callerProviderVmIds(repo: VmRepositoryShape, input: VmFirewallInput, provider: ProviderId) {
  return repo.listUserVms(input.userId, input.billingTeamId).pipe(
    Effect.map((rows) => rows
      .filter((row) => row.userId === input.userId && row.provider === provider && row.providerVmId && row.status !== "destroyed" && row.status !== "failed")
      .sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime())
      .slice(0, VM_FIREWALL_LIST_VM_LIMIT)
      .map((row) => row.providerVmId as string)),
  );
}

export function listVmFirewallRules(input: VmFirewallInput & { readonly vpcId?: string; readonly vmId?: string; readonly tunnelId?: string }): VmWorkflowProgram<VMFirewallRule[]> {
  return Effect.gen(function* () {
    const { provider, providers, repo, network } = yield* firewallProvider(input);
    const networkId = network.providerNetworkId;
    if (input.vpcId && input.vpcId !== networkId) return yield* Effect.fail(new VmNotFoundError({ vmId: input.vpcId }));
    if (input.vmId) yield* ensureOwnedFirewallEndpoint(repo, input, networkId, { vmId: input.vmId });
    if (input.tunnelId) yield* ensureOwnedFirewallEndpoint(repo, input, networkId, { tunnelId: input.tunnelId });
    const filter = input.vmId || input.tunnelId || input.vpcId ? { vmId: input.vmId, vpcId: input.vpcId, tunnelId: input.tunnelId } : undefined;
    return yield* readOwnedFirewallRules({ provider, providers, repo, input, networkId, filter });
  });
}

/**
 * The caller's rules. A provider vmId listing holds the rules naming the VM plus those naming its
 * networks; a network listing misses rules that name only a VM, so no filter means the network
 * plus the newest live VMs (bounded: each is one call to the shared provider account).
 */
function readOwnedFirewallRules(args: {
  readonly provider: ProviderId;
  readonly providers: VmProviderGatewayShape;
  readonly repo: VmRepositoryShape;
  readonly input: VmFirewallInput;
  readonly networkId: string;
  readonly filter?: { readonly vmId?: string; readonly vpcId?: string; readonly tunnelId?: string };
}) {
  return Effect.gen(function* () {
    const { provider, providers, repo, input, networkId } = args;
    const list = providers.listFirewallRules;
    if (!list) return yield* Effect.fail(new VmOperationUnsupportedError({ provider, operation: "listFirewallRules" }));
    const filters = args.filter
      ? [args.filter]
      : [{ vpcId: networkId }, ...(yield* callerProviderVmIds(repo, input, provider)).map((vmId) => ({ vmId }))];
    const listed = yield* Effect.forEach(filters, (filter) => list(provider, filter), { concurrency: 4 });
    const unique = [...new Map(listed.flat().map((rule) => [rule.id, rule])).values()];
    return yield* Effect.filter(unique, (rule) => ownsFirewallRule(repo, input, networkId, rule));
  });
}

export function listVmNetworks(input: VmFirewallInput): VmWorkflowProgram<Array<{ id: string; cidr: string | null; cidrV6: string | null; scope: "user" | "team" }>> {
  return Effect.gen(function* () {
    const provider = input.provider ?? "freestyle";
    const repo = yield* VmRepository;
    if (!repo.findNetwork) return yield* Effect.fail(new VmPrivateNetworkUnavailableError({ provider, reason: "network lookup is unavailable" }));
    const network = yield* repo.findNetwork(input.userId, provider);
    return network ? [{ id: network.providerNetworkId, cidr: network.cidr, cidrV6: network.cidrV6, scope: "user" as const }] : [];
  });
}

/** The caller's rule by id; a missing rule and another tenant's rule are the same not-found. */
function ownedFirewallRule(input: VmFirewallInput & { readonly ruleId: string }) {
  return Effect.gen(function* () {
    const { provider, providers, repo, network } = yield* firewallProvider(input);
    if (!providers.getFirewallRule) return yield* Effect.fail(new VmOperationUnsupportedError({ provider, operation: "getFirewallRule" }));
    const rule = yield* providers.getFirewallRule(provider, input.ruleId).pipe(
      Effect.catchAll((err): Effect.Effect<never, VmProviderOperationError | VmFirewallRuleNotFoundError> =>
        isProviderNotFoundError(err.cause) ? Effect.fail(new VmFirewallRuleNotFoundError({ ruleId: input.ruleId })) : Effect.fail(err),
      ),
    );
    if (!(yield* ownsFirewallRule(repo, input, network.providerNetworkId, rule))) return yield* Effect.fail(new VmFirewallRuleNotFoundError({ ruleId: input.ruleId }));
    return { provider, providers, rule };
  });
}

export function getVmFirewallRule(input: VmFirewallInput & { readonly ruleId: string }): VmWorkflowProgram<VMFirewallRule> {
  return ownedFirewallRule(input).pipe(Effect.map(({ rule }) => rule));
}

export function createVmFirewallRule(input: VmFirewallInput & VMFirewallRuleInput): VmWorkflowProgram<VMFirewallRule> {
  return Effect.gen(function* () {
    const { provider, providers, repo, network } = yield* firewallProvider(input);
    // Rules allow traffic into their destination. A destination of only an address range or the
    // public Internet would reach other tenants' machines on the shared account, so the destination
    // must be one of the caller's resources.
    if (!FIREWALL_IDENTITY_KEYS.some((key) => input.destination[key])) {
      return yield* Effect.fail(new VmFirewallRuleInvalidError({ reason: "A firewall rule's destination must be your Cloud VM, network, or tunnel." }));
    }
    yield* ensureOwnedFirewallEndpoint(repo, input, network.providerNetworkId, input.source);
    yield* ensureOwnedFirewallEndpoint(repo, input, network.providerNetworkId, input.destination);
    const existing = yield* readOwnedFirewallRules({ provider, providers, repo, input, networkId: network.providerNetworkId });
    if (existing.length >= VM_FIREWALL_RULE_LIMIT) return yield* Effect.fail(new VmFirewallRuleLimitError({ limit: VM_FIREWALL_RULE_LIMIT }));
    if (!providers.createFirewallRule) return yield* Effect.fail(new VmOperationUnsupportedError({ provider, operation: "createFirewallRule" }));
    // Only the rule goes to the provider: the driver spreads it into the request body.
    return yield* providers.createFirewallRule(provider, { source: input.source, destination: input.destination, ...(input.description ? { description: input.description } : {}) });
  });
}

export function deleteVmFirewallRule(input: VmFirewallInput & { readonly ruleId: string }): VmWorkflowProgram<void> {
  return Effect.gen(function* () {
    const { provider, providers } = yield* ownedFirewallRule(input);
    if (!providers.deleteFirewallRule) return yield* Effect.fail(new VmOperationUnsupportedError({ provider, operation: "deleteFirewallRule" }));
    // Deleted by someone else between the read and the delete: the same not-found, so a retry is correct.
    yield* providers.deleteFirewallRule(provider, input.ruleId).pipe(
      Effect.catchAll((err): Effect.Effect<never, VmProviderOperationError | VmFirewallRuleNotFoundError> =>
        isProviderNotFoundError(err.cause) ? Effect.fail(new VmFirewallRuleNotFoundError({ ruleId: input.ruleId })) : Effect.fail(err),
      ),
    );
  });
}

type VmFileInput = {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
  readonly callerPlanId?: string | null;
  readonly maxActiveVms?: number | null;
};

function fileVm<A>(input: VmFileInput, run: (provider: VmProviderGatewayShape, vm: CloudVmRow) => Effect.Effect<A, VmProviderOperationError | VmOperationUnsupportedError | VmFileNotFoundError>): VmWorkflowProgram<A> {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const vm = yield* requireAccessibleUserVm(input);
    yield* preflightResumeIfSuspended(repo, providers, vm, input.providerVmId, "user", {
      maxActiveVms: input.maxActiveVms,
    });
    return yield* run(providers, vm);
  });
}

export function listVmFiles(input: VmFileInput, path: string): VmWorkflowProgram<VMFileEntry[]> {
  return fileVm(input, (providers, vm) => {
    if (!providers.listFiles) return Effect.fail(new VmOperationUnsupportedError({ provider: vm.provider, operation: "listFiles" }));
    return providers.listFiles(vm.provider, input.providerVmId, path).pipe(missingFileAsNotFound(path));
  });
}

export function readVmFile(input: VmFileInput, path: string): VmWorkflowProgram<VMFileContents> {
  return fileVm(input, (providers, vm) => {
    if (!providers.readFile) return Effect.fail(new VmOperationUnsupportedError({ provider: vm.provider, operation: "readFile" }));
    return providers.readFile(vm.provider, input.providerVmId, path).pipe(missingFileAsNotFound(path));
  });
}

export function writeVmFile(input: VmFileInput, path: string, data: Uint8Array, mode?: number): VmWorkflowProgram<void> {
  return fileVm(input, (providers, vm) => {
    if (!providers.writeFile) return Effect.fail(new VmOperationUnsupportedError({ provider: vm.provider, operation: "writeFile" }));
    return providers.writeFile(vm.provider, input.providerVmId, path, data, mode);
  });
}

export function mkdirVmFile(input: VmFileInput, path: string): VmWorkflowProgram<void> {
  return fileVm(input, (providers, vm) => {
    if (!providers.makeDirectory) return Effect.fail(new VmOperationUnsupportedError({ provider: vm.provider, operation: "makeDirectory" }));
    return providers.makeDirectory(vm.provider, input.providerVmId, path);
  });
}

/**
 * Freestyle removes a missing path with success, so the workflow stats first: a path the provider
 * reports as missing ("No such file or directory") is VmFileNotFoundError (404 vm_file_not_found).
 * Any other stat failure, a missing VM included, stays a provider failure.
 */
export function removeVmFile(input: VmFileInput, path: string): VmWorkflowProgram<void> {
  return fileVm(input, (providers, vm) => {
    const remove = providers.removeFile
    if (!remove) return Effect.fail(new VmOperationUnsupportedError({ provider: vm.provider, operation: "removeFile" }));
    const stat: Effect.Effect<unknown, VmProviderOperationError | VmFileNotFoundError> = providers.statFile
      ? providers.statFile(vm.provider, input.providerVmId, path).pipe(missingFileAsNotFound(path))
      : Effect.void
    return stat.pipe(Effect.flatMap(() => remove(vm.provider, input.providerVmId, path)));
  });
}

/** A provider 404 whose message is the guest's ENOENT (not a missing VM). */
function isMissingFileError(cause: unknown): boolean {
  if (!isProviderNotFoundError(cause)) return false
  const message = cause instanceof Error ? cause.message : String((cause as { message?: unknown } | null)?.message ?? "")
  return /No such file or directory|os error 2\b/.test(message)
}

/** Maps the guest's ENOENT to VmFileNotFoundError (404 vm_file_not_found); other failures pass through. */
function missingFileAsNotFound(path: string) {
  return <A>(effect: Effect.Effect<A, VmProviderOperationError>): Effect.Effect<A, VmProviderOperationError | VmFileNotFoundError> =>
    effect.pipe(
      Effect.catchAll((err): Effect.Effect<never, VmProviderOperationError | VmFileNotFoundError> =>
        isMissingFileError(err.cause) ? Effect.fail(new VmFileNotFoundError({ path })) : Effect.fail(err),
      ),
    )
}

export function statVmFile(input: VmFileInput, path: string): VmWorkflowProgram<VMFileStat> {
  return fileVm(input, (providers, vm) => {
    if (!providers.statFile) return Effect.fail(new VmOperationUnsupportedError({ provider: vm.provider, operation: "statFile" }));
    return providers.statFile(vm.provider, input.providerVmId, path).pipe(missingFileAsNotFound(path));
  });
}

export function getVmStats(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
  readonly modelPlane?: VmModelPlaneRevoker;
}): VmWorkflowProgram<VMStats> {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const vm = yield* requireUserVm(input);
    // No resume preflight on purpose: a reading must never wake a sleeping machine.
    if (!providers.getStats) {
      return yield* Effect.fail(
        new VmProviderOperationError({
          provider: vm.provider,
          operation: "getStats",
          cause: new VmOperationUnsupportedError({ provider: vm.provider, operation: "getStats" }),
        }),
      );
    }
    return yield* providers.getStats(vm.provider, input.providerVmId).pipe(
      Effect.flatMap((stats) => {
        const now = Date.now();
        const reported = applyVmResourceUsage(stats, vm.providerMetadata, input.providerVmId, now);
        // The private development backend cannot receive production-edge reports.
        // Production keeps the push path. Never probe non-awake machines, and
        // prefer an existing fresh report over another guest round trip.
        const fresh = reported.resourceSampledAt !== undefined
          && reported.resourceSampledAt <= now
          && now - reported.resourceSampledAt <= VM_RESOURCE_USAGE_MAX_AGE_MS;
        if (stats.state !== "awake" || fresh || !shouldReadVmResourceStatsDirectly() || !providers.getResourceStats) {
          return Effect.succeed(reported);
        }
        return providers.getResourceStats(vm.provider, input.providerVmId).pipe(
          Effect.map((sample) => sample ? applyVmResourceUsage(stats, {
            [VM_RESOURCE_USAGE_KEY]: {
              ...sample, providerVmId: input.providerVmId, receivedAt: sample.resourceSampledAt,
            },
          }, input.providerVmId, Date.now()) : reported),
          Effect.catchAll((error) => isProviderNotFoundError(error) ? Effect.fail(error) : Effect.succeed(reported)),
        );
      }),
      Effect.mapError((error): VmWorkflowError => error),
      Effect.catchAll((error) => {
        if (!isProviderNotFoundError(error)) return Effect.fail(error);
        return Effect.gen(function* () {
          yield* applyObservedProviderStatus(repo, providers, vm, {
            providerVmId: input.providerVmId,
            providerStatus: "destroyed",
            usageEventSource: "provider_status_stats",
            modelPlane: input.modelPlane,
          }).pipe(Effect.catchAll(() => Effect.succeed(false)));
          return yield* Effect.fail(new VmNotFoundError({ vmId: input.providerVmId }));
        });
      }),
    );
  });
}

export function resizeVm(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
  readonly storageMb?: number;
  readonly cpu?: number;
  readonly memoryMb?: number;
  /** Current caller/VM plan for paid-machine resize recovery. */
  readonly billingPlanId?: string | null;
  /** Current machine-count allowance, also used when resuming a paused VM. */
  readonly maxActiveVms?: number | null;
  readonly modelPlane?: VmModelPlaneRevoker;
}): VmWorkflowProgram<VMStats> {
  // oxlint-disable-next-line complexity -- Resize orchestration must keep reservation, provider, rollback, and confirmation order explicit.
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    let vm = yield* requireAccessibleUserVm({ ...input, callerPlanId: input.billingPlanId });
    const planId = input.billingPlanId ?? vm.billingPlanId ?? "free";
    if (planId === "go" && ((input.storageMb ?? 0) > 16 * 1024 || (input.cpu ?? 0) > 2 || (input.memoryMb ?? 0) > 4 * 1024)) {
      return yield* Effect.fail(new VmGoShapeError());
    }
    for (const [resource, requested, max] of [
      ["cpu", input.cpu, maxVcpusForPlan(planId)],
      ["memory", input.memoryMb, maxMemoryMbForPlan(planId)],
      ["storage", input.storageMb, maxDiskMbForPlan(planId)],
    ] as const) {
      if (requested !== undefined && requested > max) {
        return yield* Effect.fail(new VmResizePlanLimitError({
          vmId: input.providerVmId, resource, requested, max, planId,
          ...(planId === "max" ? {} : { upgradePlanId: "max" }),
        }));
      }
    }
    if (!providers.resize || !providers.getStats) {
      return yield* Effect.fail(new VmOperationUnsupportedError({ provider: vm.provider, operation: "resize" }));
    }
    yield* preflightResumeIfSuspended(repo, providers, vm, input.providerVmId, "resize", {
      forceProviderProbe: true,
      maxActiveVms: input.maxActiveVms, callerPlanId: input.billingPlanId,
      modelPlane: input.modelPlane,
    });
    const current = yield* providers.getStats(vm.provider, input.providerVmId);
    for (const [resource, requested, previous, max] of [
      ["cpu", input.cpu, current.cpus, 32],
      ["memory", input.memoryMb, current.memoryTotalMb, 64 * 1024],
    ] as const) {
      if (requested === undefined) continue;
      if (previous === undefined || !Number.isSafeInteger(previous) || previous <= 0) {
        return yield* Effect.fail(new VmOperationUnsupportedError({ provider: vm.provider, operation: "resize" }));
      }
      if (!Number.isSafeInteger(requested) || requested < previous || requested > max || requested <= 0 || (resource === "memory" && (requested < 4 * 1024 || requested % 1024 !== 0))) {
        return yield* Effect.fail(new VmResizeInvalidError({
          vmId: input.providerVmId, requestedMb: requested, currentMb: previous, maxMb: max,
          reason: requested < previous ? "below_current" : "above_max", resource,
        }));
      }
    }
    const computeChanged = (input.cpu !== undefined && input.cpu !== current.cpus) ||
      (input.memoryMb !== undefined && input.memoryMb !== current.memoryTotalMb);
    // CPU and memory growth draws from the billing scope's shared pool. Claim
    // the larger shape under the billing lock before provider I/O, and give
    // the claim back when the provider never applied it.
    // The claim is taken right before provider I/O, after every validation.
    let computeClaim: ComputeResizeClaim | null = null;
    const claimCompute = Effect.gen(function* () {
      if (!computeChanged) return;
      computeClaim = yield* reserveComputeResize(repo, vm, input, current, planId);
      if (computeClaim) vm = computeClaim.vm;
    });
    const releaseComputeClaim = <E>(exit: Exit.Exit<void, E>) =>
      computeClaim && Exit.isFailure(exit)
        ? releaseUnappliedComputeResize(repo, providers, vm, input.providerVmId, computeClaim)
        : Effect.void;
    if (input.storageMb === undefined) {
      if (!computeChanged) return current;
      yield* claimCompute;
      yield* providers.resize(vm.provider, input.providerVmId, { cpu: input.cpu, memoryMb: input.memoryMb }).pipe(
        Effect.onExit(releaseComputeClaim),
      );
      const updated = yield* providers.getStats(vm.provider, input.providerVmId);
      const existingReservation = vmResourceReservationFromMetadata(vm.providerMetadata);
      const currentDiskMb = vmProviderResourceSize("diskMb", current.diskTotalMb) ?? existingReservation.diskMb;
      if (repo.setResourceReservation) {
        yield* confirmResizedResourceReservation(repo.setResourceReservation, {
          id: vm.id,
          reservation: reservationFromLegacyProviderStats(
            updated,
            existingReservation,
            currentDiskMb,
            currentDiskMb,
          ),
          ...(hasVmResourceReservationMetadata(vm.providerMetadata)
            ? { expectedReservation: existingReservation }
            : {}),
        }, input.providerVmId);
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
          cpu: input.cpu,
          memoryMb: input.memoryMb,
          previousCpu: current.cpus,
          previousMemoryMb: current.memoryTotalMb,
        },
      }).pipe(Effect.catchAll(() => Effect.void));
      return updated;
    }
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
    const diskMaxMb = maxDiskMbForPlan(planId);
    if (input.storageMb > diskMaxMb || input.storageMb % VM_DISK_MB_STEP !== 0) {
      return yield* Effect.fail(new VmResizeInvalidError({
        vmId: input.providerVmId,
        requestedMb: input.storageMb,
        currentMb,
        maxMb: diskMaxMb,
        reason: "above_max",
      }));
    }
    // Claim the new disk size under the same billing-team lock used by create.
    // The live repository always provides this method; test doubles from
    // before resource tracking may omit it and exercise provider behavior
    // without a database.
    yield* claimCompute;
    const storageMb = input.storageMb;
    const reserveDisk: Effect.Effect<VmResizeReservation | null, VmWorkflowError> = Effect.gen(function* () {
      if (!repo.reserveVmResize || !isPaidVmPlan(input.billingPlanId ?? vm.billingPlanId ?? "")) return null;
      const reserved = yield* repo.reserveVmResize({
        id: vm.id,
        userId: input.userId,
        billingTeamId: vm.billingTeamId ?? input.billingTeamId,
        providerVmId: input.providerVmId,
        currentDiskMb: currentMb,
        storageMb,
        maxActiveVms: input.maxActiveVms === undefined ? maxActiveVmsForPlan(vm.billingPlanId) : input.maxActiveVms,
      });
      if (!reserved) return yield* Effect.fail(new VmNotFoundError({ vmId: input.providerVmId }));
      return reserved;
    });
    // The provider has not been called when the disk claim fails, so the
    // compute claim goes back without a provider read.
    const reservation = yield* reserveDisk.pipe(
      Effect.tapError(() => computeClaim && repo.restoreVmComputeResize
        ? repo.restoreVmComputeResize({
          id: vm.id,
          expected: computeClaim.reserved,
          previous: computeClaim.previous,
        }).pipe(Effect.asVoid, Effect.catchAll(() => Effect.void))
        : Effect.void),
    );
    // A no-op request still backfills the durable reservation for legacy rows
    // whose provider metadata predates the resource tracking.
    if (input.storageMb === currentMb && !computeChanged) return current;
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
    yield* providers.resize(vm.provider, input.providerVmId, { storageMb: input.storageMb, cpu: input.cpu, memoryMb: input.memoryMb }).pipe(
      Effect.onExit(rollbackIfProviderDidNotGrow),
      Effect.onExit(releaseComputeClaim),
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
    // Keep the read-model reservation in sync with every provider-confirmed
    // dimension. Disk confirmation owns a generation; the compare-and-set
    // expected reservation prevents a concurrent resize from being clobbered.
    if (repo.setResourceReservation) {
      const existingReservation = vmResourceReservationFromMetadata(vm.providerMetadata);
      const confirmedReservation = reservationFromLegacyProviderStats(
        updated,
        existingReservation,
        confirmedDiskMb,
        input.storageMb,
      );
      const expectedReservation = reservation
        ? {
          ...existingReservation,
          diskMb: Math.max(reservation.reservedDiskMb, confirmedDiskMb),
        }
        : hasVmResourceReservationMetadata(vm.providerMetadata)
          ? existingReservation
          : undefined;
      yield* confirmResizedResourceReservation(repo.setResourceReservation, {
        id: vm.id,
        reservation: confirmedReservation,
        ...(expectedReservation === undefined ? {} : { expectedReservation }),
      }, input.providerVmId);
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
        ...(input.cpu === undefined ? {} : { cpu: input.cpu }),
        ...(input.memoryMb === undefined ? {} : { memoryMb: input.memoryMb }),
        ...(updated.cpus === undefined ? {} : { confirmedCpu: updated.cpus }),
        ...(updated.memoryTotalMb === undefined ? {} : { confirmedMemoryMb: updated.memoryTotalMb }),
      },
    }).pipe(Effect.catchAll(() => Effect.void));
    return updated;
  });
}

type ComputeResizeClaim = {
  readonly vm: CloudVmRow;
  readonly previous: VmComputeResources;
  readonly reserved: VmComputeResources;
};

/** Claim a CPU/memory growth against the plan's shared pool, when it has one. */
function reserveComputeResize(
  repo: VmRepositoryShape,
  vm: CloudVmRow,
  input: {
    readonly userId: string;
    readonly billingTeamId?: string | null;
    readonly providerVmId: string;
    readonly cpu?: number;
    readonly memoryMb?: number;
    readonly maxActiveVms?: number | null;
  },
  current: VMStats,
  planId: string,
): Effect.Effect<ComputeResizeClaim | null, VmWorkflowError> {
  const reserve = repo.reserveVmComputeResize;
  const pool = resourcePoolPolicyForPlan(
    planId,
    input.maxActiveVms === undefined ? maxActiveVmsForPlan(planId) : input.maxActiveVms,
  );
  if (!reserve || !pool || current.cpus === undefined || current.memoryTotalMb === undefined) {
    return Effect.succeed(null);
  }
  const marker = vmResourceReservationFromMetadata(vm.providerMetadata);
  const observedDiskMb = vmProviderResourceSize("diskMb", current.diskTotalMb);
  return reserve({
    id: vm.id,
    userId: input.userId,
    billingTeamId: vm.billingTeamId ?? input.billingTeamId,
    providerVmId: input.providerVmId,
    current: {
      vcpus: current.cpus,
      memoryMb: current.memoryTotalMb,
      diskMb: hasVmResourceReservationMetadata(vm.providerMetadata) ? marker.diskMb : observedDiskMb ?? VM_DISK_MB_MAX,
    },
    requested: {
      vcpus: input.cpu ?? current.cpus,
      memoryMb: input.memoryMb ?? current.memoryTotalMb,
    },
    resourcePool: pool,
  }).pipe(Effect.flatMap((claim) => claim
    ? Effect.succeed(claim)
    : Effect.fail(new VmNotFoundError({ vmId: input.providerVmId }))));
}

/**
 * Give back a compute claim only when a fresh provider read proves the VM is
 * still at its previous shape. A lost response after a real resize keeps the
 * larger claim, which over-counts the pool instead of under-counting it.
 */
function releaseUnappliedComputeResize(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  vm: CloudVmRow,
  providerVmId: string,
  claim: ComputeResizeClaim,
): Effect.Effect<void, never> {
  const restore = repo.restoreVmComputeResize;
  const getStats = providers.getStats;
  if (!restore || !getStats) return Effect.void;
  return getStats(vm.provider, providerVmId).pipe(
    Effect.flatMap((stats) => {
      const vcpus = vmProviderResourceSize("vcpus", stats.cpus);
      const memoryMb = vmProviderResourceSize("memoryMb", stats.memoryTotalMb);
      const unchanged = vcpus !== null && memoryMb !== null &&
        vcpus <= claim.previous.vcpus && memoryMb <= claim.previous.memoryMb;
      return unchanged
        ? restore({ id: vm.id, expected: claim.reserved, previous: claim.previous }).pipe(Effect.asVoid)
        : Effect.void;
    }),
    Effect.catchAll(() => Effect.void),
  );
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
  readonly modelPlane?: VmModelPlaneRevoker;
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
      { forceProviderProbe: true, maxActiveVms: input.maxActiveVms, callerPlanId: input.callerPlanId, modelPlane: input.modelPlane },
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
  /** Runs best-effort guest work after the response (the route passes `runAfterResponse`). */
  readonly deferAfterResponse?: (work: Effect.Effect<void>) => void;
  readonly modelPlane?: VmModelPlaneRevoker;
}) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const vm = yield* requireAccessibleUserVm(input);
    const supportedTransports = providers.attachTransports?.(vm.provider);
    if (supportedTransports && !supportedTransports.includes("cmux-remote")) {
      return yield* Effect.fail(new VmAttachTransportUnsupportedError({
        provider: vm.provider,
        vmId: input.providerVmId,
        requested: "cmux-remote",
        supported: supportedTransports,
      }));
    }
    if (!providers.openCmuxRemote) {
      return yield* Effect.fail(
        new VmProviderOperationError({
          provider: vm.provider,
          operation: "openCmuxRemote",
          cause: new VmOperationUnsupportedError({ provider: vm.provider, operation: "openCmuxRemote" }),
        }),
      );
    }
    yield* preflightResumeIfSuspended(
      repo,
      providers,
      vm,
      input.providerVmId,
      "attach",
      { forceProviderProbe: true, maxActiveVms: input.maxActiveVms, callerPlanId: input.callerPlanId, modelPlane: input.modelPlane },
    );
    const endpoint = yield* withResumeOnSuspendedAfterFailure(
      repo,
      providers,
      vm,
      input.providerVmId,
      "attach",
      providers.openCmuxRemote(vm.provider, input.providerVmId, {
        promptIdentity: vmPromptIdentity(vm),
        deviceFingerprint: input.deviceFingerprint,
        clientCapabilities: input.clientCapabilities,
        providerMetadata: vm.providerMetadata,
      }),
      input.maxActiveVms,
      input.callerPlanId,
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
    // Only an opted-in machine pays this exec; the default attach stays exec-free.
    if (vmAgentUpdatesFromRow(vm) === "latest") {
      yield* scheduleGuestAgentUpdates(providers, vm, "latest", input.deferAfterResponse);
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
          cause: new VmOperationUnsupportedError({ provider: vm.provider, operation: "approveCmuxRemoteEnrollment" }),
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
  readonly modelPlane?: VmModelPlaneRevoker;
};

export function openAttachEndpoint(input: OpenAttachEndpointInput) {
  return Effect.gen(function* () {
    const result = yield* openAttachEndpointResult(input);
    return result.endpoint;
  });
}

export function prepareScpEndpoint(input: {
  readonly publicKey: string;
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
  readonly callerPlanId?: string | null;
  readonly maxActiveVms?: number | null;
  readonly modelPlane?: VmModelPlaneRevoker;
}) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const vm = yield* requireAccessibleUserVm(input);
    if (!providers.prepareSCP) return yield* Effect.fail(new VmOperationUnsupportedError({ provider: vm.provider, operation: "prepareSCP" }));
    if (vm.status === "destroyed") return yield* Effect.fail(new VmNotFoundError({ vmId: input.providerVmId }));
    yield* preflightResumeIfSuspended(repo, providers, vm, input.providerVmId, "scp", {
      forceProviderProbe: true, maxActiveVms: input.maxActiveVms, callerPlanId: input.callerPlanId, modelPlane: input.modelPlane,
    });
    const endpoint = yield* withResumeOnSuspendedAfterFailure(
      repo,
      providers,
      vm,
      input.providerVmId,
      "scp",
      providers.prepareSCP(vm.provider, input.providerVmId, input.publicKey),
      input.maxActiveVms,
      input.callerPlanId,
    );
    yield* repo.recordUsageEvent({
      userId: input.userId,
      billingTeamId: vm.billingTeamId,
      billingPlanId: vm.billingPlanId,
      vmId: vm.id,
      eventType: "vm.scp_endpoint",
      provider: vm.provider,
      imageId: vm.imageId,
      metadata: { transport: "wireguard-scp", expiresAtUnix: endpoint.expiresAtUnix },
    }).pipe(Effect.catchAll(() => Effect.void));
    return endpoint;
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
  readonly modelPlane?: VmModelPlaneRevoker;
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
    modelPlane: input.modelPlane,
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
      { forceProviderProbe: true, maxActiveVms: input.maxActiveVms, callerPlanId: input.callerPlanId, modelPlane: input.modelPlane },
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
      input.callerPlanId,
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
    let vm = yield* requireUserVm(input);
    if (input.callerPlanId === "go") {
      yield* requireGoShape("go", hasVmResourceReservationMetadata(vm.providerMetadata) ? vmResourceReservationFromMetadata(vm.providerMetadata) : null);
    }
    if (input.callerPlanId && vm.billingPlanId !== input.callerPlanId &&
      (input.callerPlanId === "go" || vm.billingPlanId === "go")) {
      const billingPlanId = input.callerPlanId;
      if (vm.billingPlanId === "go" && billingPlanId !== "go" && isPaidVmPlan(billingPlanId)) {
        const providers = yield* VmProviderGateway;
        yield* setRuntimeBudget(providers, vm, input.providerVmId, null);
      }
      yield* Effect.tryPromise({
        try: () => cloudDb().update(cloudVms).set({ billingPlanId }).where(eq(cloudVms.id, vm.id)),
        catch: (cause) => new VmDatabaseError({ operation: "sync_vm_billing_plan", cause }),
      });
      vm = { ...vm, billingPlanId };
    }
    if (vm.providerMetadata[GO_PAUSE_INTENT_KEY] != null) {
      const repo = yield* VmRepository;
      if (vm.billingPlanId === "go") {
        const providers = yield* VmProviderGateway;
        yield* pauseGoVm(repo, providers, vm, input.providerVmId);
        vm = { ...vm, status: "paused" };
      } else {
        if (!repo.mergeProviderMetadata) return yield* Effect.fail(new VmDatabaseError({ operation: "cancel_go_pause", cause: "Durable metadata writes are unavailable" }));
        yield* repo.mergeProviderMetadata({ id: vm.id, patch: { [GO_PAUSE_INTENT_KEY]: null } });
      }
      vm = { ...vm, providerMetadata: { ...vm.providerMetadata, [GO_PAUSE_INTENT_KEY]: null } };
    }
    if (input.callerPlanId && isPaidVmPlan(input.callerPlanId)) {
      yield* requireMachineFitsPlan(input.callerPlanId, vm.providerMetadata);
    }
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
  const billingTeamId = vm.ownerTeamId?.trim();
  if (!billingTeamId) return false;
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
    /**
     * Set by the Base flow. createVm and forkVm own a plain row, so failing it
     * is the whole rollback. A Base row is also claimed by a base and a
     * generation, and markBaseCreateFailed is the mark on this path that
     * releases those; marking it with the ad-hoc path leaves the base
     * "resetting" and its generation "creating". (markCreateAbandoned and
     * resolveCreateCleanup also call restoreBaseAfterCreateFailure, but neither
     * is reachable from here once the row carries a failure code.)
     *
     * Reset then 409s forever, because beginBaseReset refuses to start while an
     * operation is in flight. Open does not: it has no such guard and the
     * ad-hoc-failed row is not the active one, so it quietly allocates a new
     * generation on a new provider machine and orphans the working one as
     * retained. That still counts against maxActiveVms, so a user at their
     * machine limit is stuck until they delete one by hand.
     *
     * The abandonment sweeper cannot recover either shape, because it matches
     * only provisioning rows with no failure code, and the ad-hoc mark sets
     * both.
     */
    readonly baseGeneration?: {
      readonly baseId: string;
      readonly generation: number;
    };
  },
  vm: CloudVmRow,
) {
  const markCreateFailed = (code: string, message: string) =>
    input.baseGeneration
      ? repo.markBaseCreateFailed({
        baseId: input.baseGeneration.baseId,
        generation: input.baseGeneration.generation,
        vmId: vm.id,
        userId: input.userId,
        code,
        message,
      })
      : repo.markCreateFailed({ id: vm.id, code, message });
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
            recordCreateFailureAfterMark(repo, markCreateFailed(
              isVmCreateCreditsInsufficientError(err)
                ? "billing_credits_insufficient"
                : "billing_reserve_failed",
              errorMessage(err),
            ), {
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

type CreateSuccessEventInput = {
  readonly idempotencyKey?: string;
  readonly timing?: VmTimingSink;
  readonly origin?: VmCreateOrigin;
  readonly memoryMb?: number;
  readonly persistentHome?: boolean;
  readonly perMachineHome?: boolean;
  readonly imageSize?: CreateOptions["imageSize"];
};

function createSuccessUsageEvents(input: CreateSuccessEventInput, running: CloudVmRow): VmUsageEventInput[] {
  return [
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
  ];
}

function recordCreateSuccessEvents(
  repo: VmRepositoryShape,
  input: CreateSuccessEventInput,
  running: CloudVmRow,
) {
  return measureVmEffect(
    input.timing,
    "usage_events",
    repo.recordUsageEvents(createSuccessUsageEvents(input, running)).pipe(Effect.catchAll(() => Effect.void)),
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

/** Records a failure only when its guarded lifecycle transition won the row. */
function recordCreateFailureAfterMark(
  repo: VmRepositoryShape,
  marked: Effect.Effect<boolean, VmDatabaseError>,
  event: VmUsageEventInput,
): Effect.Effect<void, VmDatabaseError> {
  return marked.pipe(
    Effect.flatMap((updated) => updated ? repo.recordUsageEvent(event) : Effect.void),
  );
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
    createdByUserId: row.userId,
    ownerTeamId: row.ownerTeamId,
    addressIpv4: typeof addressIpv4 === "string" && addressIpv4 ? addressIpv4 : null,
    addressIpv6: typeof addressIpv6 === "string" && addressIpv6 ? addressIpv6 : null,
    cmuxTuiContract: typeof metadata["cmuxTuiContract"] === "string" ? metadata["cmuxTuiContract"] : null,
    agentUpdates: vmAgentUpdatesFromRow(row),
    resourceReservation: hasVmResourceReservationMetadata(row.providerMetadata)
      ? (({ vcpus, memoryMb }) => ({ vcpus, memoryMb }))(vmResourceReservationFromMetadata(row.providerMetadata))
      : null,
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

// ---------------------------------------------------------------------------
// Outbound network policy (services/vms/networkPolicy.ts)

export type VmNetworkPolicyStatus = {
  readonly state: "applied" | "pending" | "failed";
  readonly error?: string;
  readonly appliedAt?: string;
};

export type VmNetworkPolicyView = {
  readonly policy: NetworkPolicy;
  readonly status: VmNetworkPolicyStatus;
};

/**
 * Store a create's policy on its new row before the provider call. Fails
 * closed: a restricted machine whose policy is not recorded would show as open
 * and be reconciled open by the next edit.
 */
function recordCreateNetworkPolicy(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  input: CreateVmInput,
  rowId: string,
): Effect.Effect<NetworkRulePlan | undefined, VmOperationUnsupportedError | VmDatabaseError> {
  const policy = input.networkPolicy;
  if (!policy) return Effect.succeed(undefined);
  const plan = compileNetworkPolicy(policy);
  return requireNetworkPolicySupport(providers, input.provider, plan).pipe(
    Effect.andThen(storeNetworkPolicy(repo, rowId, policy, { state: "pending" })),
    Effect.tapError((err) => repo.markCreateFailed({
      id: rowId,
      code: PROVIDER_CREATE_UNAVAILABLE_FAILURE_CODE,
      message: errorMessage(err),
    }).pipe(Effect.catchAll(() => Effect.void))),
    Effect.as(plan),
  );
}

/** The create installed the rules itself; the status row is display state only. */
function markCreateNetworkPolicyApplied(repo: VmRepositoryShape, input: CreateVmInput, rowId: string): Effect.Effect<void> {
  if (!input.networkPolicy || !repo.setNetworkPolicy) return Effect.void;
  return repo.setNetworkPolicy({ id: rowId, status: appliedNetworkStatus() }).pipe(Effect.catchAll(() => Effect.void));
}

/** A stored policy that restricts egress, or undefined for full Internet (including legacy rows). */
function restrictedNetworkPolicy(value: unknown): NetworkPolicy | undefined {
  if (value === null || value === undefined) return undefined;
  const policy = storedNetworkPolicy(value);
  return compileNetworkPolicy(policy).publicEgress ? undefined : policy;
}

function appliedNetworkStatus(): VmNetworkPolicyStatus {
  return { state: "applied", appliedAt: new Date().toISOString() };
}

function storedNetworkStatus(value: unknown, hasPolicy: boolean): VmNetworkPolicyStatus {
  if (value && typeof value === "object" && !Array.isArray(value)) {
    const { state, error, appliedAt } = value as Record<string, unknown>;
    if (state === "applied" || state === "pending" || state === "failed") {
      return {
        state,
        ...(typeof error === "string" ? { error } : {}),
        ...(typeof appliedAt === "string" ? { appliedAt } : {}),
      };
    }
  }
  // A legacy row has no stored policy and was created with full egress.
  return { state: hasPolicy ? "pending" : "applied" };
}

function storeNetworkPolicy(
  repo: VmRepositoryShape,
  id: string,
  policy: NetworkPolicy,
  status: VmNetworkPolicyStatus,
): Effect.Effect<void, VmDatabaseError> {
  if (!repo.setNetworkPolicy) {
    return Effect.fail(new VmDatabaseError({ operation: "setNetworkPolicy", cause: new Error("repository cannot store network policy") }));
  }
  return repo.setNetworkPolicy({ id, policy: { ...policy }, status: { ...status } });
}

/** Only a restricted plan needs provider egress control; full egress is every provider's default. */
function requireNetworkPolicySupport(
  providers: VmProviderGatewayShape,
  provider: ProviderId,
  plan: NetworkRulePlan,
): Effect.Effect<void, VmOperationUnsupportedError> {
  if (plan.publicEgress || providers.applyNetworkPolicy) return Effect.void;
  return Effect.fail(new VmOperationUnsupportedError({ provider, operation: "applyNetworkPolicy" }));
}

export function getVmNetworkPolicy(input: ExistingVmAccessInput): VmWorkflowProgram<VmNetworkPolicyView> {
  return Effect.gen(function* () {
    const vm = yield* requireAccessibleUserVm(input);
    return {
      policy: storedNetworkPolicy(vm.networkPolicy),
      status: storedNetworkStatus(vm.networkPolicyStatus, vm.networkPolicy != null),
    };
  });
}

/**
 * Store and apply a machine's outbound policy. The row records the intent
 * first; the provider then converges the live rules (no restart, and a paused
 * machine is not woken: Freestyle rules live outside the VM). A provider
 * failure leaves the policy stored with a `failed` status the UI surfaces, and
 * the next save retries the whole reconcile.
 */
export function updateVmNetworkPolicy(input: ExistingVmAccessInput & {
  readonly policy: NetworkPolicy;
}): VmWorkflowProgram<VmNetworkPolicyView> {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const vm = yield* requireAccessibleUserVm(input);
    const plan = compileNetworkPolicy(input.policy);
    yield* requireNetworkPolicySupport(providers, vm.provider, plan);
    if (!providers.applyNetworkPolicy) {
      return yield* Effect.fail(new VmOperationUnsupportedError({ provider: vm.provider, operation: "applyNetworkPolicy" }));
    }
    yield* storeNetworkPolicy(repo, vm.id, input.policy, { state: "pending" });
    const applied = yield* Effect.either(providers.applyNetworkPolicy(vm.provider, input.providerVmId, plan));
    const status: VmNetworkPolicyStatus = Either.isRight(applied)
      ? appliedNetworkStatus()
      : { state: "failed", error: errorMessage(applied.left) };
    yield* repo.setNetworkPolicy!({ id: vm.id, status: { ...status } });
    if (Either.isLeft(applied)) return yield* Effect.fail(applied.left);
    return { policy: input.policy, status };
  });
}
