// Dedicated deadline-bounded Postgres access for relay fleet hooks
// (/api/relay/allow, /api/relay/report).
//
// These hooks deliberately do NOT borrow the shared cloudDb client: its pool
// checkout and connection phases have no deadline there, so a stalled
// operation could neither be cancelled nor be counted on to settle. Each hook
// instead owns a client sized to its concurrency cap with a hard bound on
// every phase (connect, checkout, execution, plus a client-side cancel), so
// every hook operation settles within a known bound and the hook's
// concurrency slots — released strictly at settlement — bound retained work
// without ever staying saturated after an outage heals.
//
// Clients are cached per hook name so each hook keeps its own pool: report
// ingestion load can never queue behind (or starve) connection admissions.

import { attachDatabasePool } from "@vercel/functions";
import type { Pool } from "pg";
import postgres, { type Sql } from "postgres";

import { createAwsRdsIamPool } from "../../db/client";
import { cloudDbConfig, cloudDbConfigKey } from "../../db/config";

/** Connection-establishment (and, for pg, checkout-wait) deadline. */
const CONNECT_TIMEOUT_MS = 5_000;
const IDLE_TIMEOUT_SECONDS = 60;

export type RelayHookDbBounds = {
  /**
   * Pool size; pair it with the hook's concurrency cap so no hook operation
   * ever queues inside the driver.
   */
  readonly maxConnections: number;
  /**
   * Server-side statement_timeout, set as a session parameter on every
   * connection: Postgres cancels an executing statement and frees the
   * connection.
   */
  readonly statementTimeoutMs: number;
  /**
   * Client-side settle bound. postgres.js: a timer calls query.cancel(),
   * which rejects the query whether it is still queued or already executing.
   * pg: the pool's query_timeout enforces the same bound. Keep it above the
   * statement timeout so the server usually cancels first.
   */
  readonly settleMs: number;
};

export type RelayHookDbClient = {
  readonly query: (
    text: string,
    params: readonly unknown[],
  ) => Promise<readonly Record<string, unknown>[]>;
  readonly close: () => Promise<void>;
};

type CachedClient = {
  readonly configKey: string;
  readonly client: RelayHookDbClient;
};

const globalForHooks = globalThis as typeof globalThis & {
  __cmuxRelayHookDbClients?: Map<string, CachedClient>;
};

export function relayHookDbClient(
  hook: string,
  bounds: RelayHookDbBounds,
): RelayHookDbClient {
  const config = cloudDbConfig();
  const configKey = cloudDbConfigKey(config);
  const cache = (globalForHooks.__cmuxRelayHookDbClients ??= new Map());
  const cached = cache.get(hook);
  if (cached?.configKey === configKey) return cached.client;
  if (cached) {
    // The database config rotated within this runtime: drop the stale client
    // and close it so its pool is not retained alongside the replacement.
    // In-flight operations hold their own reference and settle under their
    // phase deadlines; close() (pool.end / sql.end) waits for them, so this
    // cannot interrupt an operation already running.
    cache.delete(hook);
    void cached.client.close().catch(() => {
      // Best-effort teardown; the replacement client is unaffected.
    });
  }

  let client: RelayHookDbClient;
  if (config.driver === "aws-rds-iam") {
    const pool: Pool = createAwsRdsIamPool(config, {
      max: bounds.maxConnections,
      // Bounds checkout waits as well as connection establishment.
      connectionTimeoutMillis: CONNECT_TIMEOUT_MS,
      idleTimeoutMillis: IDLE_TIMEOUT_SECONDS * 1_000,
      statement_timeout: bounds.statementTimeoutMs,
      query_timeout: bounds.settleMs,
    });
    attachDatabasePool(pool);
    client = {
      query: async (text, params) => {
        const result = await pool.query(text, params as unknown[]);
        return result.rows as readonly Record<string, unknown>[];
      },
      close: () => pool.end(),
    };
  } else {
    const sql: Sql = postgres(config.url, {
      max: bounds.maxConnections,
      prepare: false,
      connect_timeout: Math.ceil(CONNECT_TIMEOUT_MS / 1_000),
      idle_timeout: IDLE_TIMEOUT_SECONDS,
      connection: { statement_timeout: bounds.statementTimeoutMs },
    });
    client = {
      query: async (text, params) => {
        const query = sql.unsafe(text, params as never[]);
        // cancel() rejects the query whether still queued or executing, so
        // the operation settles even through a pool or network stall.
        const settleBound = setTimeout(() => {
          try {
            query.cancel();
          } catch {
            // Cancellation is best-effort; the statement timeout remains.
          }
        }, bounds.settleMs);
        try {
          return (await query) as unknown as readonly Record<string, unknown>[];
        } finally {
          clearTimeout(settleBound);
        }
      },
      close: () => sql.end(),
    };
  }
  cache.set(hook, { configKey, client });
  return client;
}

export async function closeRelayHookDbClientForTests(hook: string): Promise<void> {
  const cache = globalForHooks.__cmuxRelayHookDbClients;
  const cached = cache?.get(hook);
  cache?.delete(hook);
  await cached?.client.close();
}
