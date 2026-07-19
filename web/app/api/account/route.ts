import { and, asc, eq, inArray, isNotNull, isNull, not, or, sql } from "drizzle-orm";
import * as Effect from "effect/Effect";

import { getStackServerApp, isStackConfigured } from "../../lib/stack";
import { cloudDb } from "../../../db/client";
import {
  accountDeletionTombstones,
  billingEmailClaims,
  cloudVmBaseEvents,
  cloudVmBaseGenerations,
  cloudVmBases,
  cloudVmBillingGrants,
  cloudVmLeases,
  cloudVmNotificationDeliveries,
  cloudVmNotificationEvents,
  cloudVmSessions,
  cloudVmUsageEvents,
  cloudVms,
  deviceTokens,
  devices,
  notificationSendEvents,
  stripeCustomers,
  stripeSubscriptions,
  subrouterTenants,
  vaultCliAuthRequests,
  vaultSessions,
  vaultSnapshots,
  vaultUploadGrants,
  vaultUploadTombstones,
} from "../../../db/schema";
import {
  ACTIVE_STRIPE_PRO_STATUSES,
  type ProMetadataJson,
  type ProMetadataCustomer,
} from "../../../services/billing/pro";
import { isAscConfigured } from "../../../services/asc/client";
import { removeTester } from "../../../services/asc/testflight";
import { captureAscError } from "../../../services/errors";
import { isStripeBillingConfigured, stripe } from "../../../services/billing/stripe";
import {
  createSubrouterClientFromEnv,
  SubrouterClientError,
} from "../../../services/subrouter/client";
import { deleteObject } from "../../../services/vault/storage";
import { withVaultUserQuotaLock } from "../../../services/vault/usage";
import {
  AccountDeletionAnalyticsForwardInProgressError,
  accountDeletionAdvisoryLockKey,
  accountDeletionUserHash,
  assertNoAccountAnalyticsForwardInProgress,
  isBlockingAccountDeletionTombstone,
} from "../../../services/account/deletionLock";
import { unauthorized } from "../../../services/vms/auth";
import {
  VmAccountDeletionIdentityRevocationError,
  isVmAccountDeletionIdentityRevocationError,
  isVmProviderOperationError,
  vmWorkflowErrorCause,
} from "../../../services/vms/errors";
import type { ProviderId } from "../../../services/vms/drivers";
import { jsonResponse } from "../../../services/vms/routeHelpers";
import {
  destroyVm,
  listUserVms,
  revokeUserIdentityLeasesForAccountDeletion,
  runVmWorkflow,
} from "../../../services/vms/workflows";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const VAULT_OBJECT_DELETE_BATCH_SIZE = 100;
const DELETED_ACCOUNT_ACTOR_ID = "deleted-account";
const POSTHOG_DEFAULT_API_HOST = "https://us.posthog.com";
const POSTHOG_PERSON_DELETE_TIMEOUT_MS = 10_000;

type DeletableStackUser = {
  readonly id: string;
  readonly primaryEmail?: string | null;
  readonly selectedTeam?: unknown;
  readonly listTeams?: (options?: StackPaginationOptions) => Promise<StackPaginationPage>;
  readonly delete: () => Promise<void>;
} & ProMetadataCustomer;

type AccountDeletionStackTeam = {
  readonly id: string;
  readonly listUsers?: (options?: StackPaginationOptions) => Promise<StackPaginationPage>;
};

type RetainedTeamBillingOwner = {
  readonly stackTeamId: string;
  readonly stackUserId: string;
};

type PostHogPersonDeletionConfig = {
  readonly apiHost: string;
  readonly environmentId: string;
  readonly personalApiKey: string;
};

type StackPaginationOptions = {
  readonly cursor?: string;
  readonly limit?: number;
};

type StackPaginationPage = readonly unknown[] & {
  readonly nextCursor?: string | null;
};

type AccountDeletionTombstoneStart =
  | { readonly kind: "started" }
  | { readonly kind: "pending" }
  | { readonly kind: "completed" }
  | { readonly kind: "cleanupIncomplete" };

