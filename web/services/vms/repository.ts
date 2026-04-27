import { and, count, desc, eq, inArray, isNotNull, isNull, ne, or, sql } from "drizzle-orm";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { cloudDb } from "../../db/client";
import { cloudVmLeases, cloudVms, cloudVmUsageEvents } from "../../db/schema";
import type { ProviderId } from "./drivers";
import { VmDatabaseError, VmLimitExceededError, isVmLimitExceededError } from "./errors";

export type CloudVmRow = typeof cloudVms.$inferSelect;
export type CloudVmLeaseRow = typeof cloudVmLeases.$inferSelect;
export type CloudVmLeaseKind = typeof cloudVmLeases.$inferInsert.kind;

export type BeginCreateResult =
  | { readonly inserted: true; readonly vm: CloudVmRow }
  | { readonly inserted: false; readonly vm: CloudVmRow };

export type VmRepositoryShape = {
  readonly listUserVms: (userId: string) => Effect.Effect<CloudVmRow[], VmDatabaseError>;
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
  readonly markCreateRunning: (input: {
    readonly id: string;
    readonly providerVmId: string;
    readonly image: string;
    readonly imageVersion?: string | null;
  }) => Effect.Effect<CloudVmRow, VmDatabaseError>;
  readonly markCreateFailed: (input: {
    readonly id: string;
    readonly code: string;
    readonly message: string;
  }) => Effect.Effect<void, VmDatabaseError>;
  readonly findUserVm: (input: {
    readonly userId: string;
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
  userId: string,
  idempotencyKey: string,
): Promise<CloudVmRow | null> {
  const db = cloudDb();
  const [existing] = await db
    .select()
    .from(cloudVms)
    .where(and(eq(cloudVms.userId, userId), eq(cloudVms.idempotencyKey, idempotencyKey)))
    .limit(1);
  return existing ?? null;
}

export const VmRepositoryLive = Layer.succeed(VmRepository, {
  listUserVms: (userId) =>
    dbEffect("listUserVms", async () => {
      const db = cloudDb();
      return await db
        .select()
        .from(cloudVms)
        .where(and(eq(cloudVms.userId, userId), ne(cloudVms.status, "destroyed")))
        .orderBy(desc(cloudVms.createdAt));
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
                .where(and(eq(cloudVms.userId, input.userId), eq(cloudVms.idempotencyKey, idempotencyKey)))
                .limit(1);
              if (existing) return { inserted: false as const, vm: existing };
            }

            await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${input.billingTeamId}, 0))`);
            const [active] = await tx
              .select({ total: count() })
              .from(cloudVms)
              .where(
                and(
                  inArray(cloudVms.status, ["provisioning", "running", "paused"]),
                  or(
                    eq(cloudVms.billingTeamId, input.billingTeamId),
                    and(isNull(cloudVms.billingTeamId), eq(cloudVms.userId, input.userId)),
                  ),
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
            const existing = await findByIdempotencyKey(input.userId, idempotencyKey);
            if (existing) return { inserted: false as const, vm: existing };
          }
          throw err;
        }
      },
      catch: (cause) => isVmLimitExceededError(cause)
        ? cause
        : new VmDatabaseError({ operation: "beginCreate", cause }),
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

  findUserVm: (input) =>
    dbEffect("findUserVm", async () => {
      const db = cloudDb();
      const [vm] = await db
        .select()
        .from(cloudVms)
        .where(
          and(
            eq(cloudVms.userId, input.userId),
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
});
