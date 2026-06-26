import { and, count, desc, eq, inArray, isNotNull, isNull, ne, or, sql } from "drizzle-orm";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { cloudDb } from "../../db/client";
import { cloudVmBillingGrants, cloudVmLeases, cloudVmSessions, cloudVms, cloudVmUsageEvents } from "../../db/schema";
import type { ProviderId } from "./drivers";
import { VmDatabaseError, VmLimitExceededError, isVmLimitExceededError } from "./errors";

export type CloudVmRow = typeof cloudVms.$inferSelect;
export type CloudVmLeaseRow = typeof cloudVmLeases.$inferSelect;
export type CloudVmSessionRow = typeof cloudVmSessions.$inferSelect;
export type CloudVmLeaseKind = typeof cloudVmLeases.$inferInsert.kind;
export type CloudVmStatus = CloudVmRow["status"];
export type CloudVmSessionStatus = CloudVmSessionRow["status"];

export type BeginCreateResult =
  | { readonly inserted: true; readonly vm: CloudVmRow }
  | { readonly inserted: false; readonly vm: CloudVmRow };

export type BillingGrantClaim =
  | { readonly kind: "inserted"; readonly grantId: string }
  | { readonly kind: "already_claimed" };

export type VmRepositoryShape = {
  readonly listUserVms: (userId: string, billingTeamId?: string | null) => Effect.Effect<CloudVmRow[], VmDatabaseError>;
  readonly claimBillingGrant: (input: {
    readonly billingCustomerType: string;
    readonly billingCustomerId: string;
    readonly billingPlanId: string;
    readonly itemId: string;
    readonly amount: number;
    readonly reason: string;
  }) => Effect.Effect<BillingGrantClaim, VmDatabaseError>;
  readonly markBillingGrantApplied: (id: string) => Effect.Effect<void, VmDatabaseError>;
  readonly deleteBillingGrant: (id: string) => Effect.Effect<void, VmDatabaseError>;
  readonly beginCreate: (input: {
    readonly userId: string;
    readonly billingTeamId: string;
    readonly billingPlanId: string;
    readonly provider: ProviderId;
    readonly image: string;
    readonly imageVersion?: string | null;
    readonly maxActiveVms: number;
    readonly idempotencyKey?: string;
  }) => Effect.Effect<BeginCreateResult, VmDatabaseError | VmLimitExceededError>;
  readonly activeLimitCandidates: (input: {
    readonly userId: string;
    readonly billingTeamId: string;
  }) => Effect.Effect<CloudVmRow[], VmDatabaseError>;
  readonly reservePausedResume: (input: {
    readonly id: string;
    readonly userId: string;
    readonly billingTeamId?: string | null;
    readonly providerVmId: string;
    readonly maxActiveVms: number;
  }) => Effect.Effect<CloudVmRow | null, VmDatabaseError | VmLimitExceededError>;
  readonly markProviderObservedStatus: (input: {
    readonly id: string;
    readonly providerVmId: string;
    readonly status: CloudVmStatus;
  }) => Effect.Effect<boolean, VmDatabaseError>;
  readonly markCreateRunning: (input: {
    readonly id: string;
    readonly providerVmId: string;
    readonly image: string;
    readonly imageVersion?: string | null;
    readonly providerMetadata?: Record<string, unknown>;
  }) => Effect.Effect<CloudVmRow, VmDatabaseError>;
  readonly markCreateFailed: (input: {
    readonly id: string;
    readonly code: string;
    readonly message: string;
  }) => Effect.Effect<void, VmDatabaseError>;
  readonly hasOwnedSnapshot: (input: {
    readonly userId: string;
    readonly billingTeamId?: string | null;
    readonly provider: ProviderId;
    readonly snapshotId: string;
  }) => Effect.Effect<boolean, VmDatabaseError>;
  readonly findUserVm: (input: {
    readonly userId: string;
    readonly billingTeamId?: string | null;
    readonly providerVmId: string;
  }) => Effect.Effect<CloudVmRow | null, VmDatabaseError>;
  readonly markDestroyed: (id: string) => Effect.Effect<void, VmDatabaseError>;
  readonly recordLease: (input: {
    readonly vmId: string;
    readonly userId: string;
    readonly kind: CloudVmLeaseKind;
    readonly tokenHash: string;
    readonly expiresAt: Date;
    readonly providerIdentityHandle?: string;
    readonly sessionId?: string;
    readonly transport?: string;
    readonly metadata?: Record<string, unknown>;
  }) => Effect.Effect<void, VmDatabaseError>;
  readonly listVmSessions: (input: {
    readonly userId: string;
    readonly vmId: string;
  }) => Effect.Effect<CloudVmSessionRow[], VmDatabaseError>;
  readonly upsertVmSession: (input: {
    readonly vmId: string;
    readonly userId: string;
    readonly providerSessionId: string;
    readonly title?: string | null;
    readonly status?: CloudVmSessionStatus;
    readonly attachmentCount?: number;
    readonly effectiveCols?: number | null;
    readonly effectiveRows?: number | null;
    readonly lastKnownCols?: number | null;
    readonly lastKnownRows?: number | null;
    readonly scrollbackBytes?: number;
    readonly metadata?: Record<string, unknown>;
  }) => Effect.Effect<CloudVmSessionRow, VmDatabaseError>;
  readonly activeIdentityLeases: (vmId: string) => Effect.Effect<CloudVmLeaseRow[], VmDatabaseError>;
  readonly markLeasesRevoked: (ids: readonly string[]) => Effect.Effect<void, VmDatabaseError>;
  readonly recordUsageEvent: (input: {
    readonly userId: string;
    readonly billingTeamId?: string | null;
    readonly billingPlanId?: string | null;
    readonly vmId?: string | null;
    readonly eventType: string;
    readonly provider?: ProviderId;
    readonly imageId?: string;
    readonly metadata?: Record<string, unknown>;
  }) => Effect.Effect<void, VmDatabaseError>;
  readonly recordUsageEvents: (inputs: readonly {
    readonly userId: string;
    readonly billingTeamId?: string | null;
    readonly billingPlanId?: string | null;
    readonly vmId?: string | null;
    readonly eventType: string;
    readonly provider?: ProviderId;
    readonly imageId?: string;
    readonly metadata?: Record<string, unknown>;
  }[]) => Effect.Effect<void, VmDatabaseError>;
};

