import { and, desc, eq, gte, sql } from "drizzle-orm";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { cloudDb } from "../../db/client";
import {
  coderouterCredentials,
  coderouterKeys,
  coderouterPools,
  coderouterUsageEvents,
} from "../../db/schema";
import { CoderouterDatabaseError, CoderouterNotFoundError } from "./errors";
import { priceUsageMicros } from "./pricing";
import type { BillingCustomerType } from "./billing";
import type { CredentialClass, Family, KeyPolicy, PoolConfig, Usage, UsageIngest } from "./types";

export type CoderouterPoolRow = typeof coderouterPools.$inferSelect;
export type CoderouterCredentialRow = typeof coderouterCredentials.$inferSelect;
export type CoderouterKeyRow = typeof coderouterKeys.$inferSelect;

export type CreateCredentialInput = {
  readonly teamId: string;
  readonly family: Family;
  readonly billingCustomerType: BillingCustomerType;
  readonly kind: "oauth" | "api_key";
  readonly class: CredentialClass;
  readonly label?: string | null;
  readonly providerEmail?: string | null;
  readonly providerAccountId?: string | null;
  readonly encryptedSecret?: string | null;
  readonly meta?: Record<string, unknown>;
};

export type UsageSummaryRow = {
  readonly day: string;
  readonly model: string | null;
  readonly credentialClass: string;
  readonly inputTokens: UsageSummaryValue;
  readonly outputTokens: UsageSummaryValue;
  readonly cacheReadTokens: UsageSummaryValue;
  readonly cacheWriteTokens: UsageSummaryValue;
  readonly costMicros: UsageSummaryValue;
  readonly requests: UsageSummaryValue;
};

export type UsageSummaryValue = number | string | bigint;

export type IngestInsertResult = {
  readonly inserted: number;
  readonly managedCostMicros: number;
};

export type CoderouterRepositoryShape = {
  readonly getOrCreatePool: (
    teamId: string,
    family: Family,
    billingCustomerType?: BillingCustomerType,
  ) => Effect.Effect<CoderouterPoolRow, CoderouterDatabaseError>;
  readonly listPoolsForTeam: (teamId: string) => Effect.Effect<CoderouterPoolRow[], CoderouterDatabaseError>;
  readonly poolForName: (poolName: string) => Effect.Effect<CoderouterPoolRow, CoderouterDatabaseError | CoderouterNotFoundError>;
  readonly listKeys: (teamId: string) => Effect.Effect<CoderouterKeyRow[], CoderouterDatabaseError>;
  readonly createKey: (input: {
    readonly kid: string;
    readonly teamId: string;
    readonly name: string;
    readonly secretHash: string;
    readonly policy: KeyPolicy;
  }) => Effect.Effect<CoderouterKeyRow, CoderouterDatabaseError>;
  readonly revokeKey: (teamId: string, keyId: string) => Effect.Effect<CoderouterKeyRow, CoderouterDatabaseError | CoderouterNotFoundError>;
  readonly listCredentials: (teamId: string) => Effect.Effect<CoderouterCredentialRow[], CoderouterDatabaseError>;
  readonly createCredential: (input: CreateCredentialInput) => Effect.Effect<CoderouterCredentialRow, CoderouterDatabaseError>;
  readonly disableCredential: (teamId: string, credentialId: string) => Effect.Effect<CoderouterCredentialRow, CoderouterDatabaseError | CoderouterNotFoundError>;
  readonly buildPoolConfig: (input: {
    readonly teamId: string;
    readonly family: Family;
    readonly billingCustomerType: BillingCustomerType;
    readonly balanceMicros: number;
    readonly managedEnabled: boolean;
  }) => Effect.Effect<PoolConfig, CoderouterDatabaseError>;
  readonly usageSummary: (teamId: string, days: number) => Effect.Effect<UsageSummaryRow[], CoderouterDatabaseError>;
  readonly insertUsageEvents: (input: {
    readonly teamId: string;
    readonly events: readonly UsageIngest["events"][number][];
  }) => Effect.Effect<IngestInsertResult, CoderouterDatabaseError>;
  readonly applyStatusUpdates: (input: {
    readonly poolName: string;
    readonly updates: readonly { credentialId: string; status: "active" | "needs_reauth" }[];
  }) => Effect.Effect<void, CoderouterDatabaseError>;
};

export class CoderouterRepository extends Context.Tag("cmux/CoderouterRepository")<
  CoderouterRepository,
  CoderouterRepositoryShape
>() {}

