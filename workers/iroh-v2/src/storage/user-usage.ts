import { sql } from "drizzle-orm";
import { drizzle } from "drizzle-orm/durable-sqlite";
import { OperationError } from "../errors";
import { applyStorageMigrations } from "./migrations";
import { storageSchema } from "./schema";

export type UsageScope = Readonly<{ environment: string; projectId: string }>;
export type UsageOperation = keyof typeof USAGE_POLICIES;
export type UsageDecision = Readonly<{ remaining: number; retryAfterMs?: number }>;

type Policy = Readonly<{ capacity: number; refillPerMs: number }>;

const perHour = (limit: number, burst: number): Policy => ({ capacity: burst, refillPerMs: limit / 3_600_000 });
const perMinute = (limit: number, burst: number): Policy => ({ capacity: burst, refillPerMs: limit / 60_000 });

/** Fixed server policy. Callers cannot supply a policy that resets another user's bucket. */
export const USAGE_POLICIES = {
  "control.socket": perMinute(300, 100),
  "device.register": perHour(300, 50),
  "ticket.request": perHour(1200, 100),
  "relay.request": perHour(1200, 100),
  "challenge.request": perHour(300, 50),
  "recovery.approval": perHour(120, 20),
  "directory.request": perMinute(600, 200),
  "device.metadata": perMinute(600, 200),
  "session.goodbye": perMinute(600, 200),
  "session.ack": perMinute(6000, 1000),
  "device.revoke": perMinute(120, 50),
  "permission.update": perMinute(120, 50),
  "preferences.update": perMinute(300, 100),
  "workspace.snapshot": perMinute(600, 200),
  "workspace.get": perMinute(600, 200),
  "input.rejected": perMinute(6000, 1000),
} as const satisfies Record<string, Policy>;

export class UserUsageStore {
  readonly #db;
  readonly #scopeKey: string;

  constructor(readonly storage: DurableObjectStorage, readonly scope: UsageScope, options?: { initialize?: boolean }) {
    this.#db = drizzle(storage, { schema: storageSchema });
    this.#scopeKey = JSON.stringify([scope.environment, scope.projectId]);
    if (options?.initialize !== false) applyStorageMigrations(storage);
  }

  initialize(now = Date.now()): void { applyStorageMigrations(this.storage, now); }

  consume(userId: string, operation: UsageOperation, now = Date.now()): UsageDecision {
    if (!userId) throw new OperationError("unauthorized", 401);
    if (!Object.prototype.hasOwnProperty.call(USAGE_POLICIES, operation)) throw new OperationError("invalid_request", 400);
    const policy = USAGE_POLICIES[operation];
    return this.storage.transactionSync(() => {
      const key = this.#scopeKey;
      const existing = this.#db.get<{ tokens: number; refilled_at: number; consumed: number }>(sql`SELECT "tokens", "refilled_at", "consumed" FROM "user_usage" WHERE "scope_key" = ${key} AND "user_id" = ${userId} AND "operation" = ${operation}`);
      if (!existing) {
        const remaining = policy.capacity - 1;
        this.#db.run(sql`INSERT INTO "user_usage" ("scope_key", "user_id", "operation", "tokens", "refilled_at", "consumed") VALUES (${key}, ${userId}, ${operation}, ${remaining}, ${now}, 1)`);
        return { remaining };
      }
      const elapsed = Math.max(0, now - existing.refilled_at);
      const available = Math.min(policy.capacity, existing.tokens + elapsed * policy.refillPerMs);
      if (available < 1) {
        const retryAfterMs = Math.max(1, Math.ceil((1 - available) / policy.refillPerMs));
        throw new OperationError("rate_limited", 429, true, retryAfterMs);
      }
      const remaining = available - 1;
      this.#db.run(sql`UPDATE "user_usage" SET "tokens" = ${remaining}, "refilled_at" = ${now}, "consumed" = "consumed" + 1 WHERE "scope_key" = ${key} AND "user_id" = ${userId} AND "operation" = ${operation}`);
      return { remaining };
    });
  }

  inspect(userId: string, operation: UsageOperation): { tokens: number; refilledAt: number; consumed: number } | null {
    const row = this.#db.get<{ tokens: number; refilled_at: number; consumed: number }>(sql`SELECT "tokens", "refilled_at", "consumed" FROM "user_usage" WHERE "scope_key" = ${this.#scopeKey} AND "user_id" = ${userId} AND "operation" = ${operation}`);
    return row ? { tokens: row.tokens, refilledAt: row.refilled_at, consumed: row.consumed } : null;
  }
}