export class VmRepository extends Context.Tag("cmux/VmRepository")<
  VmRepository,
  VmRepositoryShape
>() {}

function dbEffect<A>(
  operation: string,
  run: () => Promise<A>,
): Effect.Effect<A, VmDatabaseError> {
  return Effect.tryPromise({
    try: run,
    catch: (cause) => new VmDatabaseError({ operation, cause }),
  });
}

function pgErrorCode(cause: unknown): string | null {
  if (!cause || typeof cause !== "object") return null;
  const code = (cause as { code?: unknown }).code;
  if (typeof code === "string") return code;
  return pgErrorCode((cause as { cause?: unknown }).cause);
}

async function findByIdempotencyKey(
  billingTeamId: string,
  idempotencyKey: string,
): Promise<CloudVmRow | null> {
  const db = cloudDb();
  const [existing] = await db
    .select()
    .from(cloudVms)
    .where(idempotencyScopeWhere({ billingTeamId, idempotencyKey }))
    .limit(1);
  return existing ?? null;
}

function idempotencyScopeWhere(input: {
  readonly billingTeamId: string;
  readonly idempotencyKey: string;
}) {
  return and(
    eq(cloudVms.idempotencyKey, input.idempotencyKey),
    eq(cloudVms.billingTeamId, input.billingTeamId),
  );
}

function accountScopeWhere(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
}) {
  const billingTeamId = input.billingTeamId?.trim();
  if (!billingTeamId) {
    return and(isNull(cloudVms.billingTeamId), eq(cloudVms.userId, input.userId));
  }
  return eq(cloudVms.billingTeamId, billingTeamId);
}