function dbEffect<A>(operation: string, run: () => Promise<A>): Effect.Effect<A, CoderouterDatabaseError> {
  return Effect.tryPromise({
    try: run,
    catch: (cause) => new CoderouterDatabaseError(operation, cause),
  });
}

export function poolName(teamId: string, family: Family): string {
  return `${teamId}:${family}`;
}

export function parsePoolName(value: string): { readonly teamId: string; readonly family: Family } | null {
  const idx = value.lastIndexOf(":");
  if (idx <= 0) return null;
  const teamId = value.slice(0, idx);
  const family = value.slice(idx + 1);
  return family === "anthropic" || family === "openai" ? { teamId, family } : null;
}

export const CoderouterRepositoryLive = Layer.succeed(CoderouterRepository, {
  getOrCreatePool: (teamId, family, billingCustomerType = "team") =>
    dbEffect("getOrCreatePool", async () => {
      const db = cloudDb();
      const [inserted] = await db
        .insert(coderouterPools)
        .values({ teamId, family, billingCustomerType })
        .onConflictDoNothing({ target: [coderouterPools.teamId, coderouterPools.family] })
        .returning();
      if (inserted) return inserted;
      const [existing] = await db
        .select()
        .from(coderouterPools)
        .where(and(eq(coderouterPools.teamId, teamId), eq(coderouterPools.family, family)))
        .limit(1);
      if (!existing) throw new Error("coderouter pool missing after insert conflict");
      return existing;
    }),

  listPoolsForTeam: (teamId) =>
    dbEffect("listPoolsForTeam", async () => {
      const db = cloudDb();
      return await db.select().from(coderouterPools).where(eq(coderouterPools.teamId, teamId));
    }),

  poolForName: (name) => {
    const parsed = parsePoolName(name);
    if (!parsed) return Effect.fail(new CoderouterNotFoundError("pool"));
    return Effect.tryPromise({
      try: async () => {
        const db = cloudDb();
        const [pool] = await db
          .select()
          .from(coderouterPools)
          .where(and(eq(coderouterPools.teamId, parsed.teamId), eq(coderouterPools.family, parsed.family)))
          .limit(1);
        if (!pool) throw new CoderouterNotFoundError("pool");
        return pool;
      },
      catch: (cause) =>
        cause instanceof CoderouterNotFoundError
          ? cause
          : new CoderouterDatabaseError("poolForName", cause),
    });
  },

  listKeys: (teamId) =>
    dbEffect("listKeys", async () => {
      const db = cloudDb();
      return await db
        .select()
        .from(coderouterKeys)
        .where(eq(coderouterKeys.teamId, teamId))
        .orderBy(desc(coderouterKeys.createdAt));
    }),

  createKey: (input) =>
    dbEffect("createKey", async () => {
      const db = cloudDb();
      const [row] = await db
        .insert(coderouterKeys)
        .values({
          id: input.kid,
          teamId: input.teamId,
          name: input.name,
          secretHash: input.secretHash,
          policy: input.policy,
        })
        .returning();
      if (!row) throw new Error("insert returned no coderouter key row");
      return row;
    }),

  revokeKey: (teamId, keyId) =>
    Effect.tryPromise({
      try: async () => {
        const db = cloudDb();
        const [row] = await db
          .update(coderouterKeys)
          .set({ revokedAt: new Date() })
          .where(and(eq(coderouterKeys.teamId, teamId), eq(coderouterKeys.id, keyId)))
          .returning();
        if (!row) throw new CoderouterNotFoundError("key");
        return row;
      },
      catch: (cause) =>
        cause instanceof CoderouterNotFoundError
          ? cause
          : new CoderouterDatabaseError("revokeKey", cause),
    }),

  listCredentials: (teamId) =>
    dbEffect("listCredentials", async () => {
      const db = cloudDb();
      return await db
        .select({
          id: coderouterCredentials.id,
          poolId: coderouterCredentials.poolId,
          kind: coderouterCredentials.kind,
          class: coderouterCredentials.class,
          status: coderouterCredentials.status,
          label: coderouterCredentials.label,
          providerEmail: coderouterCredentials.providerEmail,
          providerAccountId: coderouterCredentials.providerAccountId,
          encryptedSecret: coderouterCredentials.encryptedSecret,
          meta: coderouterCredentials.meta,
          createdAt: coderouterCredentials.createdAt,
          lastUsedAt: coderouterCredentials.lastUsedAt,
        })
        .from(coderouterCredentials)
        .innerJoin(coderouterPools, eq(coderouterCredentials.poolId, coderouterPools.id))
        .where(eq(coderouterPools.teamId, teamId))
        .orderBy(desc(coderouterCredentials.createdAt));
    }),

  createCredential: (input) =>
    dbEffect("createCredential", async () => {
      const db = cloudDb();
      const pool = await getOrCreatePoolWithDb(input.teamId, input.family, input.billingCustomerType);
      const [row] = await db
        .insert(coderouterCredentials)
        .values({
          poolId: pool.id,
          kind: input.kind,
          class: input.class,
          label: input.label ?? null,
          providerEmail: input.providerEmail ?? null,
          providerAccountId: input.providerAccountId ?? null,
          encryptedSecret: input.encryptedSecret ?? null,
          meta: input.meta ?? {},
        })
        .returning();
      if (!row) throw new Error("insert returned no coderouter credential row");
      return row;
    }),

  disableCredential: (teamId, credentialId) =>
    Effect.tryPromise({
      try: async () => {
        const db = cloudDb();
        const [row] = await db
          .update(coderouterCredentials)
          .set({ status: "disabled" })
          .from(coderouterPools)
          .where(and(
            eq(coderouterCredentials.id, credentialId),
            eq(coderouterCredentials.poolId, coderouterPools.id),
            eq(coderouterPools.teamId, teamId),
          ))
          .returning();
        if (!row) throw new CoderouterNotFoundError("credential");
        return row;
      },
      catch: (cause) =>
        cause instanceof CoderouterNotFoundError
          ? cause
          : new CoderouterDatabaseError("disableCredential", cause),
    }),

  buildPoolConfig: (input) =>
    dbEffect("buildPoolConfig", async () => {
      const db = cloudDb();
      const pool = await getOrCreatePoolWithDb(input.teamId, input.family, input.billingCustomerType);
      const keys = await db
        .select()
        .from(coderouterKeys)
        .where(eq(coderouterKeys.teamId, input.teamId));
      const credentials = await db
        .select()
        .from(coderouterCredentials)
        .where(eq(coderouterCredentials.poolId, pool.id));
      return poolConfigFromRows({
        teamId: input.teamId,
        family: input.family,
        keys,
        credentials,
        balanceMicros: input.balanceMicros,
        managedEnabled: input.managedEnabled,
        configVersion: Date.now(),
      });
    }),

  usageSummary: (teamId, days) =>
    dbEffect("usageSummary", async () => {
      const db = cloudDb();
      const since = new Date(Date.now() - days * 24 * 60 * 60 * 1000);
      return await db
        .select({
          day: sql<string>`to_char(date_trunc('day', ${coderouterUsageEvents.createdAt}), 'YYYY-MM-DD')`,
          model: coderouterUsageEvents.model,
          credentialClass: coderouterUsageEvents.credentialClass,
          inputTokens: sql<UsageSummaryValue>`coalesce(sum(${coderouterUsageEvents.inputTokens}), 0)::bigint`,
          outputTokens: sql<UsageSummaryValue>`coalesce(sum(${coderouterUsageEvents.outputTokens}), 0)::bigint`,
          cacheReadTokens: sql<UsageSummaryValue>`coalesce(sum(${coderouterUsageEvents.cacheReadTokens}), 0)::bigint`,
          cacheWriteTokens: sql<UsageSummaryValue>`coalesce(sum(${coderouterUsageEvents.cacheWriteTokens}), 0)::bigint`,
          costMicros: sql<UsageSummaryValue>`coalesce(sum(${coderouterUsageEvents.costMicros}), 0)::bigint`,
          requests: sql<UsageSummaryValue>`count(*)::bigint`,
        })
        .from(coderouterUsageEvents)
        .where(and(eq(coderouterUsageEvents.teamId, teamId), gte(coderouterUsageEvents.createdAt, since)))
        .groupBy(
          sql`date_trunc('day', ${coderouterUsageEvents.createdAt})`,
          coderouterUsageEvents.model,
          coderouterUsageEvents.credentialClass,
        )
        .orderBy(sql`date_trunc('day', ${coderouterUsageEvents.createdAt}) desc`);
    }),

  insertUsageEvents: (input) =>
    dbEffect("insertUsageEvents", async () => {
      const db = cloudDb();
      let inserted = 0;
      let managedCostMicros = 0;
      await db.transaction(async (tx) => {
        for (const event of input.events) {
          const usage: Usage = {
            inputTokens: event.inputTokens,
            outputTokens: event.outputTokens,
            cacheReadTokens: event.cacheReadTokens,
            cacheWriteTokens: event.cacheWriteTokens,
            estimated: event.estimated,
          };
          const costMicros = event.credentialClass === "managed"
            ? priceUsageMicros(event.model, usage)
            : event.costMicros ?? null;
          const [row] = await tx
            .insert(coderouterUsageEvents)
            .values({
              eventId: event.eventId,
              teamId: input.teamId,
              keyId: event.keyId ?? null,
              credentialId: event.credentialId ?? null,
              family: event.family,
              endpointClass: event.endpointClass,
              model: event.model ?? null,
              credentialClass: event.credentialClass,
              status: event.status,
              inputTokens: event.inputTokens,
              outputTokens: event.outputTokens,
              cacheReadTokens: event.cacheReadTokens,
              cacheWriteTokens: event.cacheWriteTokens,
              estimated: event.estimated,
              costMicros,
              latencyMs: event.latencyMs ?? null,
              createdAt: new Date(event.ts),
            })
            .onConflictDoNothing({ target: coderouterUsageEvents.eventId })
            .returning({ costMicros: coderouterUsageEvents.costMicros });
          if (!row) continue;
          inserted += 1;
          if (event.credentialClass === "managed" && row.costMicros) {
            managedCostMicros += row.costMicros;
          }
        }
      });
      return { inserted, managedCostMicros };
    }),

  applyStatusUpdates: (input) =>
    dbEffect("applyStatusUpdates", async () => {
      const parsed = parsePoolName(input.poolName);
      if (!parsed || input.updates.length === 0) return;
      const db = cloudDb();
      const pool = await getOrCreatePoolWithDb(parsed.teamId, parsed.family);
      await db.transaction(async (tx) => {
        for (const update of input.updates) {
          await tx
            .update(coderouterCredentials)
            .set({ status: update.status })
            .where(and(eq(coderouterCredentials.id, update.credentialId), eq(coderouterCredentials.poolId, pool.id)));
        }
      });
    }),
});

