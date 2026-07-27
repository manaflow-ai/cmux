import { and, asc, count, eq, gt, inArray, isNull, lte, ne, or, sql } from "drizzle-orm";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { cloudDb } from "../../db/client";
import {
  AccountDeletionMutationBlockedError,
  assertAccountDeletionUserMutationAllowed,
} from "../account/deletionLock";
import {
  irohAccountSecurityStates,
  irohEndpointBindings,
  irohPairGrantIssuances,
  irohRegistrationChallenges,
  irohRelayTokenIssuances,
} from "../../db/schema";
import {
  IrohConflictError,
  IrohDatabaseError,
  IrohForbiddenError,
  IrohNotFoundError,
  IrohQuotaExceededError,
} from "./errors";
import type { PairGrantPeer } from "./crypto";
import type { IrohBindingQuota, IrohChallengeQuota } from "./config";
import {
  nextPathHintExpiry,
  parseIrohPathHint,
  sha256,
  type IrohPathHint,
  type IrohRegistrationPayload,
} from "./model";

export const IROH_RETENTION_BATCH_SIZE = 500;
export const IROH_RETENTION_MAX_ROWS = 10_000;
export const IROH_RETENTION_MAX_DURATION_MS = 8_000;
export const IROH_ACCOUNT_CHALLENGE_LIMIT = 120;
export const IROH_RELAY_RESERVATION_LEASE_MS = 60 * 1_000;

export type IrohRetentionCategory =
  | "revokedHints"
  | "expiredHints"
  | "expiredChallenges"
  | "consumedChallenges"
  | "relayAudits"
  | "pairGrantAudits"
  | "revokedBindings";

export type IrohRetentionResult = {
  readonly rowsProcessed: number;
  readonly batches: number;
  readonly backlog: boolean;
  readonly budgetExhausted: "rows" | "time" | null;
  readonly byCategory: Readonly<Record<IrohRetentionCategory, number>>;
};

export type IrohBindingRecord = typeof irohEndpointBindings.$inferSelect;
export type IrohChallengeRecord = typeof irohRegistrationChallenges.$inferSelect;
export type IrohRegistrationCommit = {
  readonly binding: IrohBindingRecord;
  readonly created: boolean;
};
type CloudDbTransaction = Parameters<Parameters<ReturnType<typeof cloudDb>["transaction"]>[0]>[0];

type RepositoryError =
  | IrohDatabaseError
  | IrohForbiddenError
  | IrohNotFoundError
  | IrohConflictError
  | IrohQuotaExceededError;

export type IrohRepositoryShape = {
  readonly issueChallenge: (input: {
    readonly userId: string;
    readonly deviceUuid: string;
    readonly appInstanceId: string;
    readonly tag: string;
    readonly endpointId: string;
    readonly identityGeneration: number;
    readonly payloadSha256: string;
    readonly nonceHash: string;
    readonly now: Date;
    readonly expiresAt: Date;
    readonly challengeQuota?: IrohChallengeQuota;
  }) => Effect.Effect<IrohChallengeRecord, RepositoryError>;
  readonly findChallenge: (
    userId: string,
    challengeId: string,
  ) => Effect.Effect<IrohChallengeRecord | null, RepositoryError>;
  readonly consumeChallengeAndRegister: (input: {
    readonly userId: string;
    readonly challengeId: string;
    readonly nonceHash: string;
    readonly payload: IrohRegistrationPayload;
    readonly now: Date;
    readonly bindingQuota: IrohBindingQuota;
  }) => Effect.Effect<IrohRegistrationCommit, RepositoryError>;
  readonly discoverySnapshot: (input: {
    readonly userId: string;
    readonly now: Date;
  }) => Effect.Effect<{
    readonly bindings: IrohBindingRecord[];
    readonly lanDiscoveryGeneration: number;
  }, RepositoryError>;
  readonly findActiveBindings: (
    userId: string,
    bindingIds: readonly string[],
  ) => Effect.Effect<IrohBindingRecord[], RepositoryError>;
  readonly findActiveBindingByEndpoint: (
    userId: string,
    endpointId: string,
  ) => Effect.Effect<IrohBindingRecord | null, RepositoryError>;
  /** Returns true when the exact binding is owned and revoked, including retries. */
  readonly revokeBinding: (input: {
    readonly userId: string;
    readonly bindingId: string;
    readonly now: Date;
  }) => Effect.Effect<boolean, RepositoryError>;
  readonly pruneExpiredState: (input: {
    readonly userId: string;
    readonly now: Date;
  }) => Effect.Effect<void, RepositoryError>;
  readonly pruneExpiredStateGlobally: (input: {
    readonly now: Date;
    readonly maxRows?: number;
    readonly maxDurationMs?: number;
  }) => Effect.Effect<IrohRetentionResult, RepositoryError>;
  readonly finalizeEndpointAttestation: (input: {
    readonly userId: string;
    readonly bindingId: string;
    readonly deviceId: string;
    readonly endpointId: string;
    readonly identityGeneration: number;
    readonly platform: "mac" | "ios";
  }) => Effect.Effect<void, RepositoryError>;
  readonly recordPairGrant: (input: {
    readonly userId: string;
    readonly jti: string;
    readonly initiator: PairGrantPeer;
    readonly acceptor: PairGrantPeer;
    readonly signingKeyId: string;
    readonly alpn: string;
    readonly scope: string;
    readonly issuedAt: Date;
    readonly notBefore: Date;
    readonly expiresAt: Date;
  }) => Effect.Effect<void, RepositoryError>;
  readonly reserveRelayIssuance: (input: {
    readonly userId: string;
    readonly bindingId: string;
    readonly now: Date;
  }) => Effect.Effect<{
    readonly issuanceId: string;
    readonly binding: IrohBindingRecord;
  }, RepositoryError>;
  readonly completeRelayIssuance: (input: {
    readonly userId: string;
    readonly issuanceId: string;
    readonly bindingId: string;
    readonly endpointId: string;
    readonly tokenHash: string;
    readonly completedAt: Date;
    readonly expiresAt: Date;
  }) => Effect.Effect<boolean, RepositoryError>;
  readonly failRelayIssuance: (input: {
    readonly userId: string;
    readonly issuanceId: string;
    readonly completedAt: Date;
    readonly failureCode: string;
  }) => Effect.Effect<void, RepositoryError>;
};

export class IrohRepository extends Context.Tag("cmux/IrohRepository")<
  IrohRepository,
  IrohRepositoryShape
>() {}

