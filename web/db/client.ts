import { Signer } from "@aws-sdk/rds-signer";
import { awsCredentialsProvider } from "@vercel/oidc-aws-credentials-provider";
import { attachDatabasePool } from "@vercel/functions";
import { drizzle as drizzleNodePg } from "drizzle-orm/node-postgres";
import { drizzle } from "drizzle-orm/postgres-js";
import { Pool } from "pg";
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

  return new Pool({
    host: config.host,
    port: config.port,
    user: config.user,
    database: config.database,
    password: () => signer.getAuthToken(),
    ssl: {
      rejectUnauthorized: config.sslRejectUnauthorized,
      ...(config.sslCaPem ? { ca: config.sslCaPem } : {}),
    },
    max: config.poolMax,
    ...overrides,
  });
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
  const client = (cloudDb() as unknown as { $client: unknown }).$client;
  if (isPostgresJsClient(client)) {
    const query = client.unsafe("select 1");
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
    } finally {
      signal.removeEventListener("abort", cancel);
    }
    return;
  }

  if (isNodePostgresPool(client)) {
    if (signal.aborted) throw new Error("database probe aborted");
    // `query_timeout` is a node-postgres QueryConfig field. The installed
    // @types/pg version omits it, so keep the narrow cast local to this probe.
    await client.query({
      text: "select 1",
      query_timeout: Math.max(1, Math.floor(timeoutMs)),
    });
    if (signal.aborted) throw new Error("database probe aborted");
    return;
  }

  throw new Error("unsupported cloud database client");
}

function isPostgresJsClient(value: unknown): value is Sql {
  return typeof value === "function" &&
    typeof (value as { unsafe?: unknown }).unsafe === "function";
}

type NodePostgresPool = {
  query: (config: { text: string; query_timeout: number }) => Promise<unknown>;
};

function isNodePostgresPool(value: unknown): value is NodePostgresPool {
  return typeof value === "object" && value !== null &&
    typeof (value as { query?: unknown }).query === "function";
}

export async function closeCloudDbForTests(): Promise<void> {
  const state = globalForDb.__cmuxCloudDb;
  globalForDb.__cmuxCloudDb = undefined;
  await state?.close();
}
