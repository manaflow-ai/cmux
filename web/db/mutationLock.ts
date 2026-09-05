import { eq, sql } from "drizzle-orm";
import { accountMutationFences } from "./schema";

/**
 * Hyperdrive intentionally does not expose PostgreSQL advisory locks. Keep the
 * existing advisory-lock implementation for the Vercel runtime, and let a
 * Worker use the same transaction semantics with a row-backed fence instead.
 * `FOR UPDATE` holds the fence until the surrounding transaction commits.
 */
export type MutationLockMode = "advisory" | "row";

export type MutationLockExecutor = {
  readonly execute: (query: unknown) => Promise<unknown>;
  readonly insert: (table: unknown) => {
    values: (value: unknown) => {
      onConflictDoNothing: () => Promise<unknown>;
    };
  };
  readonly select: (...args: readonly unknown[]) => {
    from: (table: unknown) => {
      where: (condition: unknown) => {
        for: (mode: "update") => {
          limit: (count: number) => Promise<readonly unknown[]>;
        };
      };
    };
  };
};

export async function acquireMutationLock(
  tx: MutationLockExecutor,
  key: string,
  mode: MutationLockMode = "advisory",
): Promise<void> {
  if (mode === "advisory") {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${key}, 0))`);
    return;
  }
  await tx.insert(accountMutationFences)
    .values({ lockKey: key })
    .onConflictDoNothing();
  await tx
    .select({ lockKey: accountMutationFences.lockKey })
    .from(accountMutationFences)
    .where(eq(accountMutationFences.lockKey, key))
    .for("update")
    .limit(1);
}
