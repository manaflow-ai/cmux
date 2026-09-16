import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import path from "node:path";
import { parseBoolean, requireEnvKeys } from "./projects.mjs";

// Uses the operator AWS credential chain, never a pulled Vercel OIDC token.
export function createAuroraOperatorPool(webDir, env, label) {
  const { Pool } = createRequire(path.join(webDir, "package.json"))("pg");
  requireEnvKeys(env, ["AWS_REGION", "PGHOST", "PGPORT", "PGUSER", "PGDATABASE"], `${label} maintenance`);
  if ((env.CMUX_DB_SSL_CA_PEM || env.CMUX_DB_SSL_CA_PEM_BASE64) && process.env.CMUX_ALLOW_DB_CA_OVERRIDE !== "1") {
    throw new Error(
      "CMUX_DB_SSL_CA_PEM(_BASE64) is set. Current Vercel Aurora RDS certs chain to Amazon Root CA 1, so Node's default trust store should be used. Remove the override, redeploy, then retry. Set CMUX_ALLOW_DB_CA_OVERRIDE=1 only for a verified private CA.",
    );
  }
  const pgPort = Number(env.PGPORT);
  if (!Number.isInteger(pgPort) || pgPort <= 0 || pgPort > 65535) {
    throw new Error(`invalid PGPORT for ${label} maintenance: ${env.PGPORT}`);
  }
  if (!parseBoolean(env.CMUX_DB_SSL_REJECT_UNAUTHORIZED, true)) {
    throw new Error("Operator database connections require certificate validation");
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

  return new Pool({
    host: env.PGHOST,
    port: pgPort,
    user: env.PGUSER,
    database: env.PGDATABASE,
    password: authToken,
    ssl: { rejectUnauthorized: true },
    max: 1,
    connectionTimeoutMillis: 15_000,
  });
}
