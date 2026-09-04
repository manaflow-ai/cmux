import { Signer } from "@aws-sdk/rds-signer";
import { awsCredentialsProvider } from "@vercel/oidc-aws-credentials-provider";
import { attachDatabasePool } from "@vercel/functions";
import { drizzle as drizzleNodePg } from "drizzle-orm/node-postgres";
import { drizzle } from "drizzle-orm/postgres-js";
import { Client, Pool, Query as PgQuery } from "pg";
import postgres, { type Sql } from "postgres";
import { cloudDbConfig, cloudDbConfigKey, type CloudDbAwsRdsIamConfig } from "./config";
import { currentCloudDbQuerySignal } from "./queryScope";
import * as schema from "./schema";

function createPostgresJsDb(sql: Sql) {
  installPostgresJsQueryCancellation(sql);
  return drizzle({ client: sql, schema });
}

type CloudDb = ReturnType<typeof createPostgresJsDb>;
type CloudDbState = {
  db: CloudDb;
  close: () => Promise<void>;
  key: string;
};

const globalForDb = globalThis as typeof globalThis & {
  __cmuxCloudDb?: CloudDbState;
};

export function createAwsRdsIamPool(
  config: CloudDbAwsRdsIamConfig,
  overrides: Partial<ConstructorParameters<typeof Pool>[0] & object> = {},
): Pool {
  return new Pool({
    ...awsRdsConnectionOptions(config),
    max: config.poolMax,
    ...overrides,
    Client: overrides.Client ?? CancellableRdsClient,
  });
}

type CancellablePostgresQuery = {
  cancel(): unknown;
  then: Promise<unknown>["then"];
};

function installPostgresJsQueryCancellation(sql: Sql): void {
  const originalUnsafe = sql.unsafe;
  let currentUnsafe = originalUnsafe;
  const wrappedUnsafe = (...args: Parameters<typeof originalUnsafe>) => {
    const query = currentUnsafe(...args) as unknown as CancellablePostgresQuery;
    const signal = currentCloudDbQuerySignal();
    if (signal) watchPostgresJsQuery(query, signal);
    return query;
  };
  // postgres.js recreates the scoped SQL methods when it enters a transaction.
  // An accessor keeps the cancellation wrapper around the latest method.
  Object.defineProperty(sql, "unsafe", {
    configurable: true,
    enumerable: true,
    get: () => wrappedUnsafe,
    set: (next: typeof originalUnsafe) => {
      currentUnsafe = next;
    },
  });
}

function watchPostgresJsQuery(
  query: CancellablePostgresQuery,
  signal: AbortSignal,
): void {
  let settled = false;
  const cleanup = () => {
    if (settled) return;
    settled = true;
    signal.removeEventListener("abort", abort);
  };
  const abort = () => {
    if (settled) return;
    try {
      void Promise.resolve(query.cancel()).catch(() => undefined);
    } catch {
      // The query may settle between the abort and cancellation call.
    }
  };
  signal.addEventListener("abort", abort, { once: true });
  if (signal.aborted) abort();
  void query.then(cleanup, cleanup);
}

class CancellableRdsClient extends Client {}

type RawPgQueryMethod = (
  config: unknown,
  values?: unknown,
  callback?: unknown,
) => unknown;

type PgClientInternals = {
  _activeQuery: unknown;
  _queryQueue: unknown[];
};

type PgQueryInternals = PgQuery & {
  callback?: (...args: unknown[]) => unknown;
};

const rawPgQuery = Client.prototype.query as unknown as RawPgQueryMethod;
CancellableRdsClient.prototype.query = function(
  this: CancellableRdsClient,
  config: unknown,
  values?: unknown,
  callback?: unknown,
): unknown {
  const signal = currentCloudDbQuerySignal();
  if (!signal) return rawPgQuery.call(this, config, values, callback);
  // Drizzle submits strings and query configs. Preserve other pg submittables
  // such as QueryStream and COPY objects without trying to reconstruct them.
  if (
    typeof config === "object" &&
    config !== null &&
    "submit" in config &&
    typeof (config as { submit?: unknown }).submit === "function" &&
    !(config instanceof PgQuery)
  ) {
    return rawPgQuery.call(this, config, values, callback);
  }
  const internals = this as unknown as PgClientInternals;
  const activeBefore = internals._activeQuery;
  const queuedBefore = new Set(internals._queryQueue);
  const result = rawPgQuery.call(this, config, values, callback);
  const query = findSubmittedPgQuery(internals, activeBefore, queuedBefore, config);
  if (query) watchRdsQuery(this, query, signal);
  return result;
} as unknown as Client["query"];

function findSubmittedPgQuery(
  client: PgClientInternals,
  activeBefore: unknown,
  queuedBefore: ReadonlySet<unknown>,
  config: unknown,
): PgQuery | undefined {
  if (config instanceof PgQuery) return config;
  if (client._activeQuery !== activeBefore && client._activeQuery instanceof PgQuery) {
    return client._activeQuery;
  }
  for (let index = client._queryQueue.length - 1; index >= 0; index -= 1) {
    const query = client._queryQueue[index];
    if (!queuedBefore.has(query) && query instanceof PgQuery) return query;
  }
  return undefined;
}