export async function DELETE(request: Request): Promise<Response> {
  const stackUser = await currentDeletableStackUser(request);
  if (!stackUser) return unauthorized();

  const userId = stackUser.id;
  const originalStackMetadata = stackUser.clientReadOnlyMetadata;
  let stackMetadataMarked = false;
  let accountDeletionTombstoneStarted = false;
  let cmuxOwnedRowsDeleted = false;
  let analyticsCleanupStarted = false;
  let destructiveCleanupStarted = false;
  let destroyedVms = 0;
  let restoreBillingEntitlementsOnFailure = true;
  try {
    const tombstoneStart = await markAccountDeletionTombstonePending(userId);
    accountDeletionTombstoneStarted = tombstoneStart.kind === "started";
    if (tombstoneStart.kind === "pending") {
      return jsonResponse({ ok: true, deletionPending: true, destroyedVms: 0 }, 202);
    }
    if (tombstoneStart.kind === "completed") {
      return jsonResponse({ ok: true, destroyedVms: 0 }, 200);
    }
    if (tombstoneStart.kind === "cleanupIncomplete") {
      const accountScope = await accountDeletionScopeForUser(stackUser);
      // PostHog deletion completed before the Stack user was removed. A
      // cleanup-incomplete tombstone represents only the idempotent cmux-owned
      // cleanup that follows Stack deletion, so retrying PostHog here can block
      // tombstone completion after the account itself is already gone.
      await finishPostStackAccountCleanup(userId, accountScope.teamIds, {
        deletePostHogPerson: false,
      });
      await markAccountDeletionTombstoneCompleted(userId);
      return jsonResponse({ ok: true, destroyedVms: 0 }, 200);
    }
    // Validate required production configuration before metadata, billing,
    // access, VM, vault, or tenant cleanup can mutate the account. Pass the
    // validated snapshot to the later request so environment changes cannot
    // introduce a second validation failure after destructive work begins.
    const postHogDeletionConfig = postHogPersonDeletionConfig();
    const accountScope = await accountDeletionScopeForUser(stackUser);
    // The tombstone blocks new forwards before this fail-prone external call.
    // Complete analytics deletion before billing, access, VM, vault, tenant,
    // or Stack cleanup so a retryable PostHog failure leaves those resources
    // intact and the signed-in user can safely retry.
    await deletePostHogPersonForAccountDeletion(userId, {
      config: postHogDeletionConfig,
      beforeExternalRequest: () => {
        analyticsCleanupStarted = true;
      },
      afterExternalMutation: async () => {
        await markAccountDeletionTombstoneAnalyticsDeleted(userId);
      },
    });
    await markAccountDeletingAndClearBillingEntitlements(stackUser);
    stackMetadataMarked = true;
    await resolveUserBillingForAccountDeletion(
      userId,
      accountScope.teamIds,
      accountScope.retainedTeamBillingOwners,
      {
        beforeExternalRequest: () => {
          restoreBillingEntitlementsOnFailure = false;
          destructiveCleanupStarted = true;
        },
        afterExternalMutation: async () => {
          await refreshAccountDeletionTombstoneLease(userId);
        },
      },
    );
    await removeTestFlightAccessForAccountDeletion(stackUser, {
      afterExternalMutation: () => {
        restoreBillingEntitlementsOnFailure = false;
        destructiveCleanupStarted = true;
      },
    });
    await refreshAccountDeletionTombstoneLease(userId);
    try {
      const revokedIdentityLeases = await revokeAccountDeletionIdentityLeases(userId, {
        afterBatch: async () => {
          await refreshAccountDeletionTombstoneLease(userId);
        },
      });
      if (revokedIdentityLeases > 0) destructiveCleanupStarted = true;
    } catch (error) {
      if (isVmAccountDeletionIdentityRevocationError(error)) destructiveCleanupStarted = true;
      throw error;
    }
    await refreshAccountDeletionTombstoneLease(userId);
    try {
      destroyedVms = await destroyPersonalCloudVms(userId, accountScope.teamIds, {
        afterVmDestroy: async () => {
          await refreshAccountDeletionTombstoneLease(userId);
        },
      });
      if (destroyedVms > 0) destructiveCleanupStarted = true;
    } catch (error) {
      if (error instanceof AccountDeletionDestructiveCleanupError) {
        destroyedVms = error.destroyedVms;
        destructiveCleanupStarted = destructiveCleanupStarted || error.destructiveCleanupStarted;
      }
      throw error;
    }
    await deleteVaultRowsAndObjectsForAccount(userId, {
      beforeObjectDeletion: () => {
        destructiveCleanupStarted = true;
      },
      afterObjectDeletion: async () => {
        await refreshAccountDeletionTombstoneLease(userId);
      },
    });
    await deletePersonalSubrouterTenant(userId, {
      afterExternalMutation: () => {
        destructiveCleanupStarted = true;
      },
    }, accountScope.teamIds);
    await refreshAccountDeletionTombstoneLease(userId);
    // Delete cmux-owned data before the Stack user so a Stack-side failure does
    // not strand retained app data behind an account the user can no longer use.
    // These deletes are idempotent, so the same signed-in user can retry the
    // final Stack deletion when the distinct response below is returned.
    await deleteCmuxOwnedAccountRows(userId, accountScope.teamIds);
    cmuxOwnedRowsDeleted = true;
    try {
      await markAccountDeletionTombstoneStackDeletePending(userId);
      await stackUser.delete();
    } catch (error) {
      logAccountDeleteError("account.delete.stack_user_failed_after_data_delete", error);
      if (accountDeletionTombstoneStarted) await markAccountDeletionTombstoneFailed(userId, error);
      return jsonResponse({
        error: "account_delete_retryable",
        retryable: true,
        destroyedVms,
      }, 500);
    }
    try {
      await finishPostStackAccountCleanup(userId, accountScope.teamIds, {
        deletePostHogPerson: false,
      });
      await markAccountDeletionTombstoneCompleted(userId);
    } catch (error) {
      logAccountDeleteError("account.delete.post_stack_cleanup_failed", error);
      if (accountDeletionTombstoneStarted) {
        try {
          await markAccountDeletionTombstoneCleanupIncomplete(userId, error);
        } catch (markIncompleteError) {
          logAccountDeleteError("account.delete.post_stack_cleanup_mark_incomplete", markIncompleteError);
        }
      }
      return jsonResponse({
        ok: true,
        cleanupIncomplete: true,
        destroyedVms,
      }, 202);
    }
    return jsonResponse({ ok: true, destroyedVms });
  } catch (error) {
    if (destructiveCleanupStarted || cmuxOwnedRowsDeleted) {
      if (accountDeletionTombstoneStarted) await markAccountDeletionTombstoneFailed(userId, error);
      logAccountDeleteError("account.delete.partial_after_destructive_cleanup", error);
      return jsonResponse({
        error: "account_delete_retryable",
        retryable: true,
        destroyedVms,
      }, 500);
    }
    if (stackMetadataMarked) {
      await restoreStackMetadataAfterAccountDeletionFailure(stackUser, originalStackMetadata, {
        restoreBillingEntitlements: restoreBillingEntitlementsOnFailure,
      });
    }
    if (accountDeletionTombstoneStarted) await markAccountDeletionTombstoneFailed(userId, error);
    logAccountDeleteError("account.delete.failed", error);
    if (
      analyticsCleanupStarted ||
      error instanceof AccountDeletionAnalyticsForwardInProgressError
    ) {
      return jsonResponse({
        error: "account_delete_retryable",
        retryable: true,
        destroyedVms,
      }, 500);
    }
    return jsonResponse({ error: "account_delete_failed" }, 500);
  }
}

async function currentDeletableStackUser(request: Request): Promise<DeletableStackUser | null> {
  if (!isStackConfigured()) return null;

  const authHeader = request.headers.get("authorization");
  const refreshHeader = request.headers.get("x-stack-refresh-token");
  if (!authHeader?.toLowerCase().startsWith("bearer ") || !refreshHeader) return null;

  const accessToken = authHeader.slice("bearer ".length).trim();
  const refreshToken = refreshHeader.trim();
  if (!accessToken || !refreshToken) return null;

  const user = await getStackServerApp().getUser({
    tokenStore: { accessToken, refreshToken },
  });
  const candidate = user as Partial<DeletableStackUser>;
  if (!user || typeof candidate.delete !== "function" || typeof candidate.update !== "function") return null;
  return user as DeletableStackUser;
}

