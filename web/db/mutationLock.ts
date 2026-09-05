import { sql } from "drizzle-orm";

/**
 * Hyperdrive intentionally does not expose PostgreSQL advisory locks. Direct
 * Worker traffic takes a pre-seeded row fence, while the Vercel cutover path
 * can take that same row plus its existing advisory lock in one statement.
 * A fixed bucket set keeps the table bounded. Bucket collisions add contention
 * without weakening correctness. `FOR UPDATE` holds the row until commit.
 */
export type MutationLockMode = "advisory" | "row" | "hybrid";

export const MUTATION_FENCE_BUCKET_COUNT = 4_096;
const MUTATION_FENCE_PREFIX = "bucket:";

/** Stable across Node and workerd, without depending on a runtime hash seed. */
export function mutationFenceKey(lockKey: string): string {
  const bytes = new TextEncoder().encode(lockKey);
  let hash = 2_166_136_261;
  for (const byte of bytes) hash = Math.imul(hash ^ byte, 16_777_619);
  return `${MUTATION_FENCE_PREFIX}${(hash >>> 0) % MUTATION_FENCE_BUCKET_COUNT}`;
}

export type MutationLockExecutor = {
  readonly execute: (query: unknown) => Promise<unknown>;
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

  const fenceKey = mutationFenceKey(key);
  if (mode === "hybrid") {
    // The division is a fail-closed migration guard. A missing pre-seeded row
    // yields zero and aborts the transaction instead of silently running with
    // only the advisory half of the cross-runtime fence.
    await tx.execute(sql`
      select
        pg_advisory_xact_lock(hashtextextended(${key}, 0)),
        1 / count(*)::bigint as mutation_fence_acquired
      from (
        select lock_key
        from account_mutation_fences
        where lock_key = ${fenceKey}
        for update
      ) as locked_mutation_fence
    `);
    return;
  }

  await tx.execute(sql`
    select 1 / count(*)::bigint as mutation_fence_acquired
    from (
      select lock_key
      from account_mutation_fences
      where lock_key = ${fenceKey}
      for update
    ) as locked_mutation_fence
  `);
}