export const VmRepositoryLive = Layer.succeed(VmRepository, {
  listUserVms: (userId, billingTeamId) =>
    dbEffect("listUserVms", async () => {
      const db = cloudDb();
      const teamId = billingTeamId?.trim();
      return await db
        .select()
        .from(cloudVms)
        .where(and(
          accountScopeWhere({ userId, billingTeamId: teamId }),
          ne(cloudVms.status, "destroyed"),
        ))
        .orderBy(desc(cloudVms.createdAt));
    }),

  claimBillingGrant: (input) =>
    dbEffect("claimBillingGrant", async () => {
      const db = cloudDb();
      const [inserted] = await db
        .insert(cloudVmBillingGrants)
        .values({
          billingCustomerType: input.billingCustomerType,
          billingCustomerId: input.billingCustomerId,
          billingPlanId: input.billingPlanId,
          itemId: input.itemId,
          amount: input.amount,
          reason: input.reason,
        })
        .onConflictDoNothing({
          target: [
            cloudVmBillingGrants.billingCustomerType,
            cloudVmBillingGrants.billingCustomerId,
            cloudVmBillingGrants.itemId,
            cloudVmBillingGrants.reason,
          ],
        })
        .returning({ id: cloudVmBillingGrants.id });
      if (inserted) {
        return { kind: "inserted" as const, grantId: inserted.id };
      }

      const [existing] = await db
        .select({ id: cloudVmBillingGrants.id })
        .from(cloudVmBillingGrants)
        .where(
          and(
            eq(cloudVmBillingGrants.billingCustomerType, input.billingCustomerType),
            eq(cloudVmBillingGrants.billingCustomerId, input.billingCustomerId),
            eq(cloudVmBillingGrants.itemId, input.itemId),
            eq(cloudVmBillingGrants.reason, input.reason),
          ),
        )
        .limit(1);
      if (!existing) throw new Error("billing grant conflict row missing after insert");
      return { kind: "already_claimed" as const };
    }),

  markBillingGrantApplied: (id) =>
    dbEffect("markBillingGrantApplied", async () => {
      const db = cloudDb();
      await db
        .update(cloudVmBillingGrants)
        .set({ appliedAt: new Date(), updatedAt: new Date() })
        .where(eq(cloudVmBillingGrants.id, id));
    }),

  deleteBillingGrant: (id) =>
    dbEffect("deleteBillingGrant", async () => {
      const db = cloudDb();
      await db
        .delete(cloudVmBillingGrants)
        .where(and(eq(cloudVmBillingGrants.id, id), isNull(cloudVmBillingGrants.appliedAt)));
    }),

  beginCreate: (input) =>
    Effect.tryPromise({
      try: async () => {
        const idempotencyKey = input.idempotencyKey?.trim() || undefined;
        const db = cloudDb();
        try {
          return await db.transaction(async (tx) => {
            if (idempotencyKey) {
              const [existing] = await tx
                .select()
                .from(cloudVms)
                .where(idempotencyScopeWhere({ billingTeamId: input.billingTeamId, idempotencyKey }))
                .limit(1);
              if (existing) {
                if (existing.status !== "failed" && existing.status !== "destroyed") {
                  return { inserted: false as const, vm: existing };
                }
              }
            }

            await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${input.billingTeamId}, 0))`);
            if (idempotencyKey) {
              const [existing] = await tx
                .select()
                .from(cloudVms)
                .where(idempotencyScopeWhere({ billingTeamId: input.billingTeamId, idempotencyKey }))
                .limit(1);
              if (existing) {
                if (existing.status !== "failed" && existing.status !== "destroyed") {
                  return { inserted: false as const, vm: existing };
                }
                await tx
                  .update(cloudVms)
                  .set({ idempotencyKey: null, updatedAt: new Date() })
                  .where(eq(cloudVms.id, existing.id));
              }
            }

            const [active] = await tx
              .select({ total: count() })
              .from(cloudVms)
              .where(
                and(
                  inArray(cloudVms.status, ["provisioning", "running"]),
                  eq(cloudVms.billingTeamId, input.billingTeamId),
                ),
              );
            const activeCount = Number(active?.total ?? 0);
            if (activeCount >= input.maxActiveVms) {
              throw new VmLimitExceededError({
                kind: "active_vms",
                billingTeamId: input.billingTeamId,
                limit: input.maxActiveVms,
              });
            }

            const [vm] = await tx
              .insert(cloudVms)
              .values({
                userId: input.userId,
                billingTeamId: input.billingTeamId,
                billingPlanId: input.billingPlanId,
                provider: input.provider,
                imageId: input.image,
                imageVersion: input.imageVersion ?? null,
                status: "provisioning",
                idempotencyKey,
              })
              .returning();
            if (!vm) throw new Error("insert returned no VM row");
            return { inserted: true as const, vm };
          });
        } catch (err) {
          if (idempotencyKey && pgErrorCode(err) === "23505") {
            const existing = await findByIdempotencyKey(input.billingTeamId, idempotencyKey);
            if (existing) return { inserted: false as const, vm: existing };
          }
          throw err;
        }
      },
      catch: (cause) => isVmLimitExceededError(cause)
        ? cause
        : new VmDatabaseError({ operation: "beginCreate", cause }),
    }),

  activeLimitCandidates: (input) =>
    dbEffect("activeLimitCandidates", async () => {
      const db = cloudDb();
      return await db
        .select()
        .from(cloudVms)
        .where(
          and(
            eq(cloudVms.status, "running"),
            isNotNull(cloudVms.providerVmId),
            accountScopeWhere({ userId: input.userId, billingTeamId: input.billingTeamId }),
          ),
        );
    }),

  reservePausedResume: (input) =>
    Effect.tryPromise({
      try: async () => {
        const db = cloudDb();
        return await db.transaction(async (tx) => {
          const lockKey = input.billingTeamId ?? `user:${input.userId}`;
          await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${lockKey}, 0))`);

          const [current] = await tx
            .select()
            .from(cloudVms)
            .where(
              and(
                eq(cloudVms.id, input.id),
                accountScopeWhere({ userId: input.userId, billingTeamId: input.billingTeamId }),
                eq(cloudVms.providerVmId, input.providerVmId),
              ),
            )
            .limit(1);
          if (!current || current.status !== "paused") return current ?? null;

          const teamScope = accountScopeWhere({
            userId: input.userId,
            billingTeamId: input.billingTeamId,
          });
          const [active] = await tx
            .select({ total: count() })
            .from(cloudVms)
            .where(and(inArray(cloudVms.status, ["provisioning", "running"]), teamScope));
          const activeCount = Number(active?.total ?? 0);
          if (activeCount >= input.maxActiveVms) {
            throw new VmLimitExceededError({
              kind: "active_vms",
              billingTeamId: input.billingTeamId ?? input.userId,
              limit: input.maxActiveVms,
            });
          }

          const [reserved] = await tx
            .update(cloudVms)
            .set({ status: "running", updatedAt: new Date() })
            .where(
              and(
                eq(cloudVms.id, input.id),
                eq(cloudVms.status, "paused"),
                eq(cloudVms.providerVmId, input.providerVmId),
              ),
            )
            .returning();
          return reserved ?? current;
        });
      },
      catch: (cause) =>
        isVmLimitExceededError(cause)
          ? cause
          : new VmDatabaseError({ operation: "reservePausedResume", cause }),
    }),

  markProviderObservedStatus: (input) =>
    dbEffect("markProviderObservedStatus", async () => {
      const db = cloudDb();
      const updated = await db
        .update(cloudVms)
        .set({
          status: input.status,
          destroyedAt: input.status === "destroyed" ? new Date() : null,
          updatedAt: new Date(),
        })
        .where(
          and(
            eq(cloudVms.id, input.id),
            eq(cloudVms.providerVmId, input.providerVmId),
            ne(cloudVms.status, "destroyed"),
          ),
        )
        .returning({ id: cloudVms.id });
      return updated.length > 0;
    }),

  markCreateRunning: (input) =>
    dbEffect("markCreateRunning", async () => {
      const db = cloudDb();
      const [vm] = await db
        .update(cloudVms)
        .set({
          providerVmId: input.providerVmId,
          imageId: input.image,
          imageVersion: input.imageVersion ?? null,
          providerMetadata: input.providerMetadata ?? {},
          status: "running",
          failureCode: null,
          failureMessage: null,
          updatedAt: new Date(),
        })
        .where(eq(cloudVms.id, input.id))
        .returning();
      if (!vm) throw new Error(`vm row missing during create finalization: ${input.id}`);
      return vm;
    }),

  markCreateFailed: (input) =>
    dbEffect("markCreateFailed", async () => {
      const db = cloudDb();
      await db
        .update(cloudVms)
        .set({
          status: "failed",
          failureCode: input.code,
          failureMessage: input.message,
          updatedAt: new Date(),
        })
        .where(eq(cloudVms.id, input.id));
    }),

  hasOwnedSnapshot: (input) =>
    dbEffect("hasOwnedSnapshot", async () => {
      const db = cloudDb();
      const teamScope = input.billingTeamId
        ? eq(cloudVmUsageEvents.billingTeamId, input.billingTeamId)
        : and(isNull(cloudVmUsageEvents.billingTeamId), eq(cloudVmUsageEvents.userId, input.userId));
      const [event] = await db
        .select({ id: cloudVmUsageEvents.id })
        .from(cloudVmUsageEvents)
        .where(
          and(
            teamScope,
            eq(cloudVmUsageEvents.provider, input.provider),
            eq(cloudVmUsageEvents.eventType, "vm.snapshot.created"),
            sql`${cloudVmUsageEvents.metadata}->>'snapshotId' = ${input.snapshotId}`,
          ),
        )
        .limit(1);
      return !!event;
    }),

  findUserVm: (input) =>
    dbEffect("findUserVm", async () => {
      const db = cloudDb();
      const [vm] = await db
        .select()
        .from(cloudVms)
        .where(
          and(
            accountScopeWhere({ userId: input.userId, billingTeamId: input.billingTeamId }),
            eq(cloudVms.providerVmId, input.providerVmId),
            ne(cloudVms.status, "destroyed"),
          ),
        )
        .limit(1);
      return vm ?? null;
    }),

  markDestroyed: (id) =>
    dbEffect("markDestroyed", async () => {
      const db = cloudDb();
      await db
        .update(cloudVms)
        .set({
          status: "destroyed",
          destroyedAt: new Date(),
          updatedAt: new Date(),
        })
        .where(eq(cloudVms.id, id));
    }),

  recordLease: (input) =>
    dbEffect("recordLease", async () => {
      const db = cloudDb();
      const values = {
        vmId: input.vmId,
        userId: input.userId,
        kind: input.kind,
        tokenHash: input.tokenHash,
        providerIdentityHandle: input.providerIdentityHandle,
        sessionId: input.sessionId,
        transport: input.transport,
        metadata: input.metadata ?? {},
        expiresAt: input.expiresAt,
      };
      try {
        await db.insert(cloudVmLeases).values(values);
      } catch (err) {
        if (pgErrorCode(err) !== "23505") throw err;
        const [existing] = await db
          .select()
          .from(cloudVmLeases)
          .where(eq(cloudVmLeases.tokenHash, input.tokenHash))
          .limit(1);
        if (
          !existing ||
          existing.vmId !== input.vmId ||
          existing.userId !== input.userId ||
          existing.kind !== input.kind
        ) {
          throw err;
        }
        await db
          .update(cloudVmLeases)
          .set({
            providerIdentityHandle: input.providerIdentityHandle,
            sessionId: input.sessionId,
            transport: input.transport,
            metadata: input.metadata ?? {},
            expiresAt: input.expiresAt,
            revokedAt: null,
          })
          .where(eq(cloudVmLeases.tokenHash, input.tokenHash));
      }
    }),

  listVmSessions: (input) =>
    dbEffect("listVmSessions", async () => {
      const db = cloudDb();
      return await db
        .select()
        .from(cloudVmSessions)
        .where(and(
          eq(cloudVmSessions.vmId, input.vmId),
          ne(cloudVmSessions.status, "closed"),
        ))
        .orderBy(desc(cloudVmSessions.updatedAt));
    }),

  upsertVmSession: (input) =>
    dbEffect("upsertVmSession", async () => {
      const db = cloudDb();
      const now = new Date();
      const [session] = await db
        .insert(cloudVmSessions)
        .values({
          vmId: input.vmId,
          userId: input.userId,
          providerSessionId: input.providerSessionId,
          title: input.title ?? null,
          status: input.status ?? "running",
          attachmentCount: input.attachmentCount ?? 1,
          effectiveCols: input.effectiveCols ?? null,
          effectiveRows: input.effectiveRows ?? null,
          lastKnownCols: input.lastKnownCols ?? null,
          lastKnownRows: input.lastKnownRows ?? null,
          scrollbackBytes: input.scrollbackBytes ?? 0,
          metadata: input.metadata ?? {},
          lastAttachedAt: now,
          updatedAt: now,
        })
        .onConflictDoUpdate({
          target: [cloudVmSessions.vmId, cloudVmSessions.providerSessionId],
          set: {
            userId: input.userId,
            title: input.title ?? null,
            status: input.status ?? "running",
            attachmentCount: sql`${cloudVmSessions.attachmentCount} + ${input.attachmentCount ?? 1}`,
            effectiveCols: input.effectiveCols ?? null,
            effectiveRows: input.effectiveRows ?? null,
            lastKnownCols: input.lastKnownCols ?? null,
            lastKnownRows: input.lastKnownRows ?? null,
            scrollbackBytes: input.scrollbackBytes ?? 0,
            metadata: input.metadata ?? {},
            lastAttachedAt: now,
            updatedAt: now,
            closedAt: null,
          },
        })
        .returning();
      if (!session) throw new Error("cloud VM session upsert returned no row");
      return session;
    }),

  activeIdentityLeases: (vmId) =>
    dbEffect("activeIdentityLeases", async () => {
      const db = cloudDb();
      return await db
        .select()
        .from(cloudVmLeases)
        .where(
          and(
            eq(cloudVmLeases.vmId, vmId),
            isNotNull(cloudVmLeases.providerIdentityHandle),
            isNull(cloudVmLeases.revokedAt),
          ),
        );
    }),

  markLeasesRevoked: (ids) =>
    dbEffect("markLeasesRevoked", async () => {
      if (ids.length === 0) return;
      const db = cloudDb();
      await Promise.all(
        ids.map((id) =>
          db
            .update(cloudVmLeases)
            .set({ revokedAt: new Date() })
            .where(eq(cloudVmLeases.id, id)),
        ),
      );
    }),

  recordUsageEvent: (input) =>
    dbEffect("recordUsageEvent", async () => {
      const db = cloudDb();
      await db.insert(cloudVmUsageEvents).values({
        userId: input.userId,
        billingTeamId: input.billingTeamId ?? null,
        billingPlanId: input.billingPlanId ?? null,
        vmId: input.vmId ?? null,
        eventType: input.eventType,
        provider: input.provider,
        imageId: input.imageId,
        metadata: input.metadata ?? {},
      });
    }),
  recordUsageEvents: (inputs) =>
    dbEffect("recordUsageEvents", async () => {
      if (inputs.length === 0) return;
      const db = cloudDb();
      await db.insert(cloudVmUsageEvents).values(inputs.map((input) => ({
        userId: input.userId,
        billingTeamId: input.billingTeamId ?? null,
        billingPlanId: input.billingPlanId ?? null,
        vmId: input.vmId ?? null,
        eventType: input.eventType,
        provider: input.provider,
        imageId: input.imageId,
        metadata: input.metadata ?? {},
      })));
    }),
});