async function markAccountDeletionTombstonePending(userId: string): Promise<AccountDeletionTombstoneStart> {
  const db = cloudDb();
  const now = new Date();
  const userIdHash = accountDeletionUserHash(userId);
  return await db.transaction(async (tx) => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${accountDeletionAdvisoryLockKey(userId)}, 0))`);
    const [existing] = await tx
      .select({
        userIdHash: accountDeletionTombstones.userIdHash,
        status: accountDeletionTombstones.status,
        updatedAt: accountDeletionTombstones.updatedAt,
      })
      .from(accountDeletionTombstones)
      .where(eq(accountDeletionTombstones.userIdHash, userIdHash))
      .limit(1);
    if (existing?.status === "completed") return { kind: "completed" };
    if (existing?.status === "cleanup_incomplete") return { kind: "cleanupIncomplete" };
    if (existing && isBlockingAccountDeletionTombstone(existing, now)) {
      return { kind: "pending" };
    }

    await tx
      .insert(accountDeletionTombstones)
      .values({
        userId,
        userIdHash,
        status: "pending",
        attemptCount: 1,
        updatedAt: now,
        errorMessage: null,
      })
      .onConflictDoUpdate({
        target: accountDeletionTombstones.userIdHash,
        set: {
          userId,
          status: "pending",
          updatedAt: now,
          attemptCount: sql`${accountDeletionTombstones.attemptCount} + 1`,
          errorMessage: null,
        },
      });
    return { kind: "started" };
  });
}

async function markAccountDeletionTombstoneCompleted(userId: string): Promise<void> {
  const now = new Date();
  await cloudDb()
    .update(accountDeletionTombstones)
    .set({
      userId: null,
      status: "completed",
      updatedAt: now,
      completedAt: now,
      errorMessage: null,
    })
    .where(eq(accountDeletionTombstones.userIdHash, accountDeletionUserHash(userId)));
}

async function markAccountDeletionTombstoneAnalyticsDeleted(userId: string): Promise<void> {
  const now = new Date();
  await cloudDb()
    .update(accountDeletionTombstones)
    .set({ analyticsDeletedAt: now, updatedAt: now })
    .where(eq(accountDeletionTombstones.userIdHash, accountDeletionUserHash(userId)));
}

async function markAccountDeletionTombstoneFailed(userId: string, error: unknown): Promise<void> {
  await cloudDb()
    .update(accountDeletionTombstones)
    .set({
      status: "failed",
      updatedAt: new Date(),
      errorMessage: sanitizedErrorSummary(error),
    })
    .where(eq(accountDeletionTombstones.userIdHash, accountDeletionUserHash(userId)));
}

async function markAccountDeletionTombstoneStackDeletePending(userId: string): Promise<void> {
  await cloudDb()
    .update(accountDeletionTombstones)
    .set({
      status: "stack_delete_pending",
      updatedAt: new Date(),
      errorMessage: null,
    })
    .where(eq(accountDeletionTombstones.userIdHash, accountDeletionUserHash(userId)));
}

async function markAccountDeletionTombstoneCleanupIncomplete(userId: string, error: unknown): Promise<void> {
  const now = new Date();
  await cloudDb()
    .update(accountDeletionTombstones)
    .set({
      userId: null,
      status: "cleanup_incomplete",
      updatedAt: now,
      completedAt: now,
      errorMessage: sanitizedErrorSummary(error),
    })
    .where(eq(accountDeletionTombstones.userIdHash, accountDeletionUserHash(userId)));
}

async function refreshAccountDeletionTombstoneLease(userId: string): Promise<void> {
  await cloudDb()
    .update(accountDeletionTombstones)
    .set({ updatedAt: new Date() })
    .where(and(
      eq(accountDeletionTombstones.userIdHash, accountDeletionUserHash(userId)),
      inArray(accountDeletionTombstones.status, [
        "pending",
        "in_progress",
        "stack_delete_pending",
        "stack_delete_in_progress",
      ]),
    ));
}

class AccountDeletionDestructiveCleanupError extends Error {
  constructor(
    message: string,
    readonly destroyedVms: number,
    readonly destructiveCleanupStarted: boolean,
  ) {
    super(message);
    this.name = "AccountDeletionDestructiveCleanupError";
  }
}

async function revokeAccountDeletionIdentityLeases(
  userId: string,
  options: { readonly afterBatch?: () => Promise<void> } = {},
): Promise<number> {
  return await runVmWorkflow(
    revokeUserIdentityLeasesForAccountDeletion(userId, {
      afterBatch: () =>
        Effect.tryPromise({
          try: async () => {
            await options.afterBatch?.();
          },
          catch: (cause) => new VmAccountDeletionIdentityRevocationError({ cause }),
        }),
    }),
  );
}

async function destroyPersonalCloudVms(
  userId: string,
  accountTeamIds: readonly string[],
  options: { readonly afterVmDestroy?: () => Promise<void> } = {},
): Promise<number> {
  const vms = await listAccountDeletionCloudVms(userId, accountTeamIds);
  const failures: unknown[] = [];
  let destroyedVms = 0;
  let destructiveCleanupStarted = false;
  for (const vm of vms) {
    try {
      const destroyInput: {
        userId: string;
        billingTeamId?: string | null;
        teamIds: readonly string[];
        providerVmId: string;
        provider: ProviderId;
        afterProviderDestroy: () => void;
      } = {
        userId,
        teamIds: accountTeamIds,
        providerVmId: vm.providerVmId,
        provider: vm.provider,
        afterProviderDestroy: () => {
          destructiveCleanupStarted = true;
        },
      };
      if (vm.billingTeamId) destroyInput.billingTeamId = vm.billingTeamId;
      const destroyProgram = destroyVm(destroyInput);
      await runVmWorkflow(destroyProgram);
      destructiveCleanupStarted = true;
      destroyedVms += 1;
      await options.afterVmDestroy?.();
    } catch (error) {
      if (didVmDestroyReachProvider(error)) destructiveCleanupStarted = true;
      failures.push(error);
      logAccountDeleteError("account.delete.vm_destroy_failed", error);
    }
  }
  if (failures.length > 0) {
    throw new AccountDeletionDestructiveCleanupError(
      `Failed to destroy ${failures.length} personal cloud VM${failures.length === 1 ? "" : "s"}`,
      destroyedVms,
      destructiveCleanupStarted,
    );
  }
  return destroyedVms;
}

function didVmDestroyReachProvider(error: unknown): boolean {
  const workflowError = vmWorkflowErrorCause(error) ?? error;
  return isVmProviderOperationError(workflowError) && workflowError.operation === "destroy";
}

async function listAccountDeletionCloudVms(
  userId: string,
  accountTeamIds: readonly string[],
): Promise<Array<{ readonly providerVmId: string; readonly provider: ProviderId; readonly billingTeamId?: string | null }>> {
  type ListedVm = { readonly providerVmId?: string | null; readonly provider: ProviderId };
  const vms = new Map<
    string,
    { readonly providerVmId: string; readonly provider: ProviderId; readonly billingTeamId?: string | null }
  >();
  const legacyScopedVms: readonly ListedVm[] = await runVmWorkflow(listUserVms(userId));
  for (const vm of legacyScopedVms) {
    const providerVmId = vm.providerVmId;
    if (!providerVmId) continue;
    vms.set(accountDeletionVmKey({ provider: vm.provider, providerVmId }), {
      providerVmId,
      provider: vm.provider,
    });
  }
  for (const teamId of accountTeamIds) {
    if (teamId === userId) continue;
    const teamScopedVms: readonly ListedVm[] = await runVmWorkflow(listUserVms(userId, teamId));
    for (const vm of teamScopedVms) {
      const providerVmId = vm.providerVmId;
      if (!providerVmId) continue;
      vms.set(accountDeletionVmKey({ provider: vm.provider, providerVmId }), {
        providerVmId,
        provider: vm.provider,
        billingTeamId: teamId,
      });
    }
  }
  return [...vms.values()];
}

function accountDeletionVmKey(vm: { readonly provider: ProviderId; readonly providerVmId: string }): string {
  return `${vm.provider}:${vm.providerVmId}`;
}

async function deleteVaultRowsAndObjectsForAccount(
  userId: string,
  options: {
    readonly beforeObjectDeletion?: () => void;
    readonly afterObjectDeletion?: () => Promise<void>;
  } = {},
): Promise<void> {
  const db = cloudDb();
  await withVaultUserQuotaLock(db, userId, async (lockedDb) => {
    await deleteVaultRowsAndObjectsForAccountLocked(lockedDb, userId, options);
  });
}

async function deleteVaultRowsAndObjectsForAccountLocked(
  db: ReturnType<typeof cloudDb>,
  userId: string,
  options: {
    readonly beforeObjectDeletion?: () => void;
    readonly afterObjectDeletion?: () => Promise<void>;
  },
): Promise<void> {
  for (;;) {
    const snapshots = await db
      .select({ id: vaultSnapshots.id, objectKey: vaultSnapshots.objectKey })
      .from(vaultSnapshots)
      .innerJoin(vaultSessions, eq(vaultSnapshots.sessionId, vaultSessions.id))
      .where(eq(vaultSessions.userId, userId))
      .orderBy(asc(vaultSnapshots.id))
      .limit(VAULT_OBJECT_DELETE_BATCH_SIZE);
    if (snapshots.length === 0) break;
    options.beforeObjectDeletion?.();
    await Promise.all(snapshots.map((snapshot) => deleteObject(snapshot.objectKey)));
    await db.delete(vaultSnapshots).where(inArray(vaultSnapshots.id, snapshots.map((snapshot) => snapshot.id)));
    await options.afterObjectDeletion?.();
    if (snapshots.length < VAULT_OBJECT_DELETE_BATCH_SIZE) break;
  }

  for (;;) {
    const grants = await db
      .select({
        id: vaultUploadGrants.id,
        objectKey: vaultUploadGrants.objectKey,
        uploadObjectKey: vaultUploadGrants.uploadObjectKey,
      })
      .from(vaultUploadGrants)
      .where(eq(vaultUploadGrants.userId, userId))
      .orderBy(asc(vaultUploadGrants.id))
      .limit(VAULT_OBJECT_DELETE_BATCH_SIZE);
    if (grants.length === 0) break;
    options.beforeObjectDeletion?.();
    await Promise.all(grants.flatMap((grant) => [
      deleteObject(grant.objectKey),
      deleteObject(grant.uploadObjectKey),
    ]));
    await db.delete(vaultUploadGrants).where(inArray(vaultUploadGrants.id, grants.map((grant) => grant.id)));
    await options.afterObjectDeletion?.();
    if (grants.length < VAULT_OBJECT_DELETE_BATCH_SIZE) break;
  }

  for (;;) {
    const tombstones = await db
      .select({
        id: vaultUploadTombstones.id,
        objectKey: vaultUploadTombstones.objectKey,
        uploadObjectKey: vaultUploadTombstones.uploadObjectKey,
      })
      .from(vaultUploadTombstones)
      .where(eq(vaultUploadTombstones.userId, userId))
      .orderBy(asc(vaultUploadTombstones.id))
      .limit(VAULT_OBJECT_DELETE_BATCH_SIZE);
    if (tombstones.length === 0) break;
    options.beforeObjectDeletion?.();
    await Promise.all(tombstones.flatMap((tombstone) => [
      deleteObject(tombstone.objectKey),
      deleteObject(tombstone.uploadObjectKey),
    ]));
    await db
      .delete(vaultUploadTombstones)
      .where(inArray(vaultUploadTombstones.id, tombstones.map((tombstone) => tombstone.id)));
    await options.afterObjectDeletion?.();
    if (tombstones.length < VAULT_OBJECT_DELETE_BATCH_SIZE) break;
  }

  for (;;) {
    const sessions = await db
      .select({ id: vaultSessions.id, latestObjectKey: vaultSessions.latestObjectKey })
      .from(vaultSessions)
      .where(eq(vaultSessions.userId, userId))
      .orderBy(asc(vaultSessions.id))
      .limit(VAULT_OBJECT_DELETE_BATCH_SIZE);
    if (sessions.length === 0) break;
    options.beforeObjectDeletion?.();
    await Promise.all(sessions.map((session) => deleteObject(session.latestObjectKey)));
    await db.delete(vaultSessions).where(inArray(vaultSessions.id, sessions.map((session) => session.id)));
    await options.afterObjectDeletion?.();
    if (sessions.length < VAULT_OBJECT_DELETE_BATCH_SIZE) break;
  }
}

async function finishPostStackAccountCleanup(
  userId: string,
  accountTeamIds: readonly string[],
  options: { readonly deletePostHogPerson?: boolean } = {},
): Promise<void> {
  await deleteVaultRowsAndObjectsForAccount(userId);
  if (options.deletePostHogPerson !== false) {
    await deletePostHogPersonForAccountDeletion(userId);
  }
  await deleteCmuxOwnedAccountRows(userId, accountTeamIds);
}

async function deletePostHogPersonForAccountDeletion(
  userId: string,
  options: {
    readonly config?: PostHogPersonDeletionConfig | null;
    readonly beforeExternalRequest?: () => void;
    readonly afterExternalMutation?: () => Promise<void>;
  } = {},
): Promise<void> {
  const config = options.config === undefined
    ? postHogPersonDeletionConfig()
    : options.config;
  if (!config) return;

  // The deletion tombstone already blocks new reservations. Reject an older
  // in-flight forward before asking PostHog to delete, so every accepted event
  // is ordered before the bulk-delete request without holding a DB connection
  // across either external request.
  await assertNoAccountAnalyticsForwardInProgress(cloudDb(), userId);
  options.beforeExternalRequest?.();
  const response = await fetch(
    `${config.apiHost}/api/environments/${encodeURIComponent(config.environmentId)}/persons/bulk_delete/`,
    {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${config.personalApiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        distinct_ids: [userId],
        delete_events: true,
        delete_recordings: true,
        keep_person: false,
      }),
      signal: AbortSignal.timeout(POSTHOG_PERSON_DELETE_TIMEOUT_MS),
    },
  );
  if (!response.ok) {
    throw new Error(`PostHog account deletion failed with status ${response.status}`);
  }
  const summary: unknown = await response.json().catch(() => null);
  if (!isCompletePostHogPersonDeletion(summary)) {
    throw new Error("PostHog account deletion returned an incomplete result");
  }
  await options.afterExternalMutation?.();
}

function isCompletePostHogPersonDeletion(summary: unknown): boolean {
  if (!summary || typeof summary !== "object" || Array.isArray(summary)) return false;
  const result = summary as Record<string, unknown>;
  const personsFound = result.persons_found;
  const personsDeleted = result.persons_deleted;
  const eventsQueuedForDeletion = result.events_queued_for_deletion;
  const recordingsQueuedForDeletion = result.recordings_queued_for_deletion;
  const deletionErrors = result.deletion_errors;
  const hasNoDeletionErrors = deletionErrors === undefined ||
    (Array.isArray(deletionErrors) && deletionErrors.length === 0);
  if (
    !Number.isSafeInteger(personsFound) ||
    !Number.isSafeInteger(personsDeleted) ||
    (personsFound as number) < 0 ||
    personsFound !== personsDeleted ||
    !hasNoDeletionErrors
  ) return false;

  // No matching person is already the requested deletion state. PostHog has
  // nothing to enqueue in that case, so both queue flags are legitimately false.
  return personsFound === 0 ||
    (eventsQueuedForDeletion === true && recordingsQueuedForDeletion === true);
}

function postHogPersonDeletionConfig(): PostHogPersonDeletionConfig | null {
  const personalApiKey = process.env.POSTHOG_PERSONAL_API_KEY?.trim();
  if (!personalApiKey) {
    if (
      process.env.VERCEL_ENV === "production" ||
      process.env.CMUX_REQUIRE_POSTHOG_PERSON_DELETE === "1"
    ) {
      throw new Error("POSTHOG_PERSONAL_API_KEY is required for account deletion");
    }
    return null;
  }

  const apiHost = (
    process.env.POSTHOG_API_HOST ??
    POSTHOG_DEFAULT_API_HOST
  ).replace(/\/$/, "");
  const environmentId = (
    process.env.POSTHOG_ENVIRONMENT_ID ??
    process.env.POSTHOG_PROJECT_ID ??
    ""
  ).trim();
  if (!environmentId) {
    throw new Error("POSTHOG_ENVIRONMENT_ID is required for account deletion");
  }
  return { apiHost, environmentId, personalApiKey };
}

async function resolveUserBillingForAccountDeletion(
  userId: string,
  accountTeamIds: readonly string[],
  retainedTeamBillingOwners: readonly RetainedTeamBillingOwner[],
  options: {
    readonly beforeExternalRequest?: () => void;
    readonly afterExternalMutation?: () => Promise<void>;
  } = {},
): Promise<void> {
  const db = cloudDb();
  const deletionTeamIds = uniqueNonEmptyStrings([userId, ...accountTeamIds]);
  const retainedOwnerByTeam = new Map(
    retainedTeamBillingOwners.map((owner) => [owner.stackTeamId, owner.stackUserId] as const),
  );
  const subscriptionRows = await db
    .select({
      id: stripeSubscriptions.id,
      stackTeamId: stripeSubscriptions.stackTeamId,
      scope: stripeSubscriptions.scope,
      status: stripeSubscriptions.status,
    })
    .from(stripeSubscriptions)
    .where(or(
      eq(stripeSubscriptions.stackUserId, userId),
      inArray(stripeSubscriptions.stackTeamId, deletionTeamIds),
    ));
  const activeSubscriptions = subscriptionRows.filter((subscription) =>
    stripeSubscriptionBelongsToDeletingAccount(subscription, deletionTeamIds) &&
    stripeSubscriptionIsActive(subscription)
  );
  const retainedTeamSubscriptions = subscriptionRows.filter((subscription) =>
    stripeSubscriptionBelongsToRetainedTeam(subscription, deletionTeamIds)
  );
  const customerRows = await db
    .select({
      id: stripeCustomers.id,
      stackTeamId: stripeCustomers.stackTeamId,
    })
    .from(stripeCustomers)
    .where(or(
      eq(stripeCustomers.stackUserId, userId),
      inArray(stripeCustomers.stackTeamId, deletionTeamIds),
    ));
  const customers = customerRows.filter((customer) =>
    !customer.stackTeamId || deletionTeamIds.includes(customer.stackTeamId)
  );
  const retainedTeamCustomers = customerRows.filter((customer) =>
    customer.stackTeamId && !deletionTeamIds.includes(customer.stackTeamId)
  );
  assertRetainedTeamBillingOwners({
    retainedOwnerByTeam,
    rows: [...retainedTeamCustomers, ...retainedTeamSubscriptions],
  });

  if (
    activeSubscriptions.length === 0 &&
    customers.length === 0 &&
    retainedTeamCustomers.length === 0 &&
    retainedTeamSubscriptions.length === 0
  ) return;
  if (!isStripeBillingConfigured()) {
    throw new Error("Stripe billing cleanup is not configured");
  }

  const client = stripe();
  for (const customer of retainedTeamCustomers) {
    const retainedOwnerId = retainedOwnerByTeam.get(customer.stackTeamId ?? "");
    if (!retainedOwnerId) throw new Error(`retained team billing owner missing for ${customer.stackTeamId}`);
    await client.customers.update(customer.id, {
      email: "",
      metadata: {
        stackUserId: retainedOwnerId,
        deletedAccountId: deletedStripeAccountId(userId),
      },
    });
    await options.afterExternalMutation?.();
    await db
      .update(stripeCustomers)
      .set({
        stackUserId: retainedOwnerId,
        email: null,
        updatedAt: sql`now()`,
      })
      .where(eq(stripeCustomers.id, customer.id));
  }
  for (const subscription of retainedTeamSubscriptions) {
    const retainedOwnerId = retainedOwnerByTeam.get(subscription.stackTeamId ?? "");
    if (!retainedOwnerId) throw new Error(`retained team billing owner missing for ${subscription.stackTeamId}`);
    await client.subscriptions.update(subscription.id, {
      metadata: {
        stackUserId: retainedOwnerId,
        deletedAccountId: deletedStripeAccountId(userId),
      },
    });
    await options.afterExternalMutation?.();
    await db
      .update(stripeSubscriptions)
      .set({
        stackUserId: retainedOwnerId,
        raw: null,
        updatedAt: sql`now()`,
      })
      .where(eq(stripeSubscriptions.id, subscription.id));
  }
  for (const subscription of activeSubscriptions) {
    options.beforeExternalRequest?.();
    await cancelStripeSubscriptionForAccountDeletion(client, subscription.id);
    await options.afterExternalMutation?.();
  }
  for (const customer of customers) {
    options.beforeExternalRequest?.();
    await deleteStripeCustomerForAccountDeletion(client, customer.id);
    await options.afterExternalMutation?.();
  }
}

function stripeSubscriptionBelongsToDeletingAccount(
  subscription: { readonly scope?: string | null; readonly stackTeamId?: string | null },
  deletionTeamIds: readonly string[],
): boolean {
  const scope = subscription.scope ?? "user";
  if (scope === "user") return true;
  return scope === "team" &&
    typeof subscription.stackTeamId === "string" &&
    deletionTeamIds.includes(subscription.stackTeamId);
}

function stripeSubscriptionBelongsToRetainedTeam(
  subscription: { readonly scope?: string | null; readonly stackTeamId?: string | null },
  deletionTeamIds: readonly string[],
): boolean {
  return (subscription.scope ?? "user") === "team" &&
    typeof subscription.stackTeamId === "string" &&
    !deletionTeamIds.includes(subscription.stackTeamId);
}

function stripeSubscriptionIsActive(subscription: { readonly status?: string | null }): boolean {
  return !subscription.status ||
    (ACTIVE_STRIPE_PRO_STATUSES as readonly string[]).includes(subscription.status);
}

function assertRetainedTeamBillingOwners(input: {
  readonly retainedOwnerByTeam: ReadonlyMap<string, string>;
  readonly rows: readonly { readonly stackTeamId: string | null }[];
}): void {
  const missingTeamIds = uniqueNonEmptyStrings(input.rows.flatMap((row) => {
    const stackTeamId = row.stackTeamId;
    return stackTeamId && !input.retainedOwnerByTeam.has(stackTeamId) ? [stackTeamId] : [];
  }));
  if (missingTeamIds.length > 0) {
    throw new Error(`retained team billing owner missing for ${missingTeamIds.join(", ")}`);
  }
}

function deletedStripeAccountId(userId: string): string {
  return `deleted_${accountDeletionUserHash(userId).slice(0, 24)}`;
}

async function removeTestFlightAccessForAccountDeletion(
  user: DeletableStackUser,
  options: { readonly afterExternalMutation?: () => void } = {},
): Promise<void> {
  if (!isAscConfigured()) return;
  const email = user.primaryEmail?.trim();
  if (!email) return;
  try {
    await removeTester(email);
    options.afterExternalMutation?.();
  } catch (error) {
    captureAscError(error, {
      route: "/api/account",
      stackUserId: user.id,
      email,
    });
  }
}

async function markAccountDeletingAndClearBillingEntitlements(user: DeletableStackUser): Promise<void> {
  const metadata = stackMetadataRecord(user.clientReadOnlyMetadata);
  delete metadata.cmuxPlan;
  metadata.cmuxAccountDeleting = true;
  await user.update({ clientReadOnlyMetadata: metadata as ProMetadataJson });
}

async function restoreStackMetadataAfterAccountDeletionFailure(
  user: DeletableStackUser,
  metadata: unknown,
  options: { readonly restoreBillingEntitlements?: boolean } = {},
): Promise<void> {
  try {
    const restored = stackMetadataRecord(metadata);
    if (options.restoreBillingEntitlements === false) {
      delete restored.cmuxPlan;
    }
    await user.update({ clientReadOnlyMetadata: restored as ProMetadataJson });
  } catch (error) {
    logAccountDeleteError("account.delete.metadata_restore_failed", error);
  }
}

function stackMetadataRecord(metadata: unknown): Record<string, unknown> {
  return metadata && typeof metadata === "object" && !Array.isArray(metadata)
    ? { ...(metadata as Record<string, unknown>) }
    : {};
}

async function cancelStripeSubscriptionForAccountDeletion(
  client: ReturnType<typeof stripe>,
  subscriptionId: string,
): Promise<void> {
  try {
    await client.subscriptions.cancel(subscriptionId);
  } catch (error) {
    if (isStripeAlreadyInDeletionTargetState(error, [/already been canceled/i])) return;
    throw error;
  }
}

async function deleteStripeCustomerForAccountDeletion(
  client: ReturnType<typeof stripe>,
  customerId: string,
): Promise<void> {
  try {
    await client.customers.del(customerId);
  } catch (error) {
    if (isStripeAlreadyInDeletionTargetState(error, [/already deleted/i])) return;
    throw error;
  }
}

function isStripeAlreadyInDeletionTargetState(error: unknown, messagePatterns: readonly RegExp[]): boolean {
  const statusCode =
    error && typeof error === "object"
      ? (error as { statusCode?: unknown; raw?: { statusCode?: unknown } }).statusCode ??
        (error as { raw?: { statusCode?: unknown } }).raw?.statusCode
      : undefined;
  if (statusCode === 404) return true;

  const message =
    error && typeof error === "object" && typeof (error as { message?: unknown }).message === "string"
      ? (error as { message: string }).message
      : String(error);
  return messagePatterns.some((pattern) => pattern.test(message));
}

async function deleteCmuxOwnedAccountRows(userId: string, accountTeamIds: readonly string[]): Promise<void> {
  const db = cloudDb();
  await db.transaction(async (tx) => {
    const now = new Date();
    const deletionTeamIds = uniqueNonEmptyStrings([userId, ...accountTeamIds]);
    for (const teamId of deletionTeamIds) {
      await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${teamId}, 0))`);
    }
    const userVmRows = await tx
      .select({
        id: cloudVms.id,
        billingTeamId: cloudVms.billingTeamId,
        providerVmId: cloudVms.providerVmId,
        status: cloudVms.status,
      })
      .from(cloudVms)
      .where(or(
        eq(cloudVms.userId, userId),
        inArray(cloudVms.billingTeamId, deletionTeamIds),
      ))
      .for("update");
    const personalVmRows = userVmRows.filter((vm) =>
      !vm.billingTeamId || deletionTeamIds.includes(vm.billingTeamId)
    );
    const sharedTeamVmRows = userVmRows.filter((vm) =>
      vm.billingTeamId && !deletionTeamIds.includes(vm.billingTeamId)
    );
    const unsafePersonalVmRows = personalVmRows.filter((vm) => {
      if (vm.status === "destroyed") return false;
      if (vm.status === "failed" && !vm.providerVmId) return false;
      return true;
    });
    if (unsafePersonalVmRows.length > 0) {
      throw new Error(
        `Personal cloud VM provider teardown or creation is still pending for ${unsafePersonalVmRows.length} row${unsafePersonalVmRows.length === 1 ? "" : "s"}`,
      );
    }
    const personalVmIds = personalVmRows.map((vm) => vm.id);

    await tx.delete(deviceTokens).where(eq(deviceTokens.userId, userId));
    await tx.delete(notificationSendEvents).where(eq(notificationSendEvents.userId, userId));

    await tx.delete(billingEmailClaims).where(or(
      eq(billingEmailClaims.stackUserId, userId),
      eq(billingEmailClaims.claimedByUserId, userId),
    ));
    await tx.delete(stripeSubscriptions).where(or(
      and(
        eq(stripeSubscriptions.stackUserId, userId),
        eq(stripeSubscriptions.scope, "user"),
        isNull(stripeSubscriptions.stackTeamId),
      ),
      and(
        eq(stripeSubscriptions.scope, "team"),
        inArray(stripeSubscriptions.stackTeamId, deletionTeamIds),
      ),
    ));
    await tx.delete(stripeCustomers).where(or(
      and(
        eq(stripeCustomers.stackUserId, userId),
        isNull(stripeCustomers.stackTeamId),
      ),
      inArray(stripeCustomers.stackTeamId, deletionTeamIds),
    ));
    await tx
      .update(stripeSubscriptions)
      .set({ stackUserId: DELETED_ACCOUNT_ACTOR_ID, updatedAt: now })
      .where(and(
        eq(stripeSubscriptions.stackUserId, userId),
        eq(stripeSubscriptions.scope, "team"),
        isNotNull(stripeSubscriptions.stackTeamId),
        not(inArray(stripeSubscriptions.stackTeamId, deletionTeamIds)),
      ));
    await tx
      .update(stripeCustomers)
      .set({ stackUserId: DELETED_ACCOUNT_ACTOR_ID, updatedAt: now })
      .where(and(
        eq(stripeCustomers.stackUserId, userId),
        isNotNull(stripeCustomers.stackTeamId),
        not(inArray(stripeCustomers.stackTeamId, deletionTeamIds)),
      ));

    await tx.delete(cloudVmBillingGrants).where(or(
      and(
        eq(cloudVmBillingGrants.billingCustomerType, "user"),
        eq(cloudVmBillingGrants.billingCustomerId, userId),
      ),
      and(
        eq(cloudVmBillingGrants.billingCustomerType, "team"),
        inArray(cloudVmBillingGrants.billingCustomerId, deletionTeamIds),
      ),
    ));
    await tx.delete(cloudVmNotificationDeliveries).where(eq(cloudVmNotificationDeliveries.userId, userId));
    await tx.delete(cloudVmNotificationEvents).where(
      personalVmIds.length > 0
        ? or(eq(cloudVmNotificationEvents.userId, userId), inArray(cloudVmNotificationEvents.vmId, personalVmIds))
        : eq(cloudVmNotificationEvents.userId, userId),
    );
    await tx.delete(cloudVmUsageEvents).where(
      personalVmIds.length > 0
        ? or(
          eq(cloudVmUsageEvents.userId, userId),
          inArray(cloudVmUsageEvents.billingTeamId, deletionTeamIds),
          inArray(cloudVmUsageEvents.vmId, personalVmIds),
        )
        : or(eq(cloudVmUsageEvents.userId, userId), inArray(cloudVmUsageEvents.billingTeamId, deletionTeamIds)),
    );
    await tx.delete(cloudVmLeases).where(
      personalVmIds.length > 0
        ? or(eq(cloudVmLeases.userId, userId), inArray(cloudVmLeases.vmId, personalVmIds))
        : eq(cloudVmLeases.userId, userId),
    );
    await tx.delete(cloudVmSessions).where(
      personalVmIds.length > 0
        ? or(eq(cloudVmSessions.userId, userId), inArray(cloudVmSessions.vmId, personalVmIds))
        : eq(cloudVmSessions.userId, userId),
    );
    if (personalVmRows.length > 0) {
      await tx.delete(cloudVms).where(inArray(cloudVms.id, personalVmRows.map((vm) => vm.id)));
    }
    if (sharedTeamVmRows.length > 0) {
      await tx
        .update(cloudVms)
        .set({ userId: DELETED_ACCOUNT_ACTOR_ID, updatedAt: now })
        .where(inArray(cloudVms.id, sharedTeamVmRows.map((vm) => vm.id)));
    }
    await tx.delete(cloudVmBaseEvents).where(eq(cloudVmBaseEvents.userId, userId));
    await tx.delete(cloudVmBases).where(or(
      and(
        eq(cloudVmBases.scopeType, "user"),
        eq(cloudVmBases.scopeId, userId),
      ),
      and(
        eq(cloudVmBases.scopeType, "team"),
        inArray(cloudVmBases.scopeId, deletionTeamIds),
      ),
    ));
    await tx
      .update(cloudVmBases)
      .set({ createdByUserId: DELETED_ACCOUNT_ACTOR_ID, updatedAt: now })
      .where(eq(cloudVmBases.createdByUserId, userId));
    await tx
      .update(cloudVmBases)
      .set({ lastOpenedByUserId: null, updatedAt: now })
      .where(eq(cloudVmBases.lastOpenedByUserId, userId));
    await tx
      .update(cloudVmBaseGenerations)
      .set({ createdByUserId: DELETED_ACCOUNT_ACTOR_ID, updatedAt: now })
      .where(eq(cloudVmBaseGenerations.createdByUserId, userId));

    await tx.delete(devices).where(or(
      eq(devices.userId, userId),
      inArray(devices.teamId, deletionTeamIds),
    ));

    await tx.delete(vaultCliAuthRequests).where(eq(vaultCliAuthRequests.userId, userId));
  });
}

