import {
  and,
  asc,
  count,
  desc,
  eq,
  gt,
  inArray,
  isNotNull,
  isNull,
  lte,
  ne,
  or,
  sql,
} from "drizzle-orm";
import * as Context from "effect/Context";
import * as Data from "effect/Data";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import { cloudDb } from "../../db/client";
import {
  cloudVmDomains,
  cloudVmPublicationAuthCodes,
  cloudVmPublicationAuthTransactions,
  cloudVmPublicationProviderConfigs,
  cloudVmPublications,
  cloudVmPublicationSessions,
  cloudVmPublicationVmGuards,
  cloudVms,
  type CloudVmDomainVerificationRecord,
} from "../../db/schema";
import {
  AccountDeletionMutationBlockedError,
  assertAccountDeletionUserMutationAllowed,
} from "../account/deletionLock";
import type { ProviderId } from "../vms/drivers";

export type CloudVmDomainRow = typeof cloudVmDomains.$inferSelect;
export type CloudVmPublicationRow = typeof cloudVmPublications.$inferSelect;
export type CloudVmPublicationAuthTransactionRow =
  typeof cloudVmPublicationAuthTransactions.$inferSelect;
export type CloudVmPublicationAuthCodeRow =
  typeof cloudVmPublicationAuthCodes.$inferSelect;
export type CloudVmPublicationSessionRow =
  typeof cloudVmPublicationSessions.$inferSelect;
export type CloudVmPublicationProviderConfigRow =
  typeof cloudVmPublicationProviderConfigs.$inferSelect;
export type CloudVmPublicationAccessMode = CloudVmPublicationRow["accessMode"];
export type CloudVmPublicationState = CloudVmPublicationRow["state"];

export type CloudVmPublicationTarget = {
  readonly publication: CloudVmPublicationRow;
  readonly domain: CloudVmDomainRow;
  readonly vm: typeof cloudVms.$inferSelect;
};

export type CloudVmPublicationAuthTransaction = {
  readonly transaction: CloudVmPublicationAuthTransactionRow;
  readonly publication: CloudVmPublicationRow;
  readonly domain: CloudVmDomainRow;
};

export type CloudVmPublicationSessionPrincipal = {
  readonly session: CloudVmPublicationSessionRow;
  readonly publication: CloudVmPublicationRow;
  readonly domain: CloudVmDomainRow;
};

export type CloudVmPublicationAccountDeletionTarget = {
  readonly publicationId: string;
  readonly provider: ProviderId;
  readonly hostname: string;
  readonly providerTlsRuleId: string | null;
};

export type CloudVmPublicationVmDeletionTarget =
  CloudVmPublicationAccountDeletionTarget & {
    readonly state: CloudVmPublicationState;
  };

export type VmPublicationOperationClaim =
  | {
      readonly kind: "claimed";
      readonly vmId: string;
    }
  | {
      readonly kind: "in_progress";
      readonly retryAt: Date;
    };

export type VmPublicationDeletionFreeze =
  | {
      readonly kind: "ready";
      readonly vmId: string;
      readonly publications: readonly CloudVmPublicationVmDeletionTarget[];
    }
  | {
      readonly kind: "in_progress";
      readonly vmId: string;
      readonly retryAt: Date;
    };

export class PublicationDatabaseError extends Data.TaggedError(
  "PublicationDatabaseError",
)<{
  readonly operation: string;
  readonly cause: unknown;
}> {}

export class PublicationNotFoundError extends Data.TaggedError(
  "PublicationNotFoundError",
)<{
  readonly resource: "domain" | "publication" | "vm";
}> {}

export type PublicationConflictReason =
  | "hostname_taken"
  | "domain_in_use"
  | "provider_verification_in_use"
  | "provider_rule_in_use"
  | "invalid_access_policy"
  | "publication_not_active"
  | "publication_revision_changed"
  | "vm_publication_frozen"
  | "publication_operation_lost"
  | "forward_auth_bootstrap_lost"
  | "auth_transaction_limit";

export class PublicationConflictError extends Data.TaggedError(
  "PublicationConflictError",
)<{
  readonly reason: PublicationConflictReason;
}> {}

export type PublicationAuthArtifactFailure =
  | "transaction_invalid"
  | "transaction_expired"
  | "transaction_replayed"
  | "transaction_state_mismatch"
  | "transaction_pkce_mismatch"
  | "transaction_host_mismatch"
  | "authorization_code_invalid"
  | "authorization_code_expired"
  | "authorization_code_replayed"
  | "publication_revision_changed";

export class PublicationAuthArtifactError extends Data.TaggedError(
  "PublicationAuthArtifactError",
)<{
  readonly reason: PublicationAuthArtifactFailure;
}> {}

export class PublicationAccountDeletionBlockedError extends Data.TaggedError(
  "PublicationAccountDeletionBlockedError",
)<{
  readonly userId: string;
}> {}

export type ForwardAuthBootstrapClaim =
  | {
      readonly kind: "ready";
      readonly config: CloudVmPublicationProviderConfigRow;
    }
  | {
      readonly kind: "claimed";
      readonly config: CloudVmPublicationProviderConfigRow;
    }
  | {
      readonly kind: "in_progress";
      readonly retryAt: Date;
    };

type RepositoryError =
  | PublicationDatabaseError
  | PublicationNotFoundError
  | PublicationConflictError
  | PublicationAuthArtifactError
  | PublicationAccountDeletionBlockedError;