export const IrohRepositoryLive = Layer.succeed(IrohRepository, makeLiveRepository());

function makeLiveRepository(): IrohRepositoryShape {
  return {
    issueChallenge: (input) => repositoryEffect("issue_challenge", async () => {
      const db = cloudDb();
      return await db.transaction(async (tx) => {
        const challengeQuota = input.challengeQuota ?? {
          account: IROH_ACCOUNT_CHALLENGE_LIMIT,
          deviceInstance: 6,
          outstanding: 32,
        };
        await assertIrohUserMutationAllowed(tx, input.userId);
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`iroh:challenge:${input.userId}`}, 0))`);
        const tenMinutesAgo = new Date(input.now.getTime() - 10 * 60 * 1_000);
        const [recentForAccount] = await tx
          .select({ total: count() })
          .from(irohRegistrationChallenges)
          .where(and(
            eq(irohRegistrationChallenges.userId, input.userId),
            gt(irohRegistrationChallenges.createdAt, tenMinutesAgo),
          ));
        if ((recentForAccount?.total ?? 0) >= challengeQuota.account) {
          throw new IrohQuotaExceededError({
            code: "challenge_account_rate_limited",
            retryAfterSeconds: 600,
          });
        }
        const [recentForDeviceInstance] = await tx
          .select({ total: count() })
          .from(irohRegistrationChallenges)
          .where(and(
            eq(irohRegistrationChallenges.userId, input.userId),
            eq(irohRegistrationChallenges.deviceUuid, input.deviceUuid),
            eq(irohRegistrationChallenges.appInstanceId, input.appInstanceId),
            gt(irohRegistrationChallenges.createdAt, tenMinutesAgo),
          ));
        if ((recentForDeviceInstance?.total ?? 0) >= challengeQuota.deviceInstance) {
          throw new IrohQuotaExceededError({ code: "challenge_rate_limited", retryAfterSeconds: 600 });
        }
        const [outstanding] = await tx
          .select({ total: count() })
          .from(irohRegistrationChallenges)
          .where(and(
            eq(irohRegistrationChallenges.userId, input.userId),
            isNull(irohRegistrationChallenges.consumedAt),
            gt(irohRegistrationChallenges.expiresAt, input.now),
          ));
        if ((outstanding?.total ?? 0) >= challengeQuota.outstanding) {
          throw new IrohQuotaExceededError({ code: "too_many_outstanding_challenges", retryAfterSeconds: 300 });
        }
        const [challenge] = await tx
          .insert(irohRegistrationChallenges)
          .values({
            userId: input.userId,
            deviceUuid: input.deviceUuid,
            appInstanceId: input.appInstanceId,
            tag: input.tag,
            endpointId: input.endpointId,
            identityGeneration: input.identityGeneration,
            payloadSha256: input.payloadSha256,
            nonceHash: input.nonceHash,
            createdAt: input.now,
            expiresAt: input.expiresAt,
          })
          .returning();
        if (!challenge) throw new Error("challenge insert returned no row");
        return challenge;
      });
    }),

    findChallenge: (userId, challengeId) => repositoryEffect("find_challenge", async () => {
      const [challenge] = await cloudDb()
        .select()
        .from(irohRegistrationChallenges)
        .where(and(
          eq(irohRegistrationChallenges.id, challengeId),
          eq(irohRegistrationChallenges.userId, userId),
        ))
        .limit(1);
      return challenge ?? null;
    }),

    consumeChallengeAndRegister: (input) => repositoryEffect("register_binding", async () => {
      const db = cloudDb();
      return await db.transaction(async (tx) => {
        const accountPrivatePathHints = [...input.payload.pathHints];
        await assertIrohUserMutationAllowed(tx, input.userId);
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`iroh:binding:${input.userId}`}, 0))`);
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`iroh:endpoint:${input.payload.endpointId}`}, 0))`);
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`iroh:app:${input.payload.appInstanceId}`}, 0))`);
        const [challenge] = await tx
          .select()
          .from(irohRegistrationChallenges)
          .where(and(
            eq(irohRegistrationChallenges.id, input.challengeId),
            eq(irohRegistrationChallenges.userId, input.userId),
          ))
          .for("update")
          .limit(1);
        if (!challenge) throw new IrohNotFoundError({ resource: "challenge" });
        if (challenge.consumedAt) throw new IrohConflictError({ code: "challenge_replayed" });
        if (challenge.expiresAt <= input.now) throw new IrohForbiddenError({ code: "challenge_expired" });
        if (challenge.nonceHash !== input.nonceHash) throw new IrohForbiddenError({ code: "invalid_challenge_nonce" });

        const [existingApp] = await tx
          .select()
          .from(irohEndpointBindings)
          .where(and(
            eq(irohEndpointBindings.appInstanceId, input.payload.appInstanceId),
            isNull(irohEndpointBindings.revokedAt),
          ))
          .for("update")
          .limit(1);

        if (existingApp) {
          if (
            existingApp.userId !== input.userId ||
            existingApp.endpointId !== input.payload.endpointId ||
            existingApp.identityGeneration !== input.payload.identityGeneration ||
            existingApp.deviceUuid !== input.payload.deviceId ||
            existingApp.tag !== input.payload.tag ||
            existingApp.platform !== input.payload.platform
          ) {
            throw new IrohConflictError({ code: "binding_replacement_requires_revocation" });
          }
          const [updated] = await tx
            .update(irohEndpointBindings)
            .set({
              displayName: input.payload.displayName ?? null,
              pairingEnabled: input.payload.pairingEnabled,
              capabilities: [...input.payload.capabilities],
              directPortV4: input.payload.directPorts?.ipv4 ?? null,
              directPortV6: input.payload.directPorts?.ipv6 ?? null,
              pathHints: accountPrivatePathHints,
              pathHintsNextExpiry: nextPathHintExpiry(accountPrivatePathHints),
              lastSeenAt: input.now,
              updatedAt: input.now,
            })
            .where(eq(irohEndpointBindings.id, existingApp.id))
            .returning();
          await tx
            .update(irohRegistrationChallenges)
            .set({ consumedAt: input.now })
            .where(eq(irohRegistrationChallenges.id, challenge.id));
          if (!updated) throw new Error("binding update returned no row");
          return { binding: updated, created: false };
        }

        const [endpointOwner] = await tx
          .select({ id: irohEndpointBindings.id })
          .from(irohEndpointBindings)
          .where(and(
            eq(irohEndpointBindings.endpointId, input.payload.endpointId),
            isNull(irohEndpointBindings.revokedAt),
          ))
          .for("update")
          .limit(1);
        if (endpointOwner) throw new IrohConflictError({ code: "endpoint_already_bound" });

        let [deviceTotal] = await tx
          .select({ total: count() })
          .from(irohEndpointBindings)
          .where(and(
            eq(irohEndpointBindings.userId, input.userId),
            eq(irohEndpointBindings.deviceUuid, input.payload.deviceId),
            isNull(irohEndpointBindings.revokedAt),
          ));
        let deviceBindingCount = deviceTotal?.total ?? 0;
        if (deviceBindingCount >= input.bindingQuota.device) {
          const recycled = await recycleStaleBindings(tx, {
            userId: input.userId,
            deviceUuid: input.payload.deviceId,
            now: input.now,
            staleAfterMs: input.bindingQuota.staleAfterMs,
            count: deviceBindingCount - input.bindingQuota.device + 1,
          });
          deviceBindingCount -= recycled;
          if (deviceBindingCount >= input.bindingQuota.device) {
            throw new IrohQuotaExceededError({ code: "too_many_device_bindings", retryAfterSeconds: 86_400 });
          }
        }

        const [userTotal] = await tx
          .select({ total: count() })
          .from(irohEndpointBindings)
          .where(and(
            eq(irohEndpointBindings.userId, input.userId),
            isNull(irohEndpointBindings.revokedAt),
          ));
        let userBindingCount = userTotal?.total ?? 0;
        if (userBindingCount >= input.bindingQuota.account) {
          const recycled = await recycleStaleBindings(tx, {
            userId: input.userId,
            now: input.now,
            staleAfterMs: input.bindingQuota.staleAfterMs,
            count: userBindingCount - input.bindingQuota.account + 1,
          });
          userBindingCount -= recycled;
          if (userBindingCount >= input.bindingQuota.account) {
            throw new IrohQuotaExceededError({ code: "too_many_bindings", retryAfterSeconds: 86_400 });
          }
        }

        [deviceTotal] = await tx
          .select({ total: count() })
          .from(irohEndpointBindings)
          .where(and(
            eq(irohEndpointBindings.userId, input.userId),
            eq(irohEndpointBindings.deviceUuid, input.payload.deviceId),
            isNull(irohEndpointBindings.revokedAt),
          ));
        deviceBindingCount = deviceTotal?.total ?? 0;
        const usesDeviceOverride = deviceBindingCount >= input.bindingQuota.baselineDevice;

        const [binding] = await tx
          .insert(irohEndpointBindings)
          .values({
            userId: input.userId,
            deviceUuid: input.payload.deviceId,
            appInstanceId: input.payload.appInstanceId,
            tag: input.payload.tag,
            platform: input.payload.platform,
            displayName: input.payload.displayName ?? null,
            endpointId: input.payload.endpointId,
            identityGeneration: input.payload.identityGeneration,
            pairingEnabled: input.payload.pairingEnabled,
            capabilities: [...input.payload.capabilities],
            directPortV4: input.payload.directPorts?.ipv4 ?? null,
            directPortV6: input.payload.directPorts?.ipv6 ?? null,
            pathHints: accountPrivatePathHints,
            pathHintsNextExpiry: nextPathHintExpiry(accountPrivatePathHints),
            deviceLimitOverrideUsed: usesDeviceOverride,
            lastSeenAt: input.now,
            registeredAt: input.now,
            updatedAt: input.now,
          })
          .returning();
        if (!binding) throw new Error("binding insert returned no row");
        await tx
          .insert(irohAccountSecurityStates)
          .values({ userId: input.userId, lanDiscoveryGeneration: 1, createdAt: input.now, updatedAt: input.now })
          .onConflictDoNothing({ target: irohAccountSecurityStates.userId });
        await tx
          .update(irohRegistrationChallenges)
          .set({ consumedAt: input.now })
          .where(and(
            eq(irohRegistrationChallenges.id, challenge.id),
            isNull(irohRegistrationChallenges.consumedAt),
          ));
        return { binding, created: true };
      });
    }),

    discoverySnapshot: (input) => repositoryEffect("discovery_snapshot", async () => {
      return await cloudDb().transaction(async (tx) => {
        await assertIrohUserMutationAllowed(tx, input.userId);
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`iroh:binding:${input.userId}`}, 0))`);
        const [state] = await tx
          .insert(irohAccountSecurityStates)
          .values({ userId: input.userId, lanDiscoveryGeneration: 1, createdAt: input.now, updatedAt: input.now })
          .onConflictDoUpdate({
            target: irohAccountSecurityStates.userId,
            set: { updatedAt: sql`${irohAccountSecurityStates.updatedAt}` },
          })
          .returning({ generation: irohAccountSecurityStates.lanDiscoveryGeneration });
        if (!state) throw new Error("account security state returned no row");
        const bindings = await tx
          .select()
          .from(irohEndpointBindings)
          .where(and(
            eq(irohEndpointBindings.userId, input.userId),
            isNull(irohEndpointBindings.revokedAt),
          ))
          .orderBy(asc(irohEndpointBindings.registeredAt));
        return {
          bindings,
          lanDiscoveryGeneration: state.generation,
        };
      });
    }),

    findActiveBindings: (userId, bindingIds) => repositoryEffect("find_bindings", async () => {
      if (bindingIds.length === 0) return [];
      return await cloudDb().transaction(async (tx) => {
        await assertIrohUserMutationAllowed(tx, userId);
        return await tx
          .select()
          .from(irohEndpointBindings)
          .where(and(
            eq(irohEndpointBindings.userId, userId),
            inArray(irohEndpointBindings.id, [...bindingIds]),
            isNull(irohEndpointBindings.revokedAt),
          ));
      });
    }),

    findActiveBindingByEndpoint: (userId, endpointId) => repositoryEffect(
      "find_binding_by_endpoint",
      async () => {
        const [binding] = await cloudDb()
          .select()
          .from(irohEndpointBindings)
          .where(and(
            eq(irohEndpointBindings.userId, userId),
            eq(irohEndpointBindings.endpointId, endpointId),
            isNull(irohEndpointBindings.revokedAt),
          ))
          .limit(1);
        return binding ?? null;
      },
    ),

    revokeBinding: (input) => repositoryEffect("revoke_binding", async () => {
      return await cloudDb().transaction(async (tx) => {
        await assertIrohUserMutationAllowed(tx, input.userId);
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`iroh:binding:${input.userId}`}, 0))`);
        const [binding] = await tx
          .select({ revokedAt: irohEndpointBindings.revokedAt })
          .from(irohEndpointBindings)
          .where(and(
            eq(irohEndpointBindings.id, input.bindingId),
            eq(irohEndpointBindings.userId, input.userId),
          ))
          .for("update")
          .limit(1);
        if (!binding) return false;
        if (binding.revokedAt) return true;

        const revoked = await revokeActiveBindings(tx, {
          userId: input.userId,
          bindingIds: [input.bindingId],
          now: input.now,
          reason: "user_requested",
        });
        if (revoked.length === 0) return false;
        return true;
      });
    }),

    pruneExpiredState: (input) => repositoryEffect("prune_expired_state", async () => {
      await cloudDb().transaction(async (tx) => {
        await assertIrohUserMutationAllowed(tx, input.userId);
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`iroh:binding:${input.userId}`}, 0))`);
        const bindings = await tx
          .select({
            id: irohEndpointBindings.id,
            pathHints: irohEndpointBindings.pathHints,
          })
          .from(irohEndpointBindings)
          .where(and(
            eq(irohEndpointBindings.userId, input.userId),
            isNull(irohEndpointBindings.revokedAt),
            lte(irohEndpointBindings.pathHintsNextExpiry, input.now),
          ))
          .limit(IROH_RETENTION_BATCH_SIZE)
          .for("update");
        for (const binding of bindings) {
          const retained = retainedStoredHints(binding.pathHints, input.now);
          await tx
            .update(irohEndpointBindings)
            .set({
              pathHints: retained,
              pathHintsNextExpiry: nextPathHintExpiry(retained),
              updatedAt: input.now,
            })
            .where(eq(irohEndpointBindings.id, binding.id));
        }

        const challengeRetentionCutoff = new Date(input.now.getTime() - 24 * 60 * 60 * 1_000);
        const auditRetentionCutoff = new Date(input.now.getTime() - 30 * 24 * 60 * 60 * 1_000);
        await tx.execute(sql`
          with candidates as materialized (
            select id
            from iroh_registration_challenges
            where user_id = ${input.userId}
              and expires_at < ${challengeRetentionCutoff.toISOString()}::timestamptz
            order by expires_at, id
            limit ${IROH_RETENTION_BATCH_SIZE}
            for update skip locked
          )
          delete from iroh_registration_challenges as challenge
          using candidates
          where challenge.id = candidates.id
        `);
        await tx.execute(sql`
          with candidates as materialized (
            select id
            from iroh_registration_challenges
            where user_id = ${input.userId}
              and consumed_at < ${challengeRetentionCutoff.toISOString()}::timestamptz
            order by consumed_at, id
            limit ${IROH_RETENTION_BATCH_SIZE}
            for update skip locked
          )
          delete from iroh_registration_challenges as challenge
          using candidates
          where challenge.id = candidates.id
        `);
        await tx.execute(sql`
          with candidates as materialized (
            select id
            from iroh_relay_token_issuances
            where user_id = ${input.userId}
              and requested_at < ${auditRetentionCutoff.toISOString()}::timestamptz
            order by requested_at, id
            limit ${IROH_RETENTION_BATCH_SIZE}
            for update skip locked
          )
          delete from iroh_relay_token_issuances as issuance
          using candidates
          where issuance.id = candidates.id
        `);
        await tx.execute(sql`
          with candidates as materialized (
            select id
            from iroh_pair_grant_issuances
            where user_id = ${input.userId}
              and expires_at < ${auditRetentionCutoff.toISOString()}::timestamptz
            order by expires_at, id
            limit ${IROH_RETENTION_BATCH_SIZE}
            for update skip locked
          )
          delete from iroh_pair_grant_issuances as issuance
          using candidates
          where issuance.id = candidates.id
        `);
        await tx.execute(sql`
          with candidates as materialized (
            select binding.id
            from iroh_endpoint_bindings as binding
            where binding.user_id = ${input.userId}
              and binding.revoked_at < ${auditRetentionCutoff.toISOString()}::timestamptz
            and not exists (
              select 1 from iroh_pair_grant_issuances as pair_grant
              where pair_grant.initiator_binding_id = binding.id
                or pair_grant.acceptor_binding_id = binding.id
            )
            and not exists (
              select 1 from iroh_relay_token_issuances as issuance
              where issuance.binding_id = binding.id
            )
            order by binding.revoked_at, binding.id
            limit ${IROH_RETENTION_BATCH_SIZE}
            for update skip locked
          )
          delete from iroh_endpoint_bindings as binding
          using candidates
          where binding.id = candidates.id
        `);
      });
    }),

    pruneExpiredStateGlobally: (input) => repositoryEffect(
      "prune_expired_state_globally",
      () => drainIrohRetention(input),
    ),

    finalizeEndpointAttestation: (input) => repositoryEffect("finalize_endpoint_attestation", async () => {
      await cloudDb().transaction(async (tx) => {
        await assertIrohUserMutationAllowed(tx, input.userId);
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`iroh:binding:${input.userId}`}, 0))`);
        const [binding] = await tx
          .select()
          .from(irohEndpointBindings)
          .where(and(
            eq(irohEndpointBindings.id, input.bindingId),
            eq(irohEndpointBindings.userId, input.userId),
            isNull(irohEndpointBindings.revokedAt),
          ))
          .for("update")
          .limit(1);
        if (!binding) throw new IrohNotFoundError({ resource: "binding" });

        if (
          binding.deviceUuid !== input.deviceId ||
          binding.endpointId !== input.endpointId ||
          binding.identityGeneration !== input.identityGeneration ||
          binding.platform !== input.platform
        ) {
          throw new IrohConflictError({ code: "binding_changed_during_attestation" });
        }
      });
    }),

    recordPairGrant: (input) => repositoryEffect("record_pair_grant", async () => {
      await cloudDb().transaction(async (tx) => {
        await assertIrohUserMutationAllowed(tx, input.userId);
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`iroh:binding:${input.userId}`}, 0))`);
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`iroh:pair-grant:${input.userId}`}, 0))`);
        const peers = await tx
          .select()
          .from(irohEndpointBindings)
          .where(and(
            eq(irohEndpointBindings.userId, input.userId),
            inArray(irohEndpointBindings.id, [input.initiator.bindingId, input.acceptor.bindingId]),
            isNull(irohEndpointBindings.revokedAt),
          ))
          .for("update");
        const byId = new Map(peers.map((peer) => [peer.id, peer]));
        const initiator = byId.get(input.initiator.bindingId);
        const acceptor = byId.get(input.acceptor.bindingId);
        if (!initiator || !acceptor) throw new IrohNotFoundError({ resource: "binding" });
        if (
          !bindingMatchesGrantPeer(initiator, input.initiator) ||
          !bindingMatchesGrantPeer(acceptor, input.acceptor)
        ) {
          throw new IrohConflictError({ code: "binding_changed_during_grant" });
        }
        if (initiator.deviceUuid === acceptor.deviceUuid) {
          throw new IrohForbiddenError({ code: "pair_grant_same_device" });
        }
        if (initiator.platform !== "ios" || acceptor.platform !== "mac" || !acceptor.pairingEnabled) {
          throw new IrohForbiddenError({ code: "target_not_pairable" });
        }
        const hourAgo = new Date(input.issuedAt.getTime() - 60 * 60 * 1_000);
        const recent = await tx
          .select({ issuedAt: irohPairGrantIssuances.issuedAt })
          .from(irohPairGrantIssuances)
          .where(and(
            eq(irohPairGrantIssuances.userId, input.userId),
            gt(irohPairGrantIssuances.issuedAt, hourAgo),
          ))
          .orderBy(asc(irohPairGrantIssuances.issuedAt));
        if (recent.length >= 60) {
          throw quotaFromOldest(
            "pair_grant_hour_quota",
            recent[recent.length - 60]!.issuedAt,
            60 * 60,
            input.issuedAt,
          );
        }
        await tx.insert(irohPairGrantIssuances).values({
          userId: input.userId,
          jti: input.jti,
          initiatorBindingId: input.initiator.bindingId,
          acceptorBindingId: input.acceptor.bindingId,
          signingKeyId: input.signingKeyId,
          alpn: input.alpn,
          scope: input.scope,
          issuedAt: input.issuedAt,
          notBefore: input.notBefore,
          expiresAt: input.expiresAt,
        });
      });
    }),

    reserveRelayIssuance: (input) => repositoryEffect("reserve_relay_issuance", async () => {
      return await cloudDb().transaction(async (tx) => {
        await assertIrohUserMutationAllowed(tx, input.userId);
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`iroh:binding:${input.userId}`}, 0))`);
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`iroh:relay:${input.userId}`}, 0))`);
        const [binding] = await tx
          .select()
          .from(irohEndpointBindings)
          .where(and(
            eq(irohEndpointBindings.id, input.bindingId),
            eq(irohEndpointBindings.userId, input.userId),
            isNull(irohEndpointBindings.revokedAt),
          ))
          .for("update")
          .limit(1);
        if (!binding) throw new IrohNotFoundError({ resource: "binding" });

        await tx
          .update(irohEndpointBindings)
          .set({ lastSeenAt: input.now, updatedAt: input.now })
          .where(eq(irohEndpointBindings.id, binding.id));

        const reservationCutoff = new Date(
          input.now.getTime() - IROH_RELAY_RESERVATION_LEASE_MS,
        );
        await tx
          .update(irohRelayTokenIssuances)
          .set({
            status: "expired",
            completedAt: input.now,
            failureCode: "reservation_expired",
          })
          .where(and(
            eq(irohRelayTokenIssuances.userId, input.userId),
            eq(irohRelayTokenIssuances.status, "pending"),
            lte(irohRelayTokenIssuances.requestedAt, reservationCutoff),
          ));

        const dayAgo = new Date(input.now.getTime() - 24 * 60 * 60 * 1_000);
        const tenMinutesAgo = new Date(input.now.getTime() - 10 * 60 * 1_000);
        const endpointRows = await tx
          .select({ requestedAt: irohRelayTokenIssuances.requestedAt })
          .from(irohRelayTokenIssuances)
          .where(and(
            eq(irohRelayTokenIssuances.bindingId, binding.id),
            ne(irohRelayTokenIssuances.status, "expired"),
            gt(irohRelayTokenIssuances.requestedAt, dayAgo),
          ))
          .orderBy(asc(irohRelayTokenIssuances.requestedAt));
        const recentRows = endpointRows.filter((row) => row.requestedAt > tenMinutesAgo);
        if (recentRows.length >= 3) {
          throw quotaFromOldest("relay_endpoint_10m_quota", recentRows[recentRows.length - 3]!.requestedAt, 10 * 60, input.now);
        }
        if (endpointRows.length >= 12) {
          throw quotaFromOldest("relay_endpoint_day_quota", endpointRows[endpointRows.length - 12]!.requestedAt, 24 * 60 * 60, input.now);
        }
        const userRows = await tx
          .select({ requestedAt: irohRelayTokenIssuances.requestedAt })
          .from(irohRelayTokenIssuances)
          .where(and(
            eq(irohRelayTokenIssuances.userId, input.userId),
            ne(irohRelayTokenIssuances.status, "expired"),
            gt(irohRelayTokenIssuances.requestedAt, dayAgo),
          ))
          .orderBy(asc(irohRelayTokenIssuances.requestedAt));
        if (userRows.length >= 100) {
          throw quotaFromOldest("relay_user_day_quota", userRows[userRows.length - 100]!.requestedAt, 24 * 60 * 60, input.now);
        }

        const [issuance] = await tx
          .insert(irohRelayTokenIssuances)
          .values({
            userId: input.userId,
            bindingId: binding.id,
            endpointIdHash: sha256(binding.endpointId),
            status: "pending",
            requestedAt: input.now,
          })
          .returning({ id: irohRelayTokenIssuances.id });
        if (!issuance) throw new Error("relay issuance insert returned no row");
        return { issuanceId: issuance.id, binding };
      });
    }),

    completeRelayIssuance: (input) => repositoryEffect("complete_relay_issuance", async () => {
      return await cloudDb().transaction(async (tx) => {
        await assertIrohUserMutationAllowed(tx, input.userId);
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`iroh:binding:${input.userId}`}, 0))`);
        const [issuance] = await tx
          .select()
          .from(irohRelayTokenIssuances)
          .where(and(
            eq(irohRelayTokenIssuances.id, input.issuanceId),
            eq(irohRelayTokenIssuances.userId, input.userId),
            eq(irohRelayTokenIssuances.bindingId, input.bindingId),
            eq(irohRelayTokenIssuances.status, "pending"),
          ))
          .for("update")
          .limit(1);
        if (!issuance) return false;
        const [binding] = await tx
          .select({ endpointId: irohEndpointBindings.endpointId })
          .from(irohEndpointBindings)
          .where(and(
            eq(irohEndpointBindings.id, input.bindingId),
            eq(irohEndpointBindings.userId, input.userId),
            isNull(irohEndpointBindings.revokedAt),
          ))
          .for("update")
          .limit(1);
        if (
          !binding ||
          binding.endpointId !== input.endpointId ||
          issuance.endpointIdHash !== sha256(input.endpointId)
        ) {
          await tx
            .update(irohRelayTokenIssuances)
            .set({
              status: "failed",
              completedAt: input.completedAt,
              failureCode: "binding_inactive_after_mint",
            })
            .where(eq(irohRelayTokenIssuances.id, input.issuanceId));
          return false;
        }
        const completed = await tx
          .update(irohRelayTokenIssuances)
          .set({
            status: "succeeded",
            tokenHash: input.tokenHash,
            completedAt: input.completedAt,
            expiresAt: input.expiresAt,
            failureCode: null,
          })
          .where(and(
            eq(irohRelayTokenIssuances.id, input.issuanceId),
            eq(irohRelayTokenIssuances.status, "pending"),
          ))
          .returning({ id: irohRelayTokenIssuances.id });
        return completed.length === 1;
      });
    }),

    failRelayIssuance: (input) => repositoryEffect("fail_relay_issuance", async () => {
      await cloudDb().transaction(async (tx) => {
        await assertIrohUserMutationAllowed(tx, input.userId);
        await tx
          .update(irohRelayTokenIssuances)
          .set({ status: "failed", completedAt: input.completedAt, failureCode: input.failureCode.slice(0, 64) })
          .where(and(
            eq(irohRelayTokenIssuances.id, input.issuanceId),
            eq(irohRelayTokenIssuances.userId, input.userId),
            eq(irohRelayTokenIssuances.status, "pending"),
          ));
      });
    }),
  };
}

async function recycleStaleBindings(
  tx: CloudDbTransaction,
  input: {
    readonly userId: string;
    readonly deviceUuid?: string;
    readonly now: Date;
    readonly staleAfterMs: number | null;
    readonly count: number;
  },
): Promise<number> {
  if (input.staleAfterMs === null || input.count <= 0) return 0;
  const staleBefore = new Date(input.now.getTime() - input.staleAfterMs);
  const candidates = await tx
    .select({ id: irohEndpointBindings.id })
    .from(irohEndpointBindings)
    .where(and(
      eq(irohEndpointBindings.userId, input.userId),
      input.deviceUuid === undefined
        ? undefined
        : eq(irohEndpointBindings.deviceUuid, input.deviceUuid),
      isNull(irohEndpointBindings.revokedAt),
      lte(irohEndpointBindings.lastSeenAt, staleBefore),
    ))
    .orderBy(
      asc(irohEndpointBindings.lastSeenAt),
      asc(irohEndpointBindings.registeredAt),
      asc(irohEndpointBindings.id),
    )
    .limit(input.count)
    .for("update");
  if (candidates.length < input.count) return 0;
  const bindingIds = candidates.map((candidate) => candidate.id);
  const revoked = await revokeActiveBindings(tx, {
    userId: input.userId,
    bindingIds,
    now: input.now,
    reason: "stale_development_binding",
  });
  return revoked.length;
}

async function revokeActiveBindings(
  tx: CloudDbTransaction,
  input: {
    readonly userId: string;
    readonly bindingIds: readonly string[];
    readonly now: Date;
    readonly reason: "user_requested" | "stale_development_binding";
  },
): Promise<readonly string[]> {
  if (input.bindingIds.length === 0) return [];
  const revoked = await tx
    .update(irohEndpointBindings)
    .set({
      revokedAt: input.now,
      revokedReason: input.reason,
      directPortV4: null,
      directPortV6: null,
      pathHints: [],
      pathHintsNextExpiry: null,
      updatedAt: input.now,
    })
    .where(and(
      eq(irohEndpointBindings.userId, input.userId),
      inArray(irohEndpointBindings.id, [...input.bindingIds]),
      isNull(irohEndpointBindings.revokedAt),
    ))
    .returning({ id: irohEndpointBindings.id });
  if (revoked.length === 0) return [];
  const revokedIds = revoked.map((binding) => binding.id);
  await tx
    .update(irohPairGrantIssuances)
    .set({ revokedAt: input.now })
    .where(and(
      isNull(irohPairGrantIssuances.revokedAt),
      or(
        inArray(irohPairGrantIssuances.initiatorBindingId, revokedIds),
        inArray(irohPairGrantIssuances.acceptorBindingId, revokedIds),
      ),
    ));
  await tx
    .insert(irohAccountSecurityStates)
    .values({
      userId: input.userId,
      lanDiscoveryGeneration: 2,
      createdAt: input.now,
      updatedAt: input.now,
    })
    .onConflictDoUpdate({
      target: irohAccountSecurityStates.userId,
      set: {
        lanDiscoveryGeneration: sql`${irohAccountSecurityStates.lanDiscoveryGeneration} + 1`,
        updatedAt: input.now,
      },
    });
  return revokedIds;
}

type RetentionBatchOperation = {
  readonly category: IrohRetentionCategory;
  readonly run: (limit: number) => Promise<number>;
};

async function drainIrohRetention(input: {
  readonly now: Date;
  readonly maxRows?: number;
  readonly maxDurationMs?: number;
}): Promise<IrohRetentionResult> {
  const maxRows = retentionBudget(
    input.maxRows,
    IROH_RETENTION_MAX_ROWS,
    100_000,
    "maxRows",
  );
  const maxDurationMs = retentionBudget(
    input.maxDurationMs,
    IROH_RETENTION_MAX_DURATION_MS,
    30_000,
    "maxDurationMs",
  );
  const challengeRetentionCutoff = new Date(input.now.getTime() - 24 * 60 * 60 * 1_000);
  const auditRetentionCutoff = new Date(input.now.getTime() - 30 * 24 * 60 * 60 * 1_000);
  const nowIso = input.now.toISOString();
  const challengeCutoffIso = challengeRetentionCutoff.toISOString();
  const auditCutoffIso = auditRetentionCutoff.toISOString();
  const operations: readonly RetentionBatchOperation[] = [
    {
      category: "revokedHints",
      run: (limit) => runRetentionBatch(async (tx) => await tx.execute(sql`
        with candidates as materialized (
          select id
          from iroh_endpoint_bindings
          where revoked_at is not null
            and (
              path_hints_next_expiry is not null
              or direct_port_v4 is not null
              or direct_port_v6 is not null
            )
          order by revoked_at, id
          limit ${limit}
          for update skip locked
        ), changed as (
          update iroh_endpoint_bindings as binding
          set path_hints = '[]'::jsonb,
              path_hints_next_expiry = null,
              direct_port_v4 = null,
              direct_port_v6 = null,
              updated_at = ${nowIso}::timestamptz
          from candidates
          where binding.id = candidates.id
          returning binding.id
        )
        select count(*)::int as affected from changed
      `)),
    },
    {
      category: "expiredHints",
      run: (limit) => runRetentionBatch(async (tx) => await tx.execute(sql`
        with candidates as materialized (
          select id
          from iroh_endpoint_bindings
          where revoked_at is null
            and path_hints_next_expiry <= ${nowIso}::timestamptz
          order by path_hints_next_expiry, id
          limit ${limit}
          for update skip locked
        ), retained as (
          select
            binding.id,
            coalesce(
              jsonb_agg(entry.hint order by entry.ordinality) filter (
                where case
                  when jsonb_typeof(entry.hint) = 'object'
                    and jsonb_typeof(entry.hint -> 'expires_at') = 'string'
                    and (entry.hint ->> 'expires_at') ~ '^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}Z$'
                  then (entry.hint ->> 'expires_at')::timestamptz > ${nowIso}::timestamptz
                  else false
                end
              ),
              '[]'::jsonb
            ) as path_hints
          from candidates
          join iroh_endpoint_bindings as binding on binding.id = candidates.id
          left join lateral jsonb_array_elements(binding.path_hints)
            with ordinality as entry(hint, ordinality) on true
          group by binding.id
        ), normalized as (
          select
            retained.id,
            retained.path_hints,
            (
              select min((hint ->> 'expires_at')::timestamptz)
              from jsonb_array_elements(retained.path_hints) as hints(hint)
            ) as next_expiry
          from retained
        ), changed as (
          update iroh_endpoint_bindings as binding
          set path_hints = normalized.path_hints,
              path_hints_next_expiry = normalized.next_expiry,
              updated_at = ${nowIso}::timestamptz
          from normalized
          where binding.id = normalized.id
          returning binding.id
        )
        select count(*)::int as affected from changed
      `)),
    },
    {
      category: "expiredChallenges",
      run: (limit) => runRetentionBatch(async (tx) => await tx.execute(sql`
        with candidates as materialized (
          select id
          from iroh_registration_challenges
          where expires_at < ${challengeCutoffIso}::timestamptz
          order by expires_at, id
          limit ${limit}
          for update skip locked
        ), changed as (
          delete from iroh_registration_challenges as challenge
          using candidates
          where challenge.id = candidates.id
          returning challenge.id
        )
        select count(*)::int as affected from changed
      `)),
    },
    {
      category: "consumedChallenges",
      run: (limit) => runRetentionBatch(async (tx) => await tx.execute(sql`
        with candidates as materialized (
          select id
          from iroh_registration_challenges
          where consumed_at < ${challengeCutoffIso}::timestamptz
          order by consumed_at, id
          limit ${limit}
          for update skip locked
        ), changed as (
          delete from iroh_registration_challenges as challenge
          using candidates
          where challenge.id = candidates.id
          returning challenge.id
        )
        select count(*)::int as affected from changed
      `)),
    },
    {
      category: "relayAudits",
      run: (limit) => runRetentionBatch(async (tx) => await tx.execute(sql`
        with candidates as materialized (
          select id
          from iroh_relay_token_issuances
          where requested_at < ${auditCutoffIso}::timestamptz
          order by requested_at, id
          limit ${limit}
          for update skip locked
        ), changed as (
          delete from iroh_relay_token_issuances as issuance
          using candidates
          where issuance.id = candidates.id
          returning issuance.id
        )
        select count(*)::int as affected from changed
      `)),
    },
    {
      category: "pairGrantAudits",
      run: (limit) => runRetentionBatch(async (tx) => await tx.execute(sql`
        with candidates as materialized (
          select id
          from iroh_pair_grant_issuances
          where expires_at < ${auditCutoffIso}::timestamptz
          order by expires_at, id
          limit ${limit}
          for update skip locked
        ), changed as (
          delete from iroh_pair_grant_issuances as issuance
          using candidates
          where issuance.id = candidates.id
          returning issuance.id
        )
        select count(*)::int as affected from changed
      `)),
    },
    {
      category: "revokedBindings",
      run: (limit) => runRetentionBatch(async (tx) => await tx.execute(sql`
        with candidates as materialized (
          select binding.id
          from iroh_endpoint_bindings as binding
          where binding.revoked_at < ${auditCutoffIso}::timestamptz
            and not exists (
              select 1 from iroh_pair_grant_issuances as pair_grant
              where pair_grant.initiator_binding_id = binding.id
                or pair_grant.acceptor_binding_id = binding.id
            )
            and not exists (
              select 1 from iroh_relay_token_issuances as issuance
              where issuance.binding_id = binding.id
            )
          order by binding.revoked_at, binding.id
          limit ${limit}
          for update skip locked
        ), changed as (
          delete from iroh_endpoint_bindings as binding
          using candidates
          where binding.id = candidates.id
          returning binding.id
        )
        select count(*)::int as affected from changed
      `)),
    },
  ];
  const byCategory: Record<IrohRetentionCategory, number> = {
    revokedHints: 0,
    expiredHints: 0,
    expiredChallenges: 0,
    consumedChallenges: 0,
    relayAudits: 0,
    pairGrantAudits: 0,
    revokedBindings: 0,
  };
  const deadline = Date.now() + maxDurationMs;
  const activeOperations = [...operations];
  let rowsProcessed = 0;
  let batches = 0;
  let operationIndex = 0;

  while (activeOperations.length > 0 && rowsProcessed < maxRows && Date.now() < deadline) {
    const operation = activeOperations[operationIndex]!;
    const limit = Math.min(IROH_RETENTION_BATCH_SIZE, maxRows - rowsProcessed);
    const affected = await operation.run(limit);
    batches += 1;
    rowsProcessed += affected;
    byCategory[operation.category] += affected;
    if (affected < limit) {
      activeOperations.splice(operationIndex, 1);
      if (operationIndex >= activeOperations.length) operationIndex = 0;
    } else {
      operationIndex = (operationIndex + 1) % activeOperations.length;
    }
  }

  const budgetExhausted = rowsProcessed >= maxRows
    ? "rows"
    : Date.now() >= deadline
      ? "time"
      : null;
  const backlog = budgetExhausted === "time"
    ? true
    : await irohRetentionBacklogExists(input.now, challengeRetentionCutoff, auditRetentionCutoff);
  return { rowsProcessed, batches, backlog, budgetExhausted, byCategory };
}

async function runRetentionBatch(
  execute: (tx: CloudDbTransaction) => Promise<unknown>,
): Promise<number> {
  return await cloudDb().transaction(async (tx) => {
    const result = await execute(tx);
    const [row] = databaseRows(result);
    const affected = Number(row?.affected ?? 0);
    if (!Number.isSafeInteger(affected) || affected < 0 || affected > IROH_RETENTION_BATCH_SIZE) {
      throw new Error("invalid Iroh retention batch result");
    }
    return affected;
  });
}

async function irohRetentionBacklogExists(
  now: Date,
  challengeRetentionCutoff: Date,
  auditRetentionCutoff: Date,
): Promise<boolean> {
  const result = await cloudDb().execute(sql`
    select (
      exists (
        select 1 from iroh_endpoint_bindings
        where revoked_at is not null and path_hints_next_expiry is not null
      ) or exists (
        select 1 from iroh_endpoint_bindings
        where revoked_at is null and path_hints_next_expiry <= ${now.toISOString()}::timestamptz
      ) or exists (
        select 1 from iroh_registration_challenges
        where expires_at < ${challengeRetentionCutoff.toISOString()}::timestamptz
      ) or exists (
        select 1 from iroh_registration_challenges
        where consumed_at < ${challengeRetentionCutoff.toISOString()}::timestamptz
      ) or exists (
        select 1 from iroh_relay_token_issuances
        where requested_at < ${auditRetentionCutoff.toISOString()}::timestamptz
      ) or exists (
        select 1 from iroh_pair_grant_issuances
        where expires_at < ${auditRetentionCutoff.toISOString()}::timestamptz
      ) or exists (
        select 1
        from iroh_endpoint_bindings as binding
        where binding.revoked_at < ${auditRetentionCutoff.toISOString()}::timestamptz
          and not exists (
            select 1 from iroh_pair_grant_issuances as pair_grant
            where pair_grant.initiator_binding_id = binding.id
              or pair_grant.acceptor_binding_id = binding.id
          )
          and not exists (
            select 1 from iroh_relay_token_issuances as issuance
            where issuance.binding_id = binding.id
          )
      )
    ) as backlog
  `);
  const [row] = databaseRows(result);
  return row?.backlog === true;
}

function databaseRows(result: unknown): readonly Record<string, unknown>[] {
  if (Array.isArray(result)) return result as readonly Record<string, unknown>[];
  const rows = (result as { readonly rows?: unknown } | null)?.rows;
  return Array.isArray(rows) ? rows as readonly Record<string, unknown>[] : [];
}

function retentionBudget(
  value: number | undefined,
  fallback: number,
  maximum: number,
  name: string,
): number {
  const resolved = value ?? fallback;
  if (!Number.isSafeInteger(resolved) || resolved < 1 || resolved > maximum) {
    throw new Error(`invalid Iroh retention ${name}`);
  }
  return resolved;
}

function repositoryEffect<A>(
  operation: string,
  run: () => Promise<A>,
): Effect.Effect<A, RepositoryError> {
  return Effect.tryPromise({
    try: run,
    catch: (cause) => {
      if (isDomainError(cause)) return cause;
      const conflict = databaseConflict(cause);
      return conflict ?? new IrohDatabaseError({ operation, cause: sanitizedDatabaseCause(cause) });
    },
  });
}

function isDomainError(error: unknown): error is
  | IrohForbiddenError
  | IrohNotFoundError
  | IrohConflictError
  | IrohQuotaExceededError {
  const tag = (error as { _tag?: unknown } | null)?._tag;
  return tag === "IrohForbiddenError" || tag === "IrohNotFoundError" ||
    tag === "IrohConflictError" || tag === "IrohQuotaExceededError";
}

function quotaFromOldest(
  code: string,
  oldest: Date,
  windowSeconds: number,
  now: Date,
): IrohQuotaExceededError {
  const retryAfterSeconds = Math.max(
    1,
    Math.ceil((oldest.getTime() + windowSeconds * 1_000 - now.getTime()) / 1_000),
  );
  return new IrohQuotaExceededError({ code, retryAfterSeconds });
}

function sanitizedDatabaseCause(cause: unknown): unknown {
  const candidate = databaseCause(cause);
  return {
    code: typeof candidate?.code === "string" ? candidate.code : undefined,
    name: typeof candidate?.name === "string" ? candidate.name : undefined,
  };
}

function databaseConflict(cause: unknown): IrohConflictError | null {
  const candidate = databaseCause(cause);
  if (candidate?.code !== "23505") return null;
  if (candidate.constraint === "iroh_endpoint_bindings_active_endpoint_unique") {
    return new IrohConflictError({ code: "endpoint_already_bound" });
  }
  if (candidate.constraint === "iroh_endpoint_bindings_active_app_instance_unique") {
    return new IrohConflictError({ code: "binding_replacement_requires_revocation" });
  }
  return null;
}

function databaseCause(cause: unknown): {
  readonly code?: unknown;
  readonly name?: unknown;
  readonly constraint?: unknown;
} | null {
  let current = cause;
  const seen = new Set<unknown>();
  for (let depth = 0; depth < 5; depth += 1) {
    if (!current || typeof current !== "object" || seen.has(current)) return null;
    seen.add(current);
    const candidate = current as { code?: unknown; name?: unknown; constraint?: unknown; cause?: unknown };
    if (typeof candidate.code === "string") return candidate;
    current = candidate.cause;
  }
  return null;
}

async function assertIrohUserMutationAllowed(
  tx: CloudDbTransaction,
  userId: string,
): Promise<void> {
  try {
    await assertAccountDeletionUserMutationAllowed(tx, userId);
  } catch (error) {
    if (error instanceof AccountDeletionMutationBlockedError) {
      throw new IrohConflictError({ code: "account_deletion_in_progress" });
    }
    throw error;
  }
}

function retainedStoredHints(pathHints: readonly unknown[], now: Date): IrohPathHint[] {
  return pathHints.flatMap((hint): IrohPathHint[] => {
    try {
      return [parseIrohPathHint(hint, now)];
    } catch {
      return [];
    }
  });
}

function bindingMatchesGrantPeer(binding: IrohBindingRecord, peer: PairGrantPeer): boolean {
  return binding.id === peer.bindingId &&
    binding.deviceUuid === peer.deviceId &&
    binding.tag === peer.tag &&
    binding.platform === peer.platform &&
    binding.endpointId === peer.endpointId &&
    binding.identityGeneration === peer.identityGeneration;
}