async function deletePersonalSubrouterTenant(
  userId: string,
  options: { readonly afterExternalMutation?: () => void } = {},
  accountTeamIds: readonly string[] = [userId],
): Promise<void> {
  const db = cloudDb();
  const teamIds = uniqueNonEmptyStrings([userId, ...accountTeamIds]);
  const tenants = await db
    .select({ tenantId: subrouterTenants.tenantId })
    .from(subrouterTenants)
    .where(inArray(subrouterTenants.teamId, teamIds));
  if (tenants.length === 0) return;

  const client = createSubrouterClientFromEnv();
  for (const tenant of tenants) {
    try {
      await client.revokeTenant(tenant.tenantId);
      options.afterExternalMutation?.();
    } catch (error) {
      if (!(error instanceof SubrouterClientError && error.status === 404)) throw error;
    }
  }
  await db.delete(subrouterTenants).where(inArray(subrouterTenants.teamId, teamIds));
}

async function accountDeletionScopeForUser(user: DeletableStackUser): Promise<{
  readonly teamIds: readonly string[];
  readonly retainedTeamBillingOwners: readonly RetainedTeamBillingOwner[];
}> {
  const listedTeams = await listAllStackTeams(user);
  const teams = uniqueStackTeams([
    stackTeamFromUnknown(user.selectedTeam),
    ...listedTeams.map(stackTeamFromUnknown),
  ]);
  const personalTeamIds: string[] = [];
  const retainedTeamBillingOwners: RetainedTeamBillingOwner[] = [];
  for (const team of teams) {
    const memberIds = await stackTeamMemberIds(team);
    if (!memberIds) {
      throw new Error(`Stack team membership is required for account deletion: ${team.id}`);
    }
    if (memberIds.length === 1 && memberIds[0] === user.id) {
      personalTeamIds.push(team.id);
      continue;
    }
    if (!memberIds.includes(user.id)) continue;
    const retainedOwnerId = memberIds.find((memberId) => memberId !== user.id);
    if (retainedOwnerId) {
      retainedTeamBillingOwners.push({
        stackTeamId: team.id,
        stackUserId: retainedOwnerId,
      });
    }
  }
  return {
    teamIds: uniqueNonEmptyStrings([user.id, ...personalTeamIds]),
    retainedTeamBillingOwners,
  };
}