export type CloudVmPublicationRepositoryShape = {
  readonly claimProviderForwardAuth: (input: {
    readonly provider: ProviderId;
    readonly leaseId: string;
    readonly now: Date;
    readonly leaseExpiresAt: Date;
  }) => Effect.Effect<ForwardAuthBootstrapClaim, RepositoryError>;
  readonly completeProviderForwardAuth: (input: {
    readonly provider: ProviderId;
    readonly leaseId: string;
    readonly providerForwardAuthId: string;
    readonly now: Date;
  }) => Effect.Effect<CloudVmPublicationProviderConfigRow, RepositoryError>;
  readonly releaseProviderForwardAuthClaim: (input: {
    readonly provider: ProviderId;
    readonly leaseId: string;
    readonly now: Date;
  }) => Effect.Effect<boolean, PublicationDatabaseError>;
  readonly getProviderForwardAuth: (
    provider: ProviderId,
  ) => Effect.Effect<
    CloudVmPublicationProviderConfigRow | null,
    PublicationDatabaseError
  >;
  readonly replaceProviderForwardAuth: (input: {
    readonly provider: ProviderId;
    readonly expectedProviderForwardAuthId: string;
    readonly providerForwardAuthId: string;
    readonly now: Date;
  }) => Effect.Effect<CloudVmPublicationProviderConfigRow, RepositoryError>;

  readonly createDomain: (input: {
    readonly ownerUserId: string;
    readonly hostname: string;
    readonly kind: CloudVmDomainRow["kind"];
    readonly provider: ProviderId;
    readonly providerVerificationId?: string | null;
    readonly verificationState: CloudVmDomainRow["verificationState"];
    readonly certificateState: CloudVmDomainRow["certificateState"];
    readonly verificationRecords?: readonly CloudVmDomainVerificationRecord[];
    readonly now: Date;
  }) => Effect.Effect<CloudVmDomainRow, RepositoryError>;
  readonly updateDomainState: (input: {
    readonly id: string;
    readonly ownerUserId: string;
    readonly providerVerificationId?: string | null;
    readonly verificationState?: CloudVmDomainRow["verificationState"];
    readonly certificateState?: CloudVmDomainRow["certificateState"];
    readonly verificationRecords?: readonly CloudVmDomainVerificationRecord[];
    readonly now: Date;
  }) => Effect.Effect<CloudVmDomainRow, RepositoryError>;
  readonly findOwnedDomain: (input: {
    readonly id: string;
    readonly ownerUserId: string;
  }) => Effect.Effect<CloudVmDomainRow | null, PublicationDatabaseError>;
  /** The owner's zone row for an exact hostname, preferring verified over pending over failed. */
  readonly findOwnedDomainByHostname: (input: {
    readonly hostname: string;
    readonly ownerUserId: string;
  }) => Effect.Effect<CloudVmDomainRow | null, PublicationDatabaseError>;
  readonly listOwnedDomains: (
    ownerUserId: string,
  ) => Effect.Effect<readonly CloudVmDomainRow[], PublicationDatabaseError>;

  readonly reservePublication: (input: {
    readonly ownerUserId: string;
    /** The caller's account scope; VM lookup follows it like every VM route. */
    readonly billingTeamId?: string | null;
    /** Current team membership; omitted means none, which fails closed for team-billed VMs. */
    readonly teamIds?: readonly string[];
    readonly provider: ProviderId;
    readonly providerVmId: string;
    readonly domainId: string;
    readonly hostname: string;
    readonly port: number;
    readonly accessMode: CloudVmPublicationAccessMode;
    readonly teamId?: string | null;
    readonly now: Date;
  }) => Effect.Effect<CloudVmPublicationTarget, RepositoryError>;
  readonly reservePublicationWithNewDomain: (input: {
    readonly ownerUserId: string;
    readonly billingTeamId?: string | null;
    readonly teamIds?: readonly string[];
    readonly provider: ProviderId;
    readonly providerVmId: string;
    readonly domainHostname: string;
    readonly hostname: string;
    readonly kind: CloudVmDomainRow["kind"];
    readonly port: number;
    readonly accessMode: CloudVmPublicationAccessMode;
    readonly teamId?: string | null;
    readonly now: Date;
  }) => Effect.Effect<CloudVmPublicationTarget, RepositoryError>;
  readonly claimVmPublicationOperation: (input: {
    readonly publicationId: string;
    readonly ownerUserId: string;
    readonly leaseId: string;
    readonly now: Date;
    readonly leaseExpiresAt: Date;
    /** `disable` may resume a publication already left in `disabling` by a failed sweep. */
    readonly intent?: "mutate" | "disable";
  }) => Effect.Effect<VmPublicationOperationClaim, RepositoryError>;
  readonly releaseVmPublicationOperation: (input: {
    readonly publicationId: string;
    readonly leaseId: string;
    readonly now: Date;
  }) => Effect.Effect<boolean, PublicationDatabaseError>;
  readonly freezeVmPublicationsForDeletion: (input: {
    readonly requesterUserId: string;
    readonly billingTeamId?: string | null;
    readonly teamIds: readonly string[];
    readonly providerVmId: string;
    readonly now: Date;
  }) => Effect.Effect<VmPublicationDeletionFreeze, RepositoryError>;
  readonly recordProvisioningTlsRule: (input: {
    readonly id: string;
    readonly ownerUserId: string;
    readonly expectedRoutingRevision: number;
    readonly providerTlsRuleId: string;
    readonly providerForwardAuthId: string | null;
    readonly now: Date;
  }) => Effect.Effect<CloudVmPublicationRow, RepositoryError>;
  readonly activatePublication: (input: {
    readonly id: string;
    readonly ownerUserId: string;
    readonly expectedRoutingRevision: number;
    readonly providerTlsRuleId: string;
    readonly providerForwardAuthId: string | null;
    readonly now: Date;
  }) => Effect.Effect<CloudVmPublicationRow, RepositoryError>;
  readonly commitAccessPolicy: (input: {
    readonly id: string;
    readonly ownerUserId: string;
    readonly expectedRoutingRevision: number;
    readonly accessMode: CloudVmPublicationAccessMode;
    readonly teamId?: string | null;
    /** Omit to preserve the currently applied provider value during a two-step transition. */
    readonly appliedProviderForwardAuthId?: string | null;
    readonly now: Date;
  }) => Effect.Effect<CloudVmPublicationRow, RepositoryError>;
  readonly recordAppliedForwardAuth: (input: {
    readonly id: string;
    readonly expectedRoutingRevision: number;
    readonly providerForwardAuthId: string | null;
    readonly now: Date;
  }) => Effect.Effect<CloudVmPublicationRow, RepositoryError>;
  readonly markPublicationUnavailable: (input: {
    readonly id: string;
    readonly expectedRoutingRevision: number;
    readonly now: Date;
  }) => Effect.Effect<CloudVmPublicationRow, RepositoryError>;
  readonly beginDisablePublication: (input: {
    readonly id: string;
    readonly ownerUserId: string;
    readonly now: Date;
  }) => Effect.Effect<CloudVmPublicationRow, RepositoryError>;
  readonly finishDisablePublication: (input: {
    readonly id: string;
    readonly now: Date;
  }) => Effect.Effect<CloudVmPublicationRow, RepositoryError>;
  readonly findOwnedPublication: (input: {
    readonly id: string;
    readonly ownerUserId: string;
  }) => Effect.Effect<
    CloudVmPublicationTarget | null,
    PublicationDatabaseError
  >;
  /** The owner's live (not disabled) publication on an exact hostname. */
  readonly findOwnedPublicationByHostname: (input: {
    readonly hostname: string;
    readonly ownerUserId: string;
  }) => Effect.Effect<
    CloudVmPublicationTarget | null,
    PublicationDatabaseError
  >;
  readonly listOwnedPublications: (
    ownerUserId: string,
  ) => Effect.Effect<
    readonly CloudVmPublicationTarget[],
    PublicationDatabaseError
  >;
  /** The owner's publications on one zone, newest first. */
  readonly listOwnedPublicationsForDomain: (input: {
    readonly ownerUserId: string;
    readonly domainId: string;
  }) => Effect.Effect<
    readonly CloudVmPublicationTarget[],
    PublicationDatabaseError
  >;
  readonly listPublicationsForAccountDeletion: (
    ownerUserId: string,
  ) => Effect.Effect<
    readonly CloudVmPublicationAccountDeletionTarget[],
    PublicationDatabaseError
  >;
  readonly findActivePublicationForRequest: (input: {
    readonly hostname: string;
    readonly providerTlsRuleId: string;
  }) => Effect.Effect<
    CloudVmPublicationTarget | null,
    PublicationDatabaseError
  >;

  readonly createAuthTransaction: (input: {
    readonly publicationId: string;
    readonly transactionHash: string;
    readonly pkceChallenge: string;
    readonly stateHash: string;
    readonly hostname: string;
    readonly returnPath: string;
    readonly now: Date;
    readonly expiresAt: Date;
  }) => Effect.Effect<CloudVmPublicationAuthTransactionRow, RepositoryError>;
  readonly findPendingAuthTransaction: (input: {
    readonly transactionHash: string;
    readonly now: Date;
  }) => Effect.Effect<
    CloudVmPublicationAuthTransaction | null,
    PublicationDatabaseError
  >;
  readonly issueAuthCode: (input: {
    readonly transactionHash: string;
    readonly stateHash: string;
    readonly codeHash: string;
    readonly userId: string;
    readonly now: Date;
    readonly expiresAt: Date;
  }) => Effect.Effect<
    {
      readonly code: CloudVmPublicationAuthCodeRow;
      readonly transaction: CloudVmPublicationAuthTransactionRow;
    },
    RepositoryError
  >;
  readonly consumeAuthCodeAndCreateSession: (input: {
    readonly codeHash: string;
    readonly transactionHash: string;
    readonly stateHash: string;
    readonly pkceChallenge: string;
    readonly hostname: string;
    readonly sessionTokenHash: string;
    readonly now: Date;
    readonly sessionExpiresAt: Date;
  }) => Effect.Effect<
    {
      readonly session: CloudVmPublicationSessionRow;
      readonly publication: CloudVmPublicationRow;
      readonly returnPath: string;
    },
    RepositoryError
  >;
  readonly findValidSession: (input: {
    readonly tokenHash: string;
    readonly publicationId: string;
    readonly hostname: string;
    readonly now: Date;
  }) => Effect.Effect<
    CloudVmPublicationSessionPrincipal | null,
    PublicationDatabaseError
  >;
  readonly revokePublicationSessions: (input: {
    readonly publicationId: string;
    readonly now: Date;
  }) => Effect.Effect<number, PublicationDatabaseError>;
};

export class CloudVmPublicationRepository extends Context.Tag(
  "cmux/CloudVmPublicationRepository",
)<CloudVmPublicationRepository, CloudVmPublicationRepositoryShape>() {}

function tagged<T extends string>(
  value: unknown,
  tag: T,
): value is { readonly _tag: T } {
  return (value as { readonly _tag?: string } | null)?._tag === tag;
}

function isRepositoryDomainError(
  cause: unknown,
): cause is Exclude<RepositoryError, PublicationDatabaseError> {
  return (
    tagged(cause, "PublicationNotFoundError") ||
    tagged(cause, "PublicationConflictError") ||
    tagged(cause, "PublicationAuthArtifactError") ||
    tagged(cause, "PublicationAccountDeletionBlockedError")
  );
}

function repositoryEffect<A>(
  operation: string,
  run: () => Promise<A>,
): Effect.Effect<A, RepositoryError> {
  return Effect.tryPromise({
    try: run,
    catch: (cause) =>
      isRepositoryDomainError(cause)
        ? cause
        : new PublicationDatabaseError({ operation, cause }),
  });
}

function databaseEffect<A>(
  operation: string,
  run: () => Promise<A>,
): Effect.Effect<A, PublicationDatabaseError> {
  return Effect.tryPromise({
    try: run,
    catch: (cause) => new PublicationDatabaseError({ operation, cause }),
  });
}

function pgConstraint(cause: unknown): string | null {
  if (!cause || typeof cause !== "object") return null;
  const constraint =
    (
      cause as {
        readonly constraint?: unknown;
        readonly constraint_name?: unknown;
      }
    ).constraint ??
    (cause as { readonly constraint_name?: unknown }).constraint_name;
  if (typeof constraint === "string") return constraint;
  return pgConstraint((cause as { readonly cause?: unknown }).cause);
}

function isHostnameClaimConstraint(constraint: string | null): boolean {
  return (
    constraint === "cloud_vm_domains_owner_pending_hostname_unique" ||
    constraint === "cloud_vm_domains_claimed_hostname_unique" ||
    constraint === "cloud_vm_publications_owner_hostname_unique" ||
    constraint === "cloud_vm_publications_claimed_hostname_unique"
  );
}

