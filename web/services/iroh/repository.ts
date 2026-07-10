import { and, asc, count, eq, gt, inArray, isNotNull, isNull, lt, or, sql } from "drizzle-orm";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { cloudDb } from "../../db/client";
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
import { parseIrohPathHint, sha256, type IrohRegistrationPayload } from "./model";

export type IrohBindingRecord = typeof irohEndpointBindings.$inferSelect;
export type IrohChallengeRecord = typeof irohRegistrationChallenges.$inferSelect;

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
    readonly deviceLimitOverrideAllowed: boolean;
  }) => Effect.Effect<IrohBindingRecord, RepositoryError>;
  readonly listActiveBindings: (
    userId: string,
  ) => Effect.Effect<IrohBindingRecord[], RepositoryError>;
  readonly findActiveBindings: (
    userId: string,
    bindingIds: readonly string[],
  ) => Effect.Effect<IrohBindingRecord[], RepositoryError>;
  readonly revokeBinding: (input: {
    readonly userId: string;
    readonly bindingId: string;
    readonly now: Date;
  }) => Effect.Effect<boolean, RepositoryError>;
  readonly accountLanGeneration: (input: {
    readonly userId: string;
    readonly now: Date;
  }) => Effect.Effect<number, RepositoryError>;
  readonly pruneExpiredState: (input: {
    readonly userId: string;
    readonly now: Date;
  }) => Effect.Effect<void, RepositoryError>;
  readonly pruneExpiredStateGlobally: (input: {
    readonly now: Date;
  }) => Effect.Effect<void, RepositoryError>;
  readonly recordPairGrant: (input: {
    readonly userId: string;
    readonly jti: string;
    readonly initiatorBindingId: string;
    readonly acceptorBindingId: string;
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
    readonly issuanceId: string;
    readonly tokenHash: string;
    readonly completedAt: Date;
    readonly expiresAt: Date;
  }) => Effect.Effect<void, RepositoryError>;
  readonly failRelayIssuance: (input: {
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
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`iroh:challenge:${input.userId}`}, 0))`);
        const tenMinutesAgo = new Date(input.now.getTime() - 10 * 60 * 1_000);
        const [recentForDevice] = await tx
          .select({ total: count() })
          .from(irohRegistrationChallenges)
          .where(and(
            eq(irohRegistrationChallenges.userId, input.userId),
            eq(irohRegistrationChallenges.deviceUuid, input.deviceUuid),
            gt(irohRegistrationChallenges.createdAt, tenMinutesAgo),
          ));
        if ((recentForDevice?.total ?? 0) >= 6) {
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
        if ((outstanding?.total ?? 0) >= 32) {
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
            existingApp.tag !== input.payload.tag
          ) {
            throw new IrohConflictError({ code: "binding_replacement_requires_revocation" });
          }
          const [updated] = await tx
            .update(irohEndpointBindings)
            .set({
              platform: input.payload.platform,
              displayName: input.payload.displayName ?? null,
              pairingEnabled: input.payload.pairingEnabled,
              capabilities: [...input.payload.capabilities],
              pathHints: [...input.payload.pathHints],
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
          return updated;
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

        const [userTotal] = await tx
          .select({ total: count() })
          .from(irohEndpointBindings)
          .where(and(
            eq(irohEndpointBindings.userId, input.userId),
            isNull(irohEndpointBindings.revokedAt),
          ));
        if ((userTotal?.total ?? 0) >= 32) {
          throw new IrohQuotaExceededError({ code: "too_many_bindings", retryAfterSeconds: 86_400 });
        }
        const [deviceTotal] = await tx
          .select({ total: count() })
          .from(irohEndpointBindings)
          .where(and(
            eq(irohEndpointBindings.userId, input.userId),
            eq(irohEndpointBindings.deviceUuid, input.payload.deviceId),
            isNull(irohEndpointBindings.revokedAt),
          ));
        const usesDeviceOverride = (deviceTotal?.total ?? 0) >= 8;
        if (usesDeviceOverride && !input.deviceLimitOverrideAllowed) {
          throw new IrohQuotaExceededError({ code: "too_many_device_bindings", retryAfterSeconds: 86_400 });
        }

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
            pathHints: [...input.payload.pathHints],
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
        return binding;
      });
    }),

    listActiveBindings: (userId) => repositoryEffect("list_bindings", async () => {
      return await cloudDb()
        .select()
        .from(irohEndpointBindings)
        .where(and(
          eq(irohEndpointBindings.userId, userId),
          isNull(irohEndpointBindings.revokedAt),
        ))
        .orderBy(asc(irohEndpointBindings.registeredAt));
    }),

    findActiveBindings: (userId, bindingIds) => repositoryEffect("find_bindings", async () => {
      if (bindingIds.length === 0) return [];
      return await cloudDb()
        .select()
        .from(irohEndpointBindings)
        .where(and(
          eq(irohEndpointBindings.userId, userId),
          inArray(irohEndpointBindings.id, [...bindingIds]),
          isNull(irohEndpointBindings.revokedAt),
        ));
    }),

    revokeBinding: (input) => repositoryEffect("revoke_binding", async () => {
      return await cloudDb().transaction(async (tx) => {
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`iroh:binding:${input.userId}`}, 0))`);
        const revoked = await tx
          .update(irohEndpointBindings)
          .set({
            revokedAt: input.now,
            revokedReason: "user_requested",
            pathHints: [],
            updatedAt: input.now,
          })
          .where(and(
            eq(irohEndpointBindings.id, input.bindingId),
            eq(irohEndpointBindings.userId, input.userId),
            isNull(irohEndpointBindings.revokedAt),
          ))
          .returning({ id: irohEndpointBindings.id });
        if (revoked.length === 0) return false;
        await tx
          .update(irohPairGrantIssuances)
          .set({ revokedAt: input.now })
          .where(and(
            isNull(irohPairGrantIssuances.revokedAt),
            or(
              eq(irohPairGrantIssuances.initiatorBindingId, input.bindingId),
              eq(irohPairGrantIssuances.acceptorBindingId, input.bindingId),
            ),
          ));
        await tx
          .insert(irohAccountSecurityStates)
          .values({ userId: input.userId, lanDiscoveryGeneration: 2, createdAt: input.now, updatedAt: input.now })
          .onConflictDoUpdate({
            target: irohAccountSecurityStates.userId,
            set: {
              lanDiscoveryGeneration: sql`${irohAccountSecurityStates.lanDiscoveryGeneration} + 1`,
              updatedAt: input.now,
            },
          });
        return true;
      });
    }),

    accountLanGeneration: (input) => repositoryEffect("lan_generation", async () => {
      const [state] = await cloudDb()
        .insert(irohAccountSecurityStates)
        .values({ userId: input.userId, lanDiscoveryGeneration: 1, createdAt: input.now, updatedAt: input.now })
        .onConflictDoUpdate({
          target: irohAccountSecurityStates.userId,
          set: { updatedAt: sql`${irohAccountSecurityStates.updatedAt}` },
        })
        .returning({ generation: irohAccountSecurityStates.lanDiscoveryGeneration });
      if (!state) throw new Error("account security state returned no row");
      return state.generation;
    }),

    pruneExpiredState: (input) => repositoryEffect("prune_expired_state", async () => {
      await cloudDb().transaction(async (tx) => {
        const bindings = await tx
          .select({
            id: irohEndpointBindings.id,
            pathHints: irohEndpointBindings.pathHints,
            revokedAt: irohEndpointBindings.revokedAt,
          })
          .from(irohEndpointBindings)
          .where(eq(irohEndpointBindings.userId, input.userId));
        for (const binding of bindings) {
          const retained = binding.revokedAt
            ? []
            : binding.pathHints.filter((hint) => isUnexpiredStoredHint(hint, input.now));
          if (retained.length !== binding.pathHints.length) {
            await tx
              .update(irohEndpointBindings)
              .set({ pathHints: retained, updatedAt: input.now })
              .where(eq(irohEndpointBindings.id, binding.id));
          }
        }

        const challengeRetentionCutoff = new Date(input.now.getTime() - 24 * 60 * 60 * 1_000);
        await tx
          .delete(irohRegistrationChallenges)
          .where(and(
            eq(irohRegistrationChallenges.userId, input.userId),
            or(
              lt(irohRegistrationChallenges.expiresAt, challengeRetentionCutoff),
              and(
                isNotNull(irohRegistrationChallenges.consumedAt),
                lt(irohRegistrationChallenges.consumedAt, challengeRetentionCutoff),
              ),
            ),
          ));

        const auditRetentionCutoff = new Date(input.now.getTime() - 30 * 24 * 60 * 60 * 1_000);
        await tx
          .delete(irohRelayTokenIssuances)
          .where(and(
            eq(irohRelayTokenIssuances.userId, input.userId),
            lt(irohRelayTokenIssuances.requestedAt, auditRetentionCutoff),
          ));
        await tx
          .delete(irohPairGrantIssuances)
          .where(and(
            eq(irohPairGrantIssuances.userId, input.userId),
            lt(irohPairGrantIssuances.expiresAt, auditRetentionCutoff),
          ));
        await tx.execute(sql`
          delete from iroh_endpoint_bindings as binding
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
        `);
      });
    }),

    pruneExpiredStateGlobally: (input) => repositoryEffect("prune_expired_state_globally", async () => {
      const challengeRetentionCutoff = new Date(input.now.getTime() - 24 * 60 * 60 * 1_000);
      const auditRetentionCutoff = new Date(input.now.getTime() - 30 * 24 * 60 * 60 * 1_000);
      await cloudDb().transaction(async (tx) => {
        await tx.execute(sql`
          update iroh_endpoint_bindings as binding
          set
            path_hints = coalesce((
              select jsonb_agg(hint)
              from jsonb_array_elements(binding.path_hints) as hints(hint)
              where binding.revoked_at is null
                and case
                  when jsonb_typeof(hint) = 'object'
                    and jsonb_typeof(hint -> 'expires_at') = 'string'
                    and (hint ->> 'expires_at') ~ '^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}Z$'
                  then (hint ->> 'expires_at') > ${input.now.toISOString()}
                  else false
                end
            ), '[]'::jsonb),
            updated_at = ${input.now.toISOString()}::timestamptz
          where binding.path_hints <> '[]'::jsonb
            and (
              binding.revoked_at is not null
              or exists (
                select 1
                from jsonb_array_elements(binding.path_hints) as candidates(candidate)
                where case
                  when jsonb_typeof(candidate) = 'object'
                    and jsonb_typeof(candidate -> 'expires_at') = 'string'
                    and (candidate ->> 'expires_at') ~ '^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}Z$'
                  then (candidate ->> 'expires_at') <= ${input.now.toISOString()}
                  else true
                end
              )
            )
        `);
        await tx
          .delete(irohRegistrationChallenges)
          .where(or(
            lt(irohRegistrationChallenges.expiresAt, challengeRetentionCutoff),
            and(
              isNotNull(irohRegistrationChallenges.consumedAt),
              lt(irohRegistrationChallenges.consumedAt, challengeRetentionCutoff),
            ),
          ));
        await tx
          .delete(irohRelayTokenIssuances)
          .where(lt(irohRelayTokenIssuances.requestedAt, auditRetentionCutoff));
        await tx
          .delete(irohPairGrantIssuances)
          .where(lt(irohPairGrantIssuances.expiresAt, auditRetentionCutoff));
        await tx.execute(sql`
          delete from iroh_endpoint_bindings as binding
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
        `);
      });
    }),

    recordPairGrant: (input) => repositoryEffect("record_pair_grant", async () => {
      await cloudDb().transaction(async (tx) => {
        await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`iroh:pair-grant:${input.userId}`}, 0))`);
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
        await tx.insert(irohPairGrantIssuances).values(input);
      });
    }),

    reserveRelayIssuance: (input) => repositoryEffect("reserve_relay_issuance", async () => {
      return await cloudDb().transaction(async (tx) => {
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

        const dayAgo = new Date(input.now.getTime() - 24 * 60 * 60 * 1_000);
        const tenMinutesAgo = new Date(input.now.getTime() - 10 * 60 * 1_000);
        const endpointRows = await tx
          .select({ requestedAt: irohRelayTokenIssuances.requestedAt })
          .from(irohRelayTokenIssuances)
          .where(and(
            eq(irohRelayTokenIssuances.bindingId, binding.id),
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
      await cloudDb()
        .update(irohRelayTokenIssuances)
        .set({
          status: "succeeded",
          tokenHash: input.tokenHash,
          completedAt: input.completedAt,
          expiresAt: input.expiresAt,
          failureCode: null,
        })
        .where(eq(irohRelayTokenIssuances.id, input.issuanceId));
    }),

    failRelayIssuance: (input) => repositoryEffect("fail_relay_issuance", async () => {
      await cloudDb()
        .update(irohRelayTokenIssuances)
        .set({ status: "failed", completedAt: input.completedAt, failureCode: input.failureCode.slice(0, 64) })
        .where(eq(irohRelayTokenIssuances.id, input.issuanceId));
    }),
  };
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

function isUnexpiredStoredHint(hint: unknown, now: Date): boolean {
  try {
    parseIrohPathHint(hint, now);
    return true;
  } catch {
    return false;
  }
}
