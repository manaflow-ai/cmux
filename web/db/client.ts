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

export function createAwsRdsIamPool(config: CloudDbAwsRdsIamConfig): Pool {
  // Vercel supplies a short-lived OIDC token in deployed functions. The
  // operator migration command may instead run under an already-authenticated
  // AWS identity; in that case let the AWS SDK use its standard credential
  // chain rather than requiring a synthetic Vercel token.
  const credentials = process.env.VERCEL_OIDC_TOKEN
    ? awsCredentialsProvider({
      roleArn: config.awsRoleArn,
      clientConfig: { region: config.awsRegion },
    })
    : undefined;
  const signer = new Signer({
    hostname: config.host,
    port: config.port,
    username: config.user,
    region: config.awsRegion,
    ...(credentials ? { credentials } : {}),
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

export async function closeCloudDbForTests(): Promise<void> {
  const state = globalForDb.__cmuxCloudDb;
  globalForDb.__cmuxCloudDb = undefined;
  await state?.close();
}