function watchRdsQuery(
  client: CancellableRdsClient,
  query: PgQuery,
  signal: AbortSignal,
): () => void {
  let settled = false;
  const cleanup = () => {
    if (settled) return;
    settled = true;
    signal.removeEventListener("abort", abort);
  };
  const callback = (query as PgQueryInternals).callback;
  if (typeof callback === "function") {
    (query as PgQueryInternals).callback = (...args) => {
      cleanup();
      return callback(...args);
    };
  }
  const abort = () => {
    if (settled) return;
    try {
      // A pool client owns no other application work. Closing it after sending
      // the cancel packet guarantees a stalled socket cannot be reused.
      (client as CancellableRdsClient & {
        cancel(client: CancellableRdsClient, query: PgQuery): void;
      }).cancel(client, query);
    } catch {
      // Fall through to end(), which also interrupts a query that never sent.
    }
    try {
      void client.end().catch(() => undefined);
    } catch {
      // A custom client can throw while closing; cancellation already ran.
    }
  };
  query.once("end", cleanup);
  query.once("error", cleanup);
  signal.addEventListener("abort", abort, { once: true });
  if (signal.aborted) abort();
  return cleanup;
}

/** Creates an independently closable RDS client for bounded probes. */
export function createAwsRdsIamClient(
  config: CloudDbAwsRdsIamConfig,
  overrides: Partial<ConstructorParameters<typeof Client>[0] & object> = {},
): Client {
  return new Client({
    ...awsRdsConnectionOptions(config),
    ...overrides,
  });
}

function awsRdsConnectionOptions(config: CloudDbAwsRdsIamConfig) {
  const signer = new Signer({
    hostname: config.host,
    port: config.port,
    username: config.user,
    region: config.awsRegion,
    credentials: awsCredentialsProvider({
      roleArn: config.awsRoleArn,
      clientConfig: { region: config.awsRegion },
    }),
  });

  return {
    host: config.host,
    port: config.port,
    user: config.user,
    database: config.database,
    password: () => signer.getAuthToken(),
    ssl: {
      rejectUnauthorized: config.sslRejectUnauthorized,
      ...(config.sslCaPem ? { ca: config.sslCaPem } : {}),
    },
  };
}

export function cloudDb(): CloudDb {
  const config = cloudDbConfig();
  const key = cloudDbConfigKey(config);

  if (globalForDb.__cmuxCloudDb?.key === key) {
    return globalForDb.__cmuxCloudDb.db;
  }

  if (config.driver === "aws-rds-iam") {
    const pool = createAwsRdsIamPool(config);
    attachDatabasePool(pool);
    const db = drizzleNodePg({ client: pool, schema }) as unknown as CloudDb;
    globalForDb.__cmuxCloudDb = { db, close: () => pool.end(), key };
    return db;
  }

  const sql = postgres(config.url, {
    max: config.poolMax,
    prepare: false,
  });
  const db = createPostgresJsDb(sql);
  globalForDb.__cmuxCloudDb = { db, close: () => sql.end(), key };
  return db;
}

/**
 * Runs the small database probe used by the coderouter health endpoint.
 *
 * The normal Drizzle client deliberately has no per-query deadline because
 * application queries have different budgets. This probe uses the underlying
 * driver instead: postgres.js exposes cancellation on its pending query, and
 * node-postgres gets a per-query read timeout. The caller's abort signal is
 * checked before and after the driver operation so the health wrapper can
 * stop waiting without retaining an unbounded probe.
 */
export async function pingCloudDb(
  signal: AbortSignal,
  timeoutMs: number,
): Promise<void> {
  const config = cloudDbConfig();
  if (config.driver === "url") {
    const sql = postgres(config.url, {
      max: 1,
      prepare: false,
      connect_timeout: Math.max(1, Math.ceil(timeoutMs / 1_000)),
      idle_timeout: 1,
      connection: { statement_timeout: Math.max(1, Math.floor(timeoutMs)) },
    });
    const query = sql.unsafe("select 1");
    const cancel = () => {
      try {
        query.cancel();
      } catch {
        // The query may have settled between the abort and cancellation call.
      }
    };
    if (signal.aborted) cancel();
    signal.addEventListener("abort", cancel, { once: true });
    try {
      await query;
      if (signal.aborted) throw abortedDatabaseProbe();
    } finally {
      signal.removeEventListener("abort", cancel);
      await sql.end({ timeout: Math.max(1, Math.ceil(timeoutMs / 1_000)) }).catch(() => undefined);
    }
    return;
  }

  const client = createAwsRdsIamClient(config, {
    connectionTimeoutMillis: Math.max(1, Math.floor(timeoutMs)),
    query_timeout: Math.max(1, Math.floor(timeoutMs)),
    statement_timeout: Math.max(1, Math.floor(timeoutMs)),
  });
  let closePromise: Promise<void> | undefined;
  const close = () => {
    closePromise ??= client.end().catch(() => undefined);
    return closePromise;
  };
  const abort = () => {
    // This client belongs only to this probe, so closing its socket is a safe
    // and immediate cancellation for both connection and query phases.
    void close();
  };
  signal.addEventListener("abort", abort, { once: true });
  try {
    if (signal.aborted) throw abortedDatabaseProbe();
    await client.connect();
    if (signal.aborted) throw abortedDatabaseProbe();
    await client.query({ text: "select 1" });
    if (signal.aborted) throw abortedDatabaseProbe();
  } finally {
    signal.removeEventListener("abort", abort);
    await close();
  }
}

function abortedDatabaseProbe(): DOMException {
  return new DOMException("database probe aborted", "AbortError");
}

export async function closeCloudDbForTests(): Promise<void> {
  const state = globalForDb.__cmuxCloudDb;
  globalForDb.__cmuxCloudDb = undefined;
  await state?.close();
}
