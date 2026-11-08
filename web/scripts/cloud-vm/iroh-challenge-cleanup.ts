import * as Effect from "effect/Effect";
import type { Pool, PoolClient, QueryResult } from "pg";

type CleanupOptions = {
  readonly apply?: boolean;
  readonly now?: Date;
  readonly batchSize?: number;
  readonly maxDurationMs?: number;
};

export class IrohChallengeCleanupError extends Error {
  constructor(error: unknown) {
    super(`Iroh challenge cleanup failed (${errorCode(error)}); committed batches can be safely rerun`);
  }
}

// Operator-only data migration. Never import this from a route or app startup.
// The deployed issuer owns the ongoing one-challenge-per-tuple invariant.
export function cleanupIrohChallenges(pool: Pool, options: CleanupOptions = {}) {
  return Effect.tryPromise({
    try: () => runCleanup(pool, options),
    // PostgreSQL errors may contain row data. Report only the operation/code.
    catch: (error) => new IrohChallengeCleanupError(error),
  });
}

function errorCode(error: unknown): string {
  const code = (error as { code?: unknown } | null)?.code;
  return typeof code === "string" && /^[A-Z0-9_]+$/.test(code) ? code : "OPERATION_FAILED";
}

async function runCleanup(pool: Pool, options: CleanupOptions) {
  const now = options.now ?? new Date();
  const batchSize = options.batchSize ?? 1_000;
  const duration = options.maxDurationMs ?? 15 * 60_000;
  if (!Number.isInteger(batchSize) || batchSize < 1 || batchSize > 1_000
    || !Number.isInteger(duration) || duration < 1 || duration > 15 * 60_000
    || !Number.isFinite(now.getTime())) {
    throw Object.assign(new Error(), { code: "INVALID_OPTIONS" });
  }
  const deadline = Date.now() + duration;
  const checkDeadline = () => {
    if (Date.now() >= deadline) throw Object.assign(new Error(), { code: "TIME_BUDGET_EXHAUSTED" });
  };
  const client = await pool.connect();
  try {
    await client.query("set statement_timeout = '30s'");
    const before = await inspectChallenges(client, now);
    const deleted = { expired: 0, consumed: 0, superseded: 0 };
    if (!options.apply) return { applied: false, before, after: before, deleted };

    for (const category of ["expired", "consumed"] as const) {
      let affected: number;
      do {
        checkDeadline();
        affected = await transaction(client, async () => {
          // Each path uses its existing expiry/consumption index. SKIP LOCKED
          // lets an in-flight registration finish; final verification catches
          // any skipped rows instead of claiming the cleanup is complete.
          const result = await client.query(category === "expired" ? `
            delete from iroh_registration_challenges where id in (
              select id from iroh_registration_challenges
              where expires_at <= $1 order by expires_at, id
              limit $2 for update skip locked
            )` : `
            delete from iroh_registration_challenges where id in (
              select id from iroh_registration_challenges
              where consumed_at is not null order by consumed_at, id
              limit $1 for update skip locked
            )`, category === "expired" ? [now, batchSize] : [batchSize]);
          return result.rowCount ?? 0;
        });
        deleted[category] += affected;
      } while (affected === batchSize);
    }

    // Expired history is gone before ranking. Keyset traversal uses the
    // existing user_id index, and only one user's pending rows are ranked.
    let previousUser: string | null = null;
    while (true) {
      checkDeadline();
      const next: QueryResult<{ user_id: string }> = await client.query(previousUser === null ? `
        select user_id from iroh_registration_challenges order by user_id limit 1
      ` : `
        select user_id from iroh_registration_challenges
        where user_id > $1 order by user_id limit 1
      `, previousUser === null ? [] : [previousUser]);
      const userId: string | undefined = next.rows[0]?.user_id;
      if (userId === undefined) break;
      let affected: number;
      do {
        checkDeadline();
        affected = await transaction(client, async () => {
          // Match both old and new issuers' lock. Read the ranking AFTER the
          // lock is acquired so a writer committing while we wait is visible.
          await client.query("select pg_advisory_xact_lock(hashtextextended($1, 0))", [`iroh:challenge:${userId}`]);
          const result = await client.query(`
            with ranked as (
              select id, row_number() over (
                partition by client_namespace, device_uuid, tag
                order by created_at desc, id desc
              ) as position
              from iroh_registration_challenges
              where user_id = $1 and consumed_at is null and expires_at > $2
            )
            delete from iroh_registration_challenges where id in (
              select id from ranked where position > 1 order by id limit $3
            )`, [userId, now, batchSize]);
          return result.rowCount ?? 0;
        });
        deleted.superseded += affected;
      } while (affected === batchSize);
      previousUser = userId;
    }
    const after = await inspectChallenges(client, now);
    if (after.expired || after.consumed || after.duplicates) {
      throw Object.assign(new Error(), { code: "ROWS_REMAIN_RERUN" });
    }
    return { applied: true, before, after, deleted };
  } finally {
    // This connection has operator-specific timeouts; discard it on release.
    client.release(true);
  }
}

async function transaction<T>(client: PoolClient, run: () => Promise<T>): Promise<T> {
  await client.query("begin");
  try {
    await client.query("set local lock_timeout = '2s'");
    await client.query("set local statement_timeout = '5s'");
    const result = await run();
    await client.query("commit");
    return result;
  } catch (error) {
    await client.query("rollback");
    throw error;
  }
}

async function inspectChallenges(client: PoolClient, now: Date) {
  const result = await client.query<{
    rows: number; expired: number; consumed: number; duplicates: number; allocatedBytes: string;
  }>(`select
    count(*)::int as rows,
    count(*) filter (where expires_at <= $1)::int as expired,
    count(*) filter (where consumed_at is not null)::int as consumed,
    (count(*) filter (where consumed_at is null and expires_at > $1)
      - count(distinct (user_id, client_namespace, device_uuid, tag))
        filter (where consumed_at is null and expires_at > $1))::int as duplicates,
    pg_total_relation_size('iroh_registration_challenges')::text as "allocatedBytes"
    from iroh_registration_challenges`, [now]);
  return result.rows[0]!;
}