async function getOrCreatePoolWithDb(
  teamId: string,
  family: Family,
  billingCustomerType: BillingCustomerType = "team",
): Promise<CoderouterPoolRow> {
  const db = cloudDb();
  const [inserted] = await db
    .insert(coderouterPools)
    .values({ teamId, family, billingCustomerType })
    .onConflictDoNothing({ target: [coderouterPools.teamId, coderouterPools.family] })
    .returning();
  if (inserted) return inserted;
  const [existing] = await db
    .select()
    .from(coderouterPools)
    .where(and(eq(coderouterPools.teamId, teamId), eq(coderouterPools.family, family)))
    .limit(1);
  if (!existing) throw new Error("coderouter pool missing after insert conflict");
  return existing;
}

function normalizedPolicy(policy: unknown): KeyPolicy {
  if (!policy || typeof policy !== "object") return {};
  const allowed = (policy as { allowedClasses?: unknown }).allowedClasses;
  if (!Array.isArray(allowed)) return {};
  const classes = allowed.filter((value): value is CredentialClass =>
    value === "oauth" || value === "byok" || value === "managed"
  );
  return classes.length > 0 ? { allowedClasses: [...new Set(classes)] } : {};
}

export function poolConfigFromRows(input: {
  readonly teamId: string;
  readonly family: Family;
  readonly keys: readonly Pick<CoderouterKeyRow, "id" | "revokedAt" | "policy">[];
  readonly credentials: readonly Pick<
    CoderouterCredentialRow,
    "id" | "kind" | "class" | "status" | "label" | "providerAccountId" | "encryptedSecret"
  >[];
  readonly balanceMicros: number;
  readonly managedEnabled: boolean;
  readonly configVersion: number;
}): PoolConfig {
  return {
    poolId: poolName(input.teamId, input.family),
    teamId: input.teamId,
    family: input.family,
    configVersion: input.configVersion,
    keys: input.keys.map((key) => ({
      kid: key.id,
      revoked: key.revokedAt !== null,
      policy: normalizedPolicy(key.policy),
    })),
    credentials: input.credentials.map((credential) => ({
      id: credential.id,
      kind: credential.kind,
      class: credential.class,
      status: credential.status,
      ...(credential.label ? { label: credential.label } : {}),
      ...(credential.providerAccountId ? { providerAccountId: credential.providerAccountId } : {}),
      ...(credential.encryptedSecret ? { encryptedSecret: credential.encryptedSecret } : {}),
    })),
    managed: { enabled: input.managedEnabled },
    balanceMicros: input.balanceMicros,
  };
}
