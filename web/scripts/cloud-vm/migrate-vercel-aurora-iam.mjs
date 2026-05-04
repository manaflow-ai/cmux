#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import path from "node:path";
import {
  loadTargetEnv,
  parseBoolean,
  parseWebDirAndTarget,
  requireEnvKeys,
} from "./projects.mjs";

const usage = "Usage: migrate-vercel-aurora-iam.mjs [web-dir] <staging|production>";
const { webDir, project } = parseWebDirAndTarget(process.argv.slice(2), usage);
const pkgPath = path.join(webDir, "package.json");
const migrationsFolder = path.join(webDir, "db/migrations");
const requireFromWeb = createRequire(pkgPath);
const { Pool } = requireFromWeb("pg");
const { drizzle } = requireFromWeb("drizzle-orm/node-postgres");
const { migrate } = requireFromWeb("drizzle-orm/node-postgres/migrator");

try {
  const env = loadTargetEnv(project);
  requireEnvKeys(env, ["AWS_REGION", "PGHOST", "PGPORT", "PGUSER", "PGDATABASE"], `${project.projectName} migration`);
  if ((env.CMUX_DB_SSL_CA_PEM || env.CMUX_DB_SSL_CA_PEM_BASE64) && process.env.CMUX_ALLOW_DB_CA_OVERRIDE !== "1") {
    throw new Error(
      "CMUX_DB_SSL_CA_PEM(_BASE64) is set. Current Vercel Aurora RDS certs chain to Amazon Root CA 1, so Node's default trust store should be used. Remove the override, redeploy, then retry. Set CMUX_ALLOW_DB_CA_OVERRIDE=1 only for a verified private CA.",
    );
  }
  const pgPort = Number(env.PGPORT);
  if (!Number.isInteger(pgPort) || pgPort <= 0 || pgPort > 65535) {
    throw new Error(`invalid PGPORT for ${project.projectName} migration: ${env.PGPORT}`);
  }

  const authToken = execFileSync(process.env.AWS_CLI ?? "aws", [
    "rds",
    "generate-db-auth-token",
    "--hostname",
    env.PGHOST,
    "--port",
    String(pgPort),
    "--region",
    env.AWS_REGION,
    "--username",
    env.PGUSER,
  ], { encoding: "utf8" }).trim();

  const pool = new Pool({
    host: env.PGHOST,
    port: pgPort,
    user: env.PGUSER,
    database: env.PGDATABASE,
    password: authToken,
    ssl: { rejectUnauthorized: parseBoolean(env.CMUX_DB_SSL_REJECT_UNAUTHORIZED, true) },
    max: 1,
  });

  try {
    const db = drizzle({ client: pool });
    await migrate(db, { migrationsFolder });
  } finally {
    await pool.end();
  }

  console.log(`${project.label} migration applied`);
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}