async function listAllStackTeams(user: DeletableStackUser): Promise<readonly unknown[]> {
  if (typeof user.listTeams !== "function") {
    throw new Error("Stack team listing is required for account deletion");
  }

  const teams: unknown[] = [];
  const seenCursors = new Set<string>();
  const limit = 100;
  let cursor: string | undefined;
  do {
    const page = await user.listTeams({ cursor, limit });
    teams.push(...Array.from(page));
    const nextCursor = normalizedStackCursor(page.nextCursor);
    if (!nextCursor) break;
    if (seenCursors.has(nextCursor)) {
      throw new Error("Stack team pagination looped during account deletion");
    }
    seenCursors.add(nextCursor);
    cursor = nextCursor;
  } while (true);
  return teams;
}

function stackTeamFromUnknown(value: unknown): AccountDeletionStackTeam | null {
  if (!value || typeof value !== "object") return null;
  const id = (value as { readonly id?: unknown }).id;
  if (typeof id !== "string" || !id.trim()) return null;
  const listUsers = (value as { readonly listUsers?: unknown }).listUsers;
  return {
    id: id.trim(),
    listUsers: typeof listUsers === "function"
      ? async (options) => await listUsers.call(value, options)
      : undefined,
  };
}

async function stackTeamMemberIds(team: AccountDeletionStackTeam): Promise<readonly string[] | null> {
  if (typeof team.listUsers !== "function") return null;
  const members: unknown[] = [];
  const seenCursors = new Set<string>();
  const limit = 100;
  let cursor: string | undefined;
  do {
    const page = await team.listUsers({ cursor, limit });
    members.push(...Array.from(page));
    const nextCursor = normalizedStackCursor(page.nextCursor);
    if (!nextCursor) break;
    if (seenCursors.has(nextCursor)) {
      throw new Error(`Stack team ${team.id} membership pagination looped`);
    }
    seenCursors.add(nextCursor);
    cursor = nextCursor;
  } while (true);
  return uniqueNonEmptyStrings(members.flatMap((member) => {
    if (!member || typeof member !== "object") return [];
    const id = (member as { readonly id?: unknown }).id;
    return typeof id === "string" ? [id] : [];
  }));
}