function normalizedHostname(value: string): string {
  return value.trim().toLowerCase().replace(/\.$/u, "");
}

function domainCoversPublicationHostname(
  domain: Pick<CloudVmDomainRow, "hostname" | "kind">,
  hostname: string,
): boolean {
  if (hostname === domain.hostname) return true;
  if (domain.kind === "generated") return false;
  const suffix = `.${domain.hostname}`;
  if (!hostname.endsWith(suffix)) return false;
  const childLabel = hostname.slice(0, -suffix.length);
  return childLabel.length > 0 && !childLabel.includes(".");
}

function initialHostnameClaimedAt(
  domain: Pick<CloudVmDomainRow, "kind" | "verificationState">,
  now: Date,
): Date | null {
  return domain.kind === "generated" || domain.verificationState === "verified"
    ? now
    : null;
}

function normalizedTeamId(
  accessMode: CloudVmPublicationAccessMode,
  teamId: string | null | undefined,
): string | null {
  const normalized = teamId?.trim() || null;
  if ((accessMode === "team") !== (normalized !== null)) {
    throw new PublicationConflictError({ reason: "invalid_access_policy" });
  }
  return normalized;
}

/**
 * A team-billed VM is publishable by any current member of that team, and a
 * creator who has since left the team may not publish it. This mirrors the
 * `billingTeamId` guard every other VM route applies before `vmAccountScopeWhere`.
 */
function requireVmAccountScope(input: {
  readonly ownerUserId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
}): { readonly requesterUserId: string; readonly billingTeamId: string | null } {
  const billingTeamId = input.billingTeamId?.trim() || null;
  if (
    billingTeamId &&
    billingTeamId !== input.ownerUserId &&
    !(input.teamIds ?? []).includes(billingTeamId)
  ) {
    throw new PublicationNotFoundError({ resource: "vm" });
  }
  return { requesterUserId: input.ownerUserId, billingTeamId };
}

function vmAccountScopeWhere(input: {
  readonly requesterUserId: string;
  readonly billingTeamId?: string | null;
}) {
  const billingTeamId = input.billingTeamId?.trim();
  if (billingTeamId) return eq(cloudVms.billingTeamId, billingTeamId);
  return and(
    eq(cloudVms.userId, input.requesterUserId),
    or(
      isNull(cloudVms.billingTeamId),
      eq(cloudVms.billingTeamId, input.requesterUserId),
    ),
  );
}

function accountDeletionError(
  cause: unknown,
): PublicationAccountDeletionBlockedError | unknown {
  return cause instanceof AccountDeletionMutationBlockedError
    ? new PublicationAccountDeletionBlockedError({ userId: cause.userId })
    : cause;
}

/**
 * Every unauthenticated navigation to a protected hostname mints a
 * transaction, so hygiene runs on that hot path instead of a cron: retire a
 * bounded batch of this publication's expired transactions (codes cascade)
 * and cap the pending ones so one hostname cannot fill the table. A consumed
 * transaction is deliberately kept until it expires: consumption means a code
 * was issued, and the browser still has to present that code at the callback.
 * At the cap, sign-ins that have sat untouched longer than a browser needs to
 * finish the handoff are retired first; if the cap is still reached, the new
 * transaction is refused rather than evicting someone mid sign-in.
 */
export const AUTH_ARTIFACT_SWEEP_LIMIT = 100;
export const MAX_PENDING_AUTH_TRANSACTIONS_PER_PUBLICATION = 1_000;
export const AUTH_TRANSACTION_ABANDONED_AFTER_MS = 2 * 60 * 1_000;

type CloudDbTx = Parameters<Parameters<ReturnType<typeof cloudDb>["transaction"]>[0]>[0];

async function sweepAuthTransactions(
  tx: CloudDbTx,
  publicationId: string,
  now: Date,
): Promise<void> {
  await tx
    .delete(cloudVmPublicationAuthTransactions)
    .where(
      inArray(
        cloudVmPublicationAuthTransactions.transactionHash,
        tx
          .select({ hash: cloudVmPublicationAuthTransactions.transactionHash })
          .from(cloudVmPublicationAuthTransactions)
          .where(
            and(
              eq(cloudVmPublicationAuthTransactions.publicationId, publicationId),
              lte(cloudVmPublicationAuthTransactions.expiresAt, now),
            ),
          )
          .orderBy(asc(cloudVmPublicationAuthTransactions.expiresAt))
          .limit(AUTH_ARTIFACT_SWEEP_LIMIT),
      ),
    );
  const pendingWhere = and(
    eq(cloudVmPublicationAuthTransactions.publicationId, publicationId),
    gt(cloudVmPublicationAuthTransactions.expiresAt, now),
    isNull(cloudVmPublicationAuthTransactions.consumedAt),
  );
  const countPending = async (): Promise<number> => {
    const [pending] = await tx
      .select({ total: count() })
      .from(cloudVmPublicationAuthTransactions)
      .where(pendingWhere);
    return pending?.total ?? 0;
  };
  if (await countPending() < MAX_PENDING_AUTH_TRANSACTIONS_PER_PUBLICATION) return;
  await tx
    .delete(cloudVmPublicationAuthTransactions)
    .where(
      and(
        pendingWhere,
        lte(
          cloudVmPublicationAuthTransactions.createdAt,
          new Date(now.getTime() - AUTH_TRANSACTION_ABANDONED_AFTER_MS),
        ),
      ),
    );
  if (await countPending() >= MAX_PENDING_AUTH_TRANSACTIONS_PER_PUBLICATION) {
    throw new PublicationConflictError({ reason: "auth_transaction_limit" });
  }
}

async function sweepPublicationSessions(
  tx: CloudDbTx,
  publicationId: string,
  now: Date,
): Promise<void> {
  await tx
    .delete(cloudVmPublicationSessions)
    .where(
      inArray(
        cloudVmPublicationSessions.tokenHash,
        tx
          .select({ hash: cloudVmPublicationSessions.tokenHash })
          .from(cloudVmPublicationSessions)
          .where(
            and(
              eq(cloudVmPublicationSessions.publicationId, publicationId),
              or(
                lte(cloudVmPublicationSessions.expiresAt, now),
                isNotNull(cloudVmPublicationSessions.revokedAt),
              ),
            ),
          )
          .orderBy(asc(cloudVmPublicationSessions.expiresAt))
          .limit(AUTH_ARTIFACT_SWEEP_LIMIT),
      ),
    );
}

async function requirePublicationRevision(
  tx: Parameters<Parameters<ReturnType<typeof cloudDb>["transaction"]>[0]>[0],
  input: {
    readonly id: string;
    readonly expectedRoutingRevision: number;
    readonly ownerUserId?: string;
  },
): Promise<CloudVmPublicationRow> {
  const conditions = [eq(cloudVmPublications.id, input.id)];
  if (input.ownerUserId !== undefined) {
    conditions.push(eq(cloudVmPublications.ownerUserId, input.ownerUserId));
  }
  const [publication] = await tx
    .select()
    .from(cloudVmPublications)
    .where(and(...conditions))
    .for("update")
    .limit(1);
  if (!publication)
    throw new PublicationNotFoundError({ resource: "publication" });
  if (publication.routingRevision !== input.expectedRoutingRevision) {
    throw new PublicationConflictError({
      reason: "publication_revision_changed",
    });
  }
  return publication;
}

