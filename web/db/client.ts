import { Signer } from "@aws-sdk/rds-signer";
import { awsCredentialsProvider } from "@vercel/oidc-aws-credentials-provider";
import { attachDatabasePool } from "@vercel/functions";
import { drizzle as drizzleNodePg } from "drizzle-orm/node-postgres";
import { drizzle } from "drizzle-orm/postgres-js";
import { Client, Pool } from "pg";
import postgres, { type Sql } from "postgres";
import { cloudDbConfig, cloudDbConfigKey, type CloudDbAwsRdsIamConfig } from "./config";
import * as schema from "./schema";

function createPostgresJsDb(sql: Sql) {
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
  });
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