function normalizedStackCursor(value: string | null | undefined): string | undefined {
  const cursor = value?.trim();
  return cursor ? cursor : undefined;
}

function uniqueStackTeams(values: readonly (AccountDeletionStackTeam | null)[]): readonly AccountDeletionStackTeam[] {
  const teams = new Map<string, AccountDeletionStackTeam>();
  for (const team of values) {
    if (!team) continue;
    const existing = teams.get(team.id);
    if (!existing || (typeof existing.listUsers !== "function" && typeof team.listUsers === "function")) {
      teams.set(team.id, team);
    }
  }
  return [...teams.values()];
}

function uniqueNonEmptyStrings(values: readonly (string | null | undefined)[]): readonly string[] {
  return [...new Set(values.map((value) => value?.trim()).filter((value): value is string => !!value))];
}

const SENSITIVE_ERROR_TEXT =
  /(Bearer\s+\S+|eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+|srt_[A-Za-z0-9_-]+|sk-[A-Za-z0-9_-]{8,})/g;

function logAccountDeleteError(label: string, error: unknown): void {
  console.error(label, sanitizedErrorSummary(error));
}

function sanitizedErrorSummary(error: unknown): string {
  const name =
    error && typeof error === "object" && typeof (error as { name?: unknown }).name === "string"
      ? (error as { name: string }).name
      : typeof error;
  const message =
    error && typeof error === "object" && typeof (error as { message?: unknown }).message === "string"
      ? (error as { message: string }).message
      : String(error);
  return `${name}: ${message.replace(SENSITIVE_ERROR_TEXT, "[redacted]")}`;
}