export const CloudVmPublicationRepositoryLive = Layer.succeed(
  CloudVmPublicationRepository,
  {
    claimProviderForwardAuth: (input) =>
      repositoryEffect("claimProviderForwardAuth", async () => {
        if (input.leaseExpiresAt <= input.now) {
          throw new PublicationConflictError({
            reason: "forward_auth_bootstrap_lost",
          });
        }
        return await cloudDb().transaction(async (tx) => {
          await tx
            .insert(cloudVmPublicationProviderConfigs)
            .values({
              provider: input.provider,
              provisioningLeaseId: input.leaseId,
              provisioningLeaseExpiresAt: input.leaseExpiresAt,
              createdAt: input.now,
              updatedAt: input.now,
            })
            .onConflictDoNothing({
              target: cloudVmPublicationProviderConfigs.provider,
            });
          const [config] = await tx
            .select()
            .from(cloudVmPublicationProviderConfigs)
            .where(
              eq(cloudVmPublicationProviderConfigs.provider, input.provider),
            )
            .for("update")
            .limit(1);
          if (!config)
            throw new Error(
              "provider config missing after bootstrap reservation",
            );
          if (config.providerForwardAuthId)
            return { kind: "ready" as const, config };
          if (
            config.provisioningLeaseId &&
            config.provisioningLeaseId !== input.leaseId &&
            config.provisioningLeaseExpiresAt &&
            config.provisioningLeaseExpiresAt > input.now
          ) {
            return {
              kind: "in_progress" as const,
              retryAt: config.provisioningLeaseExpiresAt,
            };
          }
          const [claimed] = await tx
            .update(cloudVmPublicationProviderConfigs)
            .set({
              provisioningLeaseId: input.leaseId,
              provisioningLeaseExpiresAt: input.leaseExpiresAt,
              updatedAt: input.now,
            })
            .where(
              eq(cloudVmPublicationProviderConfigs.provider, input.provider),
            )
            .returning();
          if (!claimed)
            throw new Error("provider config bootstrap claim returned no row");
          return { kind: "claimed" as const, config: claimed };
        });
      }),

    completeProviderForwardAuth: (input) =>
      repositoryEffect("completeProviderForwardAuth", async () => {
        const [config] = await cloudDb()
          .update(cloudVmPublicationProviderConfigs)
          .set({
            providerForwardAuthId: input.providerForwardAuthId,
            provisioningLeaseId: null,
            provisioningLeaseExpiresAt: null,
            updatedAt: input.now,
          })
          .where(
            and(
              eq(cloudVmPublicationProviderConfigs.provider, input.provider),
              eq(
                cloudVmPublicationProviderConfigs.provisioningLeaseId,
                input.leaseId,
              ),
              isNull(cloudVmPublicationProviderConfigs.providerForwardAuthId),
            ),
          )
          .returning();
        if (!config) {
          throw new PublicationConflictError({
            reason: "forward_auth_bootstrap_lost",
          });
        }
        return config;
      }),

    releaseProviderForwardAuthClaim: (input) =>
      databaseEffect("releaseProviderForwardAuthClaim", async () => {
        const released = await cloudDb()
          .update(cloudVmPublicationProviderConfigs)
          .set({
            provisioningLeaseId: null,
            provisioningLeaseExpiresAt: null,
            updatedAt: input.now,
          })
          .where(
            and(
              eq(cloudVmPublicationProviderConfigs.provider, input.provider),
              eq(
                cloudVmPublicationProviderConfigs.provisioningLeaseId,
                input.leaseId,
              ),
              isNull(cloudVmPublicationProviderConfigs.providerForwardAuthId),
            ),
          )
          .returning({ provider: cloudVmPublicationProviderConfigs.provider });
        return released.length > 0;
      }),

    getProviderForwardAuth: (provider) =>
      databaseEffect("getProviderForwardAuth", async () => {
        const [config] = await cloudDb()
          .select()
          .from(cloudVmPublicationProviderConfigs)
          .where(eq(cloudVmPublicationProviderConfigs.provider, provider))
          .limit(1);
        return config ?? null;
      }),

    replaceProviderForwardAuth: (input) =>
      repositoryEffect("replaceProviderForwardAuth", async () => {
        const [config] = await cloudDb()
          .update(cloudVmPublicationProviderConfigs)
          .set({
            providerForwardAuthId: input.providerForwardAuthId,
            updatedAt: input.now,
          })
          .where(
            and(
              eq(cloudVmPublicationProviderConfigs.provider, input.provider),
              eq(
                cloudVmPublicationProviderConfigs.providerForwardAuthId,
                input.expectedProviderForwardAuthId,
              ),
              isNull(cloudVmPublicationProviderConfigs.provisioningLeaseId),
            ),
          )
          .returning();
        if (!config) {
          throw new PublicationConflictError({
            reason: "forward_auth_bootstrap_lost",
          });
        }
        return config;
      }),

    createDomain: (input) =>
      repositoryEffect("createDomain", async () => {
        try {
          return await cloudDb().transaction(async (tx) => {
            try {
              await assertAccountDeletionUserMutationAllowed(
                tx,
                input.ownerUserId,
              );
            } catch (cause) {
              throw accountDeletionError(cause);
            }
            const [domain] = await tx
              .insert(cloudVmDomains)
              .values({
                ownerUserId: input.ownerUserId,
                hostname: normalizedHostname(input.hostname),
                kind: input.kind,
                provider: input.provider,
                providerVerificationId: input.providerVerificationId ?? null,
                verificationState: input.verificationState,
                certificateState: input.certificateState,
                verificationRecords: [...(input.verificationRecords ?? [])],
                createdAt: input.now,
                updatedAt: input.now,
              })
              .returning();
            if (!domain) throw new Error("domain insert returned no row");
            return domain;
          });
        } catch (cause) {
          const constraint = pgConstraint(cause);
          if (isHostnameClaimConstraint(constraint)) {
            throw new PublicationConflictError({ reason: "hostname_taken" });
          }
          if (constraint === "cloud_vm_domains_provider_verification_unique") {
            throw new PublicationConflictError({
              reason: "provider_verification_in_use",
            });
          }
          throw cause;
        }
      }),

    updateDomainState: (input) =>
      repositoryEffect("updateDomainState", async () => {
        try {
          return await cloudDb().transaction(async (tx) => {
            const [current] = await tx
              .select()
              .from(cloudVmDomains)
              .where(
                and(
                  eq(cloudVmDomains.id, input.id),
                  eq(cloudVmDomains.ownerUserId, input.ownerUserId),
                ),
              )
              .for("update")
              .limit(1);
            if (!current)
              throw new PublicationNotFoundError({ resource: "domain" });

            const patch: Partial<typeof cloudVmDomains.$inferInsert> = {
              updatedAt: input.now,
            };
            if ("providerVerificationId" in input) {
              patch.providerVerificationId =
                input.providerVerificationId ?? null;
            }
            if (input.verificationState !== undefined) {
              patch.verificationState = input.verificationState;
            }
            if (input.certificateState !== undefined) {
              patch.certificateState = input.certificateState;
            }
            if (input.verificationRecords !== undefined) {
              patch.verificationRecords = [...input.verificationRecords];
            }
            const [domain] = await tx
              .update(cloudVmDomains)
              .set(patch)
              .where(eq(cloudVmDomains.id, current.id))
              .returning();
            if (!domain) throw new Error("domain update returned no row");

            // The verified-zone uniqueness constraint and every attached exact
            // hostname claim commit together. If another owner won either
            // resource, the whole promotion rolls back to pending.
            if (domain.verificationState === "verified") {
              await tx
                .update(cloudVmPublications)
                .set({
                  hostnameClaimedAt: input.now,
                  updatedAt: input.now,
                })
                .where(
                  and(
                    eq(cloudVmPublications.domainId, domain.id),
                    isNull(cloudVmPublications.disabledAt),
                    isNull(cloudVmPublications.hostnameClaimedAt),
                  ),
                );
            }
            return domain;
          });
        } catch (cause) {
          const constraint = pgConstraint(cause);
          if (isHostnameClaimConstraint(constraint)) {
            throw new PublicationConflictError({ reason: "hostname_taken" });
          }
          if (constraint === "cloud_vm_domains_provider_verification_unique") {
            throw new PublicationConflictError({
              reason: "provider_verification_in_use",
            });
          }
          throw cause;
        }
      }),

    findOwnedDomain: (input) =>
      databaseEffect("findOwnedDomain", async () => {
        const [domain] = await cloudDb()
          .select()
          .from(cloudVmDomains)
          .where(
            and(
              eq(cloudVmDomains.id, input.id),
              eq(cloudVmDomains.ownerUserId, input.ownerUserId),
            ),
          )
          .limit(1);
        return domain ?? null;
      }),

    findOwnedDomainByHostname: (input) =>
      databaseEffect("findOwnedDomainByHostname", async () => {
        const rows = await cloudDb()
          .select()
          .from(cloudVmDomains)
          .where(
            and(
              eq(cloudVmDomains.hostname, normalizedHostname(input.hostname)),
              eq(cloudVmDomains.ownerUserId, input.ownerUserId),
            ),
          )
          .orderBy(desc(cloudVmDomains.createdAt));
        const rank = (row: CloudVmDomainRow): number =>
          row.verificationState === "verified"
            ? 0
            : row.verificationState === "pending" || row.verificationState === "not_required"
            ? 1
            : 2;
        return [...rows].sort((left, right) => rank(left) - rank(right))[0] ?? null;
      }),
    listOwnedDomains: (ownerUserId) =>
      databaseEffect(
        "listOwnedDomains",
        async () =>
          await cloudDb()
            .select()
            .from(cloudVmDomains)
            .where(eq(cloudVmDomains.ownerUserId, ownerUserId))
            .orderBy(desc(cloudVmDomains.createdAt)),
      ),

    reservePublication: (input) =>
      repositoryEffect("reservePublication", async () => {
        const teamId = normalizedTeamId(input.accessMode, input.teamId);
        const hostname = normalizedHostname(input.hostname);
        const vmScope = requireVmAccountScope(input);
        try {
          return await cloudDb().transaction(async (tx) => {
            try {
              await assertAccountDeletionUserMutationAllowed(
                tx,
                input.ownerUserId,
              );
            } catch (cause) {
              throw accountDeletionError(cause);
            }
            const [vm] = await tx
              .select()
              .from(cloudVms)
              .where(
                and(
                  vmAccountScopeWhere(vmScope),
                  eq(cloudVms.provider, input.provider),
                  eq(cloudVms.providerVmId, input.providerVmId),
                  inArray(cloudVms.status, ["running", "paused"]),
                ),
              )
              .for("update")
              .limit(1);
            if (!vm) throw new PublicationNotFoundError({ resource: "vm" });
            const [guard] = await tx
              .select({
                teardownStartedAt: cloudVmPublicationVmGuards.teardownStartedAt,
              })
              .from(cloudVmPublicationVmGuards)
              .where(eq(cloudVmPublicationVmGuards.vmId, vm.id))
              .limit(1);
            if (guard?.teardownStartedAt) {
              throw new PublicationConflictError({
                reason: "vm_publication_frozen",
              });
            }
            const [domain] = await tx
              .select()
              .from(cloudVmDomains)
              .where(
                and(
                  eq(cloudVmDomains.id, input.domainId),
                  eq(cloudVmDomains.ownerUserId, input.ownerUserId),
                  eq(cloudVmDomains.provider, input.provider),
                ),
              )
              .for("update")
              .limit(1);
            if (!domain)
              throw new PublicationNotFoundError({ resource: "domain" });
            if (!domainCoversPublicationHostname(domain, hostname)) {
              throw new PublicationConflictError({ reason: "hostname_taken" });
            }
            const [publication] = await tx
              .insert(cloudVmPublications)
              .values({
                ownerUserId: input.ownerUserId,
                vmId: vm.id,
                domainId: domain.id,
                hostname,
                hostnameClaimedAt: initialHostnameClaimedAt(domain, input.now),
                port: input.port,
                accessMode: input.accessMode,
                teamId,
                routingRevision: 1,
                state: "provisioning",
                createdAt: input.now,
                updatedAt: input.now,
              })
              .returning();
            if (!publication)
              throw new Error("publication insert returned no row");
            return { publication, domain, vm };
          });
        } catch (cause) {
          if (isHostnameClaimConstraint(pgConstraint(cause))) {
            throw new PublicationConflictError({ reason: "hostname_taken" });
          }
          throw cause;
        }
      }),

    reservePublicationWithNewDomain: (input) =>
      repositoryEffect("reservePublicationWithNewDomain", async () => {
        const teamId = normalizedTeamId(input.accessMode, input.teamId);
        const domainHostname = normalizedHostname(input.domainHostname);
        const hostname = normalizedHostname(input.hostname);
        const vmScope = requireVmAccountScope(input);
        const domainSeed = {
          hostname: domainHostname,
          kind: input.kind,
          verificationState:
            input.kind === "generated"
              ? ("not_required" as const)
              : ("pending" as const),
        };
        if (!domainCoversPublicationHostname(domainSeed, hostname)) {
          throw new PublicationConflictError({ reason: "hostname_taken" });
        }
        try {
          return await cloudDb().transaction(async (tx) => {
            try {
              await assertAccountDeletionUserMutationAllowed(
                tx,
                input.ownerUserId,
              );
            } catch (cause) {
              throw accountDeletionError(cause);
            }
            // Lock and authorize the VM before reserving either durable DNS
            // ownership or a public hostname. A failure therefore leaves no
            // zone row for an invalid or foreign VM id.
            const [vm] = await tx
              .select()
              .from(cloudVms)
              .where(
                and(
                  vmAccountScopeWhere(vmScope),
                  eq(cloudVms.provider, input.provider),
                  eq(cloudVms.providerVmId, input.providerVmId),
                  inArray(cloudVms.status, ["running", "paused"]),
                ),
              )
              .for("update")
              .limit(1);
            if (!vm) throw new PublicationNotFoundError({ resource: "vm" });
            const [guard] = await tx
              .select({
                teardownStartedAt: cloudVmPublicationVmGuards.teardownStartedAt,
              })
              .from(cloudVmPublicationVmGuards)
              .where(eq(cloudVmPublicationVmGuards.vmId, vm.id))
              .limit(1);
            if (guard?.teardownStartedAt) {
              throw new PublicationConflictError({
                reason: "vm_publication_frozen",
              });
            }
            const [domain] = await tx
              .insert(cloudVmDomains)
              .values({
                ownerUserId: input.ownerUserId,
                hostname: domainHostname,
                kind: input.kind,
                provider: input.provider,
                verificationState: domainSeed.verificationState,
                certificateState:
                  input.kind === "generated" ? "active" : "missing",
                createdAt: input.now,
                updatedAt: input.now,
              })
              .returning();
            if (!domain) throw new Error("domain insert returned no row");
            const [publication] = await tx
              .insert(cloudVmPublications)
              .values({
                ownerUserId: input.ownerUserId,
                vmId: vm.id,
                domainId: domain.id,
                hostname,
                hostnameClaimedAt: initialHostnameClaimedAt(domain, input.now),
                port: input.port,
                accessMode: input.accessMode,
                teamId,
                routingRevision: 1,
                state: "provisioning",
                createdAt: input.now,
                updatedAt: input.now,
              })
              .returning();
            if (!publication)
              throw new Error("publication insert returned no row");
            return { publication, domain, vm };
          });
        } catch (cause) {
          const constraint = pgConstraint(cause);
          if (isHostnameClaimConstraint(constraint)) {
            throw new PublicationConflictError({ reason: "hostname_taken" });
          }
          if (constraint === "cloud_vm_domains_provider_verification_unique") {
            throw new PublicationConflictError({
              reason: "provider_verification_in_use",
            });
          }
          throw cause;
        }
      }),

    claimVmPublicationOperation: (input) =>
      repositoryEffect("claimVmPublicationOperation", async () => {
        if (input.leaseExpiresAt <= input.now) {
          throw new PublicationConflictError({
            reason: "publication_operation_lost",
          });
        }
        return await cloudDb().transaction(async (tx) => {
          try {
            await assertAccountDeletionUserMutationAllowed(
              tx,
              input.ownerUserId,
            );
          } catch (cause) {
            throw accountDeletionError(cause);
          }
          const [candidate] = await tx
            .select({ vmId: cloudVmPublications.vmId })
            .from(cloudVmPublications)
            .where(
              and(
                eq(cloudVmPublications.id, input.publicationId),
                eq(cloudVmPublications.ownerUserId, input.ownerUserId),
              ),
            )
            .limit(1);
          if (!candidate) {
            throw new PublicationNotFoundError({ resource: "publication" });
          }
          const [vm] = await tx
            .select()
            .from(cloudVms)
            .where(eq(cloudVms.id, candidate.vmId))
            .for("update")
            .limit(1);
          const [publication] = await tx
            .select()
            .from(cloudVmPublications)
            .where(
              and(
                eq(cloudVmPublications.id, input.publicationId),
                eq(cloudVmPublications.ownerUserId, input.ownerUserId),
                eq(cloudVmPublications.vmId, candidate.vmId),
              ),
            )
            .for("update")
            .limit(1);
          if (!vm || !publication) {
            throw new PublicationNotFoundError({ resource: "publication" });
          }
          // A sweep that failed after `beginDisablePublication` leaves the row
          // `disabling`; only a delete may take the lease again to finish it.
          if (
            publication.state === "disabled" ||
            (publication.state === "disabling" && input.intent !== "disable")
          ) {
            throw new PublicationConflictError({
              reason: "publication_not_active",
            });
          }
          const [guard] = await tx
            .select()
            .from(cloudVmPublicationVmGuards)
            .where(eq(cloudVmPublicationVmGuards.vmId, vm.id))
            .for("update")
            .limit(1);
          if (guard?.teardownStartedAt) {
            throw new PublicationConflictError({
              reason: "vm_publication_frozen",
            });
          }
          if (
            guard?.operationLeaseId &&
            guard.operationLeaseExpiresAt &&
            guard.operationLeaseExpiresAt > input.now &&
            guard.operationLeaseId !== input.leaseId
          ) {
            return {
              kind: "in_progress" as const,
              retryAt: guard.operationLeaseExpiresAt,
            };
          }
          const [claimed] = await tx
            .insert(cloudVmPublicationVmGuards)
            .values({
              vmId: vm.id,
              operationLeaseId: input.leaseId,
              operationLeaseExpiresAt: input.leaseExpiresAt,
              createdAt: input.now,
              updatedAt: input.now,
            })
            .onConflictDoUpdate({
              target: cloudVmPublicationVmGuards.vmId,
              set: {
                operationLeaseId: input.leaseId,
                operationLeaseExpiresAt: input.leaseExpiresAt,
                updatedAt: input.now,
              },
            })
            .returning({ vmId: cloudVmPublicationVmGuards.vmId });
          if (!claimed)
            throw new Error("publication operation lease returned no row");
          return { kind: "claimed" as const, vmId: claimed.vmId };
        });
      }),

    releaseVmPublicationOperation: (input) =>
      databaseEffect("releaseVmPublicationOperation", async () => {
        const [publication] = await cloudDb()
          .select({ vmId: cloudVmPublications.vmId })
          .from(cloudVmPublications)
          .where(eq(cloudVmPublications.id, input.publicationId))
          .limit(1);
        if (!publication) return false;
        const [released] = await cloudDb()
          .update(cloudVmPublicationVmGuards)
          .set({
            operationLeaseId: null,
            operationLeaseExpiresAt: null,
            updatedAt: input.now,
          })
          .where(
            and(
              eq(cloudVmPublicationVmGuards.vmId, publication.vmId),
              eq(cloudVmPublicationVmGuards.operationLeaseId, input.leaseId),
            ),
          )
          .returning({
            vmId: cloudVmPublicationVmGuards.vmId,
            teardownStartedAt: cloudVmPublicationVmGuards.teardownStartedAt,
          });
        if (!released) return false;
        if (!released.teardownStartedAt) {
          await cloudDb()
            .delete(cloudVmPublicationVmGuards)
            .where(
              and(
                eq(cloudVmPublicationVmGuards.vmId, released.vmId),
                isNull(cloudVmPublicationVmGuards.teardownStartedAt),
                isNull(cloudVmPublicationVmGuards.operationLeaseId),
              ),
            );
        }
        return true;
      }),

    freezeVmPublicationsForDeletion: (input) =>
      repositoryEffect("freezeVmPublicationsForDeletion", async () => {
        const billingTeamId = input.billingTeamId?.trim() || null;
        if (
          billingTeamId &&
          billingTeamId !== input.requesterUserId &&
          !input.teamIds.includes(billingTeamId)
        ) {
          throw new PublicationNotFoundError({ resource: "vm" });
        }
        return await cloudDb().transaction(async (tx) => {
          const [vm] = await tx
            .select()
            .from(cloudVms)
            .where(
              and(
                vmAccountScopeWhere(input),
                eq(cloudVms.providerVmId, input.providerVmId),
                ne(cloudVms.status, "destroyed"),
              ),
            )
            .for("update")
            .limit(1);
          if (!vm) throw new PublicationNotFoundError({ resource: "vm" });

          const [guard] = await tx
            .select()
            .from(cloudVmPublicationVmGuards)
            .where(eq(cloudVmPublicationVmGuards.vmId, vm.id))
            .for("update")
            .limit(1);
          const operationInProgress = Boolean(
            guard?.operationLeaseId &&
            guard.operationLeaseExpiresAt &&
            guard.operationLeaseExpiresAt > input.now,
          );
          const operationLeaseId = operationInProgress
            ? (guard?.operationLeaseId ?? null)
            : null;
          const operationLeaseExpiresAt = operationInProgress
            ? (guard?.operationLeaseExpiresAt ?? null)
            : null;
          if (guard) {
            await tx
              .update(cloudVmPublicationVmGuards)
              .set({
                teardownStartedAt: guard.teardownStartedAt ?? input.now,
                operationLeaseId,
                operationLeaseExpiresAt,
                updatedAt: input.now,
              })
              .where(eq(cloudVmPublicationVmGuards.vmId, vm.id));
          } else {
            await tx.insert(cloudVmPublicationVmGuards).values({
              vmId: vm.id,
              teardownStartedAt: input.now,
              operationLeaseId,
              operationLeaseExpiresAt,
              createdAt: input.now,
              updatedAt: input.now,
            });
          }

          await tx
            .update(cloudVmPublications)
            .set({
              state: "disabling",
              routingRevision: sql`${cloudVmPublications.routingRevision} + 1`,
              updatedAt: input.now,
            })
            .where(
              and(
                eq(cloudVmPublications.vmId, vm.id),
                ne(cloudVmPublications.state, "disabling"),
                ne(cloudVmPublications.state, "disabled"),
              ),
            );

          if (operationInProgress && operationLeaseExpiresAt) {
            return {
              kind: "in_progress" as const,
              vmId: vm.id,
              retryAt: operationLeaseExpiresAt,
            };
          }
          const publications = await tx
            .select({
              publicationId: cloudVmPublications.id,
              provider: cloudVmDomains.provider,
              hostname: cloudVmPublications.hostname,
              providerTlsRuleId: cloudVmPublications.providerTlsRuleId,
              state: cloudVmPublications.state,
            })
            .from(cloudVmPublications)
            .innerJoin(
              cloudVmDomains,
              eq(cloudVmPublications.domainId, cloudVmDomains.id),
            )
            .where(
              and(
                eq(cloudVmPublications.vmId, vm.id),
                ne(cloudVmPublications.state, "disabled"),
              ),
            )
            .orderBy(
              asc(cloudVmPublications.createdAt),
              asc(cloudVmPublications.id),
            );
          return { kind: "ready" as const, vmId: vm.id, publications };
        });
      }),

    recordProvisioningTlsRule: (input) =>
      repositoryEffect("recordProvisioningTlsRule", async () => {
        try {
          return await cloudDb().transaction(async (tx) => {
            const publication = await requirePublicationRevision(tx, input);
            if (
              publication.state !== "provisioning" &&
              publication.state !== "unavailable"
            ) {
              throw new PublicationConflictError({
                reason: "publication_not_active",
              });
            }
            if (!publication.hostnameClaimedAt) {
              throw new PublicationConflictError({ reason: "hostname_taken" });
            }
            if (
              (publication.accessMode === "public") !==
              (input.providerForwardAuthId === null)
            ) {
              throw new PublicationConflictError({
                reason: "invalid_access_policy",
              });
            }
            const [updated] = await tx
              .update(cloudVmPublications)
              .set({
                providerTlsRuleId: input.providerTlsRuleId,
                providerForwardAuthId: input.providerForwardAuthId,
                updatedAt: input.now,
              })
              .where(eq(cloudVmPublications.id, publication.id))
              .returning();
            if (!updated)
              throw new Error("publication TLS rule update returned no row");
            return updated;
          });
        } catch (cause) {
          if (
            pgConstraint(cause) ===
            "cloud_vm_publications_provider_rule_unique"
          ) {
            throw new PublicationConflictError({
              reason: "provider_rule_in_use",
            });
          }
          throw cause;
        }
      }),

    activatePublication: (input) =>
      repositoryEffect("activatePublication", async () => {
        try {
          return await cloudDb().transaction(async (tx) => {
            const publication = await requirePublicationRevision(tx, input);
            if (
              !(["provisioning", "unavailable"] as const).includes(
                publication.state as "provisioning" | "unavailable",
              )
            ) {
              throw new PublicationConflictError({
                reason: "publication_not_active",
              });
            }
            if (
              (publication.accessMode === "public") !==
              (input.providerForwardAuthId === null)
            ) {
              throw new PublicationConflictError({
                reason: "invalid_access_policy",
              });
            }
            const [updated] = await tx
              .update(cloudVmPublications)
              .set({
                providerTlsRuleId: input.providerTlsRuleId,
                providerForwardAuthId: input.providerForwardAuthId,
                state: "active",
                updatedAt: input.now,
              })
              .where(eq(cloudVmPublications.id, publication.id))
              .returning();
            if (!updated)
              throw new Error("publication activation returned no row");
            return updated;
          });
        } catch (cause) {
          if (
            pgConstraint(cause) ===
            "cloud_vm_publications_provider_rule_unique"
          ) {
            throw new PublicationConflictError({
              reason: "provider_rule_in_use",
            });
          }
          throw cause;
        }
      }),

    commitAccessPolicy: (input) =>
      repositoryEffect("commitAccessPolicy", async () => {
        const teamId = normalizedTeamId(input.accessMode, input.teamId);
        return await cloudDb().transaction(async (tx) => {
          const publication = await requirePublicationRevision(tx, input);
          if (publication.state !== "active") {
            throw new PublicationConflictError({
              reason: "publication_not_active",
            });
          }
          const providerPatch =
            "appliedProviderForwardAuthId" in input
              ? {
                  providerForwardAuthId:
                    input.appliedProviderForwardAuthId ?? null,
                }
              : {};
          const [updated] = await tx
            .update(cloudVmPublications)
            .set({
              accessMode: input.accessMode,
              teamId,
              routingRevision: publication.routingRevision + 1,
              ...providerPatch,
              updatedAt: input.now,
            })
            .where(eq(cloudVmPublications.id, publication.id))
            .returning();
          if (!updated)
            throw new Error("publication policy update returned no row");
          return updated;
        });
      }),

    recordAppliedForwardAuth: (input) =>
      repositoryEffect("recordAppliedForwardAuth", async () => {
        const [updated] = await cloudDb()
          .update(cloudVmPublications)
          .set({
            providerForwardAuthId: input.providerForwardAuthId,
            updatedAt: input.now,
          })
          .where(
            and(
              eq(cloudVmPublications.id, input.id),
              eq(
                cloudVmPublications.routingRevision,
                input.expectedRoutingRevision,
              ),
              ne(cloudVmPublications.state, "disabled"),
            ),
          )
          .returning();
        if (!updated) {
          throw new PublicationConflictError({
            reason: "publication_revision_changed",
          });
        }
        return updated;
      }),

    markPublicationUnavailable: (input) =>
      repositoryEffect("markPublicationUnavailable", async () => {
        return await cloudDb().transaction(async (tx) => {
          const publication = await requirePublicationRevision(tx, input);
          if (
            publication.state === "disabled" ||
            publication.state === "disabling"
          ) {
            throw new PublicationConflictError({
              reason: "publication_not_active",
            });
          }
          const [updated] = await tx
            .update(cloudVmPublications)
            .set({
              state: "unavailable",
              routingRevision: publication.routingRevision + 1,
              updatedAt: input.now,
            })
            .where(eq(cloudVmPublications.id, publication.id))
            .returning();
          if (!updated)
            throw new Error("publication unavailable update returned no row");
          return updated;
        });
      }),

    beginDisablePublication: (input) =>
      repositoryEffect("beginDisablePublication", async () => {
        return await cloudDb().transaction(async (tx) => {
          const [publication] = await tx
            .select()
            .from(cloudVmPublications)
            .where(
              and(
                eq(cloudVmPublications.id, input.id),
                eq(cloudVmPublications.ownerUserId, input.ownerUserId),
              ),
            )
            .for("update")
            .limit(1);
          if (!publication)
            throw new PublicationNotFoundError({ resource: "publication" });
          if (
            publication.state === "disabled" ||
            publication.state === "disabling"
          ) {
            return publication;
          }
          const [updated] = await tx
            .update(cloudVmPublications)
            .set({
              state: "disabling",
              routingRevision: publication.routingRevision + 1,
              updatedAt: input.now,
            })
            .where(eq(cloudVmPublications.id, publication.id))
            .returning();
          if (!updated)
            throw new Error("publication disable start returned no row");
          return updated;
        });
      }),

    finishDisablePublication: (input) =>
      repositoryEffect("finishDisablePublication", async () => {
        const [updated] = await cloudDb()
          .update(cloudVmPublications)
          .set({
            state: "disabled",
            disabledAt: input.now,
            updatedAt: input.now,
          })
          .where(
            and(
              eq(cloudVmPublications.id, input.id),
              eq(cloudVmPublications.state, "disabling"),
              isNull(cloudVmPublications.disabledAt),
            ),
          )
          .returning();
        if (!updated)
          throw new PublicationConflictError({
            reason: "publication_not_active",
          });
        return updated;
      }),

    findOwnedPublication: (input) =>
      databaseEffect("findOwnedPublication", async () => {
        const [target] = await cloudDb()
          .select({
            publication: cloudVmPublications,
            domain: cloudVmDomains,
            vm: cloudVms,
          })
          .from(cloudVmPublications)
          .innerJoin(
            cloudVmDomains,
            eq(cloudVmPublications.domainId, cloudVmDomains.id),
          )
          .innerJoin(cloudVms, eq(cloudVmPublications.vmId, cloudVms.id))
          .where(
            and(
              eq(cloudVmPublications.id, input.id),
              eq(cloudVmPublications.ownerUserId, input.ownerUserId),
            ),
          )
          .limit(1);
        return target ?? null;
      }),

    findOwnedPublicationByHostname: (input) =>
      databaseEffect("findOwnedPublicationByHostname", async () => {
        const [target] = await cloudDb()
          .select({
            publication: cloudVmPublications,
            domain: cloudVmDomains,
            vm: cloudVms,
          })
          .from(cloudVmPublications)
          .innerJoin(
            cloudVmDomains,
            eq(cloudVmPublications.domainId, cloudVmDomains.id),
          )
          .innerJoin(cloudVms, eq(cloudVmPublications.vmId, cloudVms.id))
          .where(
            and(
              eq(cloudVmPublications.hostname, normalizedHostname(input.hostname)),
              eq(cloudVmPublications.ownerUserId, input.ownerUserId),
              isNull(cloudVmPublications.disabledAt),
            ),
          )
          .limit(1);
        return target ?? null;
      }),
    listOwnedPublications: (ownerUserId) =>
      databaseEffect(
        "listOwnedPublications",
        async () =>
          await cloudDb()
            .select({
              publication: cloudVmPublications,
              domain: cloudVmDomains,
              vm: cloudVms,
            })
            .from(cloudVmPublications)
            .innerJoin(
              cloudVmDomains,
              eq(cloudVmPublications.domainId, cloudVmDomains.id),
            )
            .innerJoin(cloudVms, eq(cloudVmPublications.vmId, cloudVms.id))
            .where(eq(cloudVmPublications.ownerUserId, ownerUserId))
            .orderBy(desc(cloudVmPublications.createdAt)),
      ),

    listOwnedPublicationsForDomain: (input) =>
      databaseEffect(
        "listOwnedPublicationsForDomain",
        async () =>
          await cloudDb()
            .select({
              publication: cloudVmPublications,
              domain: cloudVmDomains,
              vm: cloudVms,
            })
            .from(cloudVmPublications)
            .innerJoin(
              cloudVmDomains,
              eq(cloudVmPublications.domainId, cloudVmDomains.id),
            )
            .innerJoin(cloudVms, eq(cloudVmPublications.vmId, cloudVms.id))
            .where(
              and(
                eq(cloudVmPublications.ownerUserId, input.ownerUserId),
                eq(cloudVmPublications.domainId, input.domainId),
              ),
            )
            .orderBy(desc(cloudVmPublications.createdAt)),
      ),
    listPublicationsForAccountDeletion: (ownerUserId) =>
      databaseEffect(
        "listPublicationsForAccountDeletion",
        async () =>
          await cloudDb()
            .select({
              publicationId: cloudVmPublications.id,
              provider: cloudVmDomains.provider,
              hostname: cloudVmPublications.hostname,
              providerTlsRuleId: cloudVmPublications.providerTlsRuleId,
            })
            .from(cloudVmPublications)
            .innerJoin(
              cloudVmDomains,
              eq(cloudVmPublications.domainId, cloudVmDomains.id),
            )
            // A disabled publication's hostname may already be claimed by
            // another account, so its rules are never swept again.
            .where(
              and(
                eq(cloudVmPublications.ownerUserId, ownerUserId),
                ne(cloudVmPublications.state, "disabled"),
              ),
            )
            .orderBy(
              asc(cloudVmPublications.createdAt),
              asc(cloudVmPublications.id),
            ),
      ),

    findActivePublicationForRequest: (input) =>
      databaseEffect("findActivePublicationForRequest", async () => {
        const [target] = await cloudDb()
          .select({
            publication: cloudVmPublications,
            domain: cloudVmDomains,
            vm: cloudVms,
          })
          .from(cloudVmPublications)
          .innerJoin(
            cloudVmDomains,
            eq(cloudVmPublications.domainId, cloudVmDomains.id),
          )
          .innerJoin(cloudVms, eq(cloudVmPublications.vmId, cloudVms.id))
          .where(
            and(
              eq(
                cloudVmPublications.hostname,
                normalizedHostname(input.hostname),
              ),
              eq(
                cloudVmPublications.providerTlsRuleId,
                input.providerTlsRuleId,
              ),
              eq(cloudVmPublications.state, "active"),
              isNull(cloudVmPublications.disabledAt),
              inArray(cloudVms.status, ["running", "paused"]),
            ),
          )
          .limit(1);
        return target ?? null;
      }),

    createAuthTransaction: (input) =>
      repositoryEffect("createAuthTransaction", async () => {
        return await cloudDb().transaction(async (tx) => {
          const [target] = await tx
            .select({
              publication: cloudVmPublications,
              domain: cloudVmDomains,
            })
            .from(cloudVmPublications)
            .innerJoin(
              cloudVmDomains,
              eq(cloudVmPublications.domainId, cloudVmDomains.id),
            )
            .where(
              and(
                eq(cloudVmPublications.id, input.publicationId),
                eq(cloudVmPublications.state, "active"),
                isNull(cloudVmPublications.disabledAt),
              ),
            )
            .limit(1);
          if (!target)
            throw new PublicationNotFoundError({ resource: "publication" });
          if (
            target.publication.hostname !== normalizedHostname(input.hostname)
          ) {
            throw new PublicationAuthArtifactError({
              reason: "transaction_host_mismatch",
            });
          }
          await sweepAuthTransactions(tx, target.publication.id, input.now);
          const [transaction] = await tx
            .insert(cloudVmPublicationAuthTransactions)
            .values({
              transactionHash: input.transactionHash,
              publicationId: target.publication.id,
              routingRevision: target.publication.routingRevision,
              pkceChallenge: input.pkceChallenge,
              stateHash: input.stateHash,
              hostname: target.publication.hostname,
              returnPath: input.returnPath,
              createdAt: input.now,
              expiresAt: input.expiresAt,
            })
            .returning();
          if (!transaction)
            throw new Error("auth transaction insert returned no row");
          return transaction;
        });
      }),

    findPendingAuthTransaction: (input) =>
      databaseEffect("findPendingAuthTransaction", async () => {
        const [target] = await cloudDb()
          .select({
            transaction: cloudVmPublicationAuthTransactions,
            publication: cloudVmPublications,
            domain: cloudVmDomains,
          })
          .from(cloudVmPublicationAuthTransactions)
          .innerJoin(
            cloudVmPublications,
            eq(
              cloudVmPublicationAuthTransactions.publicationId,
              cloudVmPublications.id,
            ),
          )
          .innerJoin(
            cloudVmDomains,
            eq(cloudVmPublications.domainId, cloudVmDomains.id),
          )
          .where(
            and(
              eq(
                cloudVmPublicationAuthTransactions.transactionHash,
                input.transactionHash,
              ),
              gt(cloudVmPublicationAuthTransactions.expiresAt, input.now),
              isNull(cloudVmPublicationAuthTransactions.consumedAt),
              eq(
                cloudVmPublicationAuthTransactions.routingRevision,
                cloudVmPublications.routingRevision,
              ),
              eq(
                cloudVmPublicationAuthTransactions.hostname,
                cloudVmPublications.hostname,
              ),
              eq(cloudVmPublications.state, "active"),
              isNull(cloudVmPublications.disabledAt),
            ),
          )
          .limit(1);
        return target ?? null;
      }),

    issueAuthCode: (input) =>
      repositoryEffect("issueAuthCode", async () => {
        return await cloudDb().transaction(async (tx) => {
          try {
            await assertAccountDeletionUserMutationAllowed(tx, input.userId);
          } catch (cause) {
            throw accountDeletionError(cause);
          }
          const [transaction] = await tx
            .select()
            .from(cloudVmPublicationAuthTransactions)
            .where(
              eq(
                cloudVmPublicationAuthTransactions.transactionHash,
                input.transactionHash,
              ),
            )
            .for("update")
            .limit(1);
          if (!transaction) {
            throw new PublicationAuthArtifactError({
              reason: "transaction_invalid",
            });
          }
          if (transaction.consumedAt) {
            throw new PublicationAuthArtifactError({
              reason: "transaction_replayed",
            });
          }
          if (transaction.expiresAt <= input.now) {
            throw new PublicationAuthArtifactError({
              reason: "transaction_expired",
            });
          }
          if (transaction.stateHash !== input.stateHash) {
            throw new PublicationAuthArtifactError({
              reason: "transaction_state_mismatch",
            });
          }
          const [publication] = await tx
            .select()
            .from(cloudVmPublications)
            .where(eq(cloudVmPublications.id, transaction.publicationId))
            .for("update")
            .limit(1);
          if (
            !publication ||
            publication.state !== "active" ||
            publication.disabledAt ||
            publication.routingRevision !== transaction.routingRevision
          ) {
            throw new PublicationAuthArtifactError({
              reason: "publication_revision_changed",
            });
          }
          const [code] = await tx
            .insert(cloudVmPublicationAuthCodes)
            .values({
              codeHash: input.codeHash,
              transactionHash: transaction.transactionHash,
              publicationId: publication.id,
              userId: input.userId,
              routingRevision: publication.routingRevision,
              createdAt: input.now,
              expiresAt: input.expiresAt,
            })
            .returning();
          if (!code)
            throw new Error("authorization code insert returned no row");
          await tx
            .update(cloudVmPublicationAuthTransactions)
            .set({ consumedAt: input.now })
            .where(
              and(
                eq(
                  cloudVmPublicationAuthTransactions.transactionHash,
                  transaction.transactionHash,
                ),
                isNull(cloudVmPublicationAuthTransactions.consumedAt),
              ),
            );
          return {
            code,
            transaction: { ...transaction, consumedAt: input.now },
          };
        });
      }),

    consumeAuthCodeAndCreateSession: (input) =>
      repositoryEffect("consumeAuthCodeAndCreateSession", async () => {
        return await cloudDb().transaction(async (tx) => {
          const [candidate] = await tx
            .select({ userId: cloudVmPublicationAuthCodes.userId })
            .from(cloudVmPublicationAuthCodes)
            .where(
              and(
                eq(cloudVmPublicationAuthCodes.codeHash, input.codeHash),
                eq(
                  cloudVmPublicationAuthCodes.transactionHash,
                  input.transactionHash,
                ),
              ),
            )
            .limit(1);
          if (!candidate) {
            throw new PublicationAuthArtifactError({
              reason: "authorization_code_invalid",
            });
          }
          // Take the account-deletion advisory lock before the row lock below.
          // This preserves the global lock order and prevents a session from
          // resurrecting after privacy cleanup has started.
          try {
            await assertAccountDeletionUserMutationAllowed(
              tx,
              candidate.userId,
            );
          } catch (cause) {
            throw accountDeletionError(cause);
          }
          const [code] = await tx
            .select()
            .from(cloudVmPublicationAuthCodes)
            .where(
              and(
                eq(cloudVmPublicationAuthCodes.codeHash, input.codeHash),
                eq(
                  cloudVmPublicationAuthCodes.transactionHash,
                  input.transactionHash,
                ),
              ),
            )
            .for("update")
            .limit(1);
          if (!code) {
            throw new PublicationAuthArtifactError({
              reason: "authorization_code_invalid",
            });
          }
          if (code.consumedAt) {
            throw new PublicationAuthArtifactError({
              reason: "authorization_code_replayed",
            });
          }
          if (code.expiresAt <= input.now) {
            throw new PublicationAuthArtifactError({
              reason: "authorization_code_expired",
            });
          }
          const [transaction] = await tx
            .select()
            .from(cloudVmPublicationAuthTransactions)
            .where(
              eq(
                cloudVmPublicationAuthTransactions.transactionHash,
                code.transactionHash,
              ),
            )
            .limit(1);
          if (!transaction || !transaction.consumedAt) {
            throw new PublicationAuthArtifactError({
              reason: "transaction_invalid",
            });
          }
          if (transaction.stateHash !== input.stateHash) {
            throw new PublicationAuthArtifactError({
              reason: "transaction_state_mismatch",
            });
          }
          if (transaction.pkceChallenge !== input.pkceChallenge) {
            throw new PublicationAuthArtifactError({
              reason: "transaction_pkce_mismatch",
            });
          }
          if (transaction.hostname !== normalizedHostname(input.hostname)) {
            throw new PublicationAuthArtifactError({
              reason: "transaction_host_mismatch",
            });
          }
          const [target] = await tx
            .select({
              publication: cloudVmPublications,
              domain: cloudVmDomains,
            })
            .from(cloudVmPublications)
            .innerJoin(
              cloudVmDomains,
              eq(cloudVmPublications.domainId, cloudVmDomains.id),
            )
            .where(eq(cloudVmPublications.id, code.publicationId))
            .for("update")
            .limit(1);
          if (
            !target ||
            target.publication.state !== "active" ||
            target.publication.disabledAt ||
            target.publication.routingRevision !== code.routingRevision ||
            target.publication.routingRevision !== transaction.routingRevision
          ) {
            throw new PublicationAuthArtifactError({
              reason: "publication_revision_changed",
            });
          }
          if (target.publication.hostname !== transaction.hostname) {
            throw new PublicationAuthArtifactError({
              reason: "transaction_host_mismatch",
            });
          }
          await sweepPublicationSessions(tx, target.publication.id, input.now);
          const [session] = await tx
            .insert(cloudVmPublicationSessions)
            .values({
              tokenHash: input.sessionTokenHash,
              publicationId: target.publication.id,
              userId: code.userId,
              routingRevision: target.publication.routingRevision,
              createdAt: input.now,
              expiresAt: input.sessionExpiresAt,
            })
            .returning();
          if (!session)
            throw new Error("publication session insert returned no row");
          await tx
            .update(cloudVmPublicationAuthCodes)
            .set({ consumedAt: input.now })
            .where(
              and(
                eq(cloudVmPublicationAuthCodes.codeHash, code.codeHash),
                isNull(cloudVmPublicationAuthCodes.consumedAt),
              ),
            );
          return {
            session,
            publication: target.publication,
            returnPath: transaction.returnPath,
          };
        });
      }),

    findValidSession: (input) =>
      databaseEffect("findValidSession", async () => {
        const [principal] = await cloudDb()
          .select({
            session: cloudVmPublicationSessions,
            publication: cloudVmPublications,
            domain: cloudVmDomains,
          })
          .from(cloudVmPublicationSessions)
          .innerJoin(
            cloudVmPublications,
            eq(
              cloudVmPublicationSessions.publicationId,
              cloudVmPublications.id,
            ),
          )
          .innerJoin(
            cloudVmDomains,
            eq(cloudVmPublications.domainId, cloudVmDomains.id),
          )
          .where(
            and(
              eq(cloudVmPublicationSessions.tokenHash, input.tokenHash),
              eq(cloudVmPublicationSessions.publicationId, input.publicationId),
              gt(cloudVmPublicationSessions.expiresAt, input.now),
              isNull(cloudVmPublicationSessions.revokedAt),
              eq(
                cloudVmPublicationSessions.routingRevision,
                cloudVmPublications.routingRevision,
              ),
              eq(cloudVmPublications.state, "active"),
              isNull(cloudVmPublications.disabledAt),
              eq(
                cloudVmPublications.hostname,
                normalizedHostname(input.hostname),
              ),
            ),
          )
          .limit(1);
        return principal ?? null;
      }),

    revokePublicationSessions: (input) =>
      databaseEffect("revokePublicationSessions", async () => {
        const revoked = await cloudDb()
          .update(cloudVmPublicationSessions)
          .set({ revokedAt: input.now })
          .where(
            and(
              eq(cloudVmPublicationSessions.publicationId, input.publicationId),
              isNull(cloudVmPublicationSessions.revokedAt),
            ),
          )
          .returning({ tokenHash: cloudVmPublicationSessions.tokenHash });
        return revoked.length;
      }),
  },
);

export async function runCloudVmPublicationRepositoryEffect<A, E>(
  program: Effect.Effect<A, E, CloudVmPublicationRepository>,
): Promise<A> {
  const result = await Effect.runPromise(
    program.pipe(
      Effect.provide(CloudVmPublicationRepositoryLive),
      Effect.either,
    ),
  );
  if (result._tag === "Left") throw result.left;
  return result.right;
}
