import { createRequire } from "node:module";
import path from "node:path";

export class PlanetScaleOperatorConfigError extends Error {}

/** Operator jobs use a direct, certificate-verified PlanetScale connection. */
export function planetScaleOperatorOptions(env, label) {
  const raw = env.DIRECT_DATABASE_URL?.trim() || env.DATABASE_URL?.trim();
  const fail = (message) => { throw new PlanetScaleOperatorConfigError(`${label}: ${message}`); };
  if (!raw) fail("DATABASE_URL or DIRECT_DATABASE_URL is required for PlanetScale maintenance");
  let url;
  try { url = new URL(raw); } catch { fail("invalid database URL"); }
  if (!["postgres:", "postgresql:"].includes(url.protocol)) fail("expected a PostgreSQL URL");
  if (!url.hostname.endsWith(".pg.psdb.cloud")) fail("expected a PlanetScale Postgres endpoint");
  if (!url.username || !url.password) fail("database URL must contain operator credentials");
  if (url.port && !["5432", "6432"].includes(url.port)) fail("unsupported PlanetScale port");
  const sslmode = url.searchParams.get("sslmode");
  if (sslmode && !["require", "verify-ca", "verify-full"].includes(sslmode)) {
    fail("operator connections require certificate verification");
  }
  if (env.CMUX_DB_SSL_REJECT_UNAUTHORIZED &&
      !["true", "1", "yes", "on"].includes(env.CMUX_DB_SSL_REJECT_UNAUTHORIZED.trim().toLowerCase())) {
    fail("operator connections require certificate verification");
  }
  // The deployed URL uses PgBouncer (6432). Migrations and cleanup jobs need
  // the same branch's direct port for session settings and advisory locks.
  url.port = "5432";
  // pg parses query parameters after Pool options. Operator connections own
  // their TLS and endpoint policy; URL parameters must not override either.
  url.search = "";
  return {
    connectionString: url.href,
    ssl: { rejectUnauthorized: true },
    max: 1,
    connectionTimeoutMillis: 15_000,
  };
}

export function createPlanetScaleOperatorPool(webDir, env, label) {
  const options = planetScaleOperatorOptions(env, label);
  const { Pool } = createRequire(path.join(webDir, "package.json"))("pg");
  return new Pool(options);
}
