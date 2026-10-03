#!/usr/bin/env node
// Read-only deploy gate: a production Vercel build of the cmux or cmux-staging
// project fails, so Vercel keeps the previous deployment live, when that
// project's database lacks any migration in this build's web/db/migrations.
//
// Migrations never run here. The gate opens one read-only transaction, reads
// drizzle.__drizzle_migrations names, and compares them with the local folder
// by name, the same rule drizzle's getMigrationsToRun uses to pick pending
// migrations (so an older-timestamp migration behind newer applied ones is
// still detected). It prints migration names only, never URLs, SQL, or driver
// messages.
//
// Lives in tools/ because the root .vercelignore drops every scripts/ dir.
//
// Usage:
//   bun tools/migration-deploy-gate.mjs
//     Build mode. Decides from the Vercel environment; a no-op outside the
//     production environment of the two gated projects.
//   bun tools/migration-deploy-gate.mjs --label <name> --database-url-env <VAR> --names <a,b>
//     Explicit read-only check of the named migrations against the URL in
//     $VAR (the pull-request readiness workflow uses this).
//
// Break-glass: set CMUX_MIGRATION_GATE_BREAK_GLASS to the commit SHA being
// deployed (at least 7 hex characters). It skips the check for that commit
// only, so a forgotten value cannot disable the gate for later commits.
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const BREAK_GLASS_ENV = "CMUX_MIGRATION_GATE_BREAK_GLASS";

// Keep in sync with scripts/cloud-vm/projects.mjs (a test enforces it).
export const gatedProjects = {
  prj_kH8qcuoliyJ2TLI4vMM03rnNVzr4: { label: "production", projectName: "cmux", branch: "main" },
  prj_804LTAUdOwulMvEfcmfnU8bvGo3T: { label: "staging", projectName: "cmux-staging", branch: "staging" },
};

const migrationNamePattern = /^\d{14}_[A-Za-z0-9_]+$/;
const defaultWebDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const requireFromWeb = createRequire(path.join(defaultWebDir, "package.json"));

function envValue(env, key) {
  const value = env[key]?.trim();
  return value ? value : undefined;
}

/** Decides whether this build must check its database. Pure; reads only env. */
export function resolveGateMode(env) {
  if (envValue(env, "VERCEL") !== "1") return { action: "skip", reason: "not a Vercel build" };
  const vercelEnv = envValue(env, "VERCEL_ENV");
  if (vercelEnv !== "production") return { action: "skip", reason: `Vercel ${vercelEnv ?? "unknown"} environment` };
  const projectId = envValue(env, "VERCEL_PROJECT_ID");
  if (!projectId) {
    return {
      action: "fail",
      reason: "VERCEL_PROJECT_ID is not set on a Vercel production build, so the gate cannot tell whether this project serves the production database",
    };
  }
  const project = gatedProjects[projectId];
  if (!project) return { action: "skip", reason: `project ${projectId} is not a gated database project` };
  return { action: "check", ...project };
}

/** Required names the database lacks, by drizzle's own name-based pending rule. */
export function missingMigrationNames(requiredNames, appliedNames) {
  const { getMigrationsToRun } = requireFromWeb("drizzle-orm/migrator.utils");
  const pending = getMigrationsToRun({
    localMigrations: requiredNames.map((name) => ({ name })),
    dbMigrations: appliedNames.map((name) => ({ name })),
  });
  return pending.map((migration) => migration.name);
}

function localMigrationNames(webDir) {
  const { readMigrationFiles } = requireFromWeb("drizzle-orm/migrator");
  return readMigrationFiles({ migrationsFolder: path.join(webDir, "db/migrations") }).map((migration) => migration.name);
}

// Driver messages can contain hosts, users, or SQL. Report only a stable code.
function errorCode(error) {
  const code = error && typeof error === "object" ? error.code : undefined;
  if (typeof code === "string" && /^(?:[0-9A-Z]{5}|E[A-Z_]+)$/.test(code)) return code;
  const message = error instanceof Error ? error.message : "";
  if (/timeout/i.test(message)) return "timeout";
  return "unknown";
}

async function readOnce(Client, connectionString, timeoutMs) {
  const client = new Client({ connectionString, connectionTimeoutMillis: timeoutMs, query_timeout: timeoutMs });
  // An idle-connection error after a failed connect must not crash the build
  // with a message that can contain the URL.
  client.on("error", () => {});
  await client.connect();
  try {
    await client.query("begin read only");
    try {
      const result = await client.query("select name from drizzle.__drizzle_migrations");
      return result.rows.map((row) => row.name);
    } finally {
      await client.query("rollback");
    }
  } finally {
    await client.end().catch(() => {});
  }
}

/**
 * Reads applied migration names in one read-only transaction. Retries only
 * transient connection failures; a missing ledger or permission error fails
 * at once.
 */
export async function readAppliedMigrationNames(connectionString, { attempts = 3, timeoutMs = 15_000, retryDelayMs = 2_000 } = {}) {
  const { Client } = requireFromWeb("pg");
  let lastError;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      return await readOnce(Client, connectionString, timeoutMs);
    } catch (error) {
      lastError = error;
      if (/^[0-9A-Z]{5}$/.test(errorCode(error)) || attempt === attempts) break;
      await new Promise((resolve) => setTimeout(resolve, retryDelayMs));
    }
  }
  throw lastError;
}

function breakGlassDecision(env) {
  const value = envValue(env, BREAK_GLASS_ENV);
  if (!value) return { active: false };
  const sha = envValue(env, "VERCEL_GIT_COMMIT_SHA")?.toLowerCase();
  const normalized = value.toLowerCase();
  if (!/^[0-9a-f]{7,40}$/.test(normalized)) {
    return { active: false, refusal: `${BREAK_GLASS_ENV} must be the deployed commit SHA (7 to 40 hex characters); ignoring it.` };
  }
  if (!sha || !sha.startsWith(normalized)) {
    return { active: false, refusal: `${BREAK_GLASS_ENV} names commit ${normalized}, but this build is ${sha ?? "an unknown commit"}; ignoring it.` };
  }
  return { active: true };
}

function printBreakGlass(log, label) {
  const bar = "!".repeat(72);
  for (const line of [
    bar,
    `BREAK-GLASS: ${BREAK_GLASS_ENV} matches this commit.`,
    `The ${label} migration deploy gate is SKIPPED. This deployment may run code`,
    "against a database that lacks its migrations. Remove the variable after this",
    "deployment and record why it was used.",
    bar,
  ]) log(line);
}

function failureHelp(error, label, branch) {
  const lines = [
    `Apply the reviewed migrations first: from web/, run \`bun run cloud-vm:migrate -- ${label}\``,
    branch ? `(PlanetScale cmux-prod branch \`${branch}\`), then redeploy.` : "then rerun this check.",
  ];
  if (branch) {
    lines.push(`Emergency only: set ${BREAK_GLASS_ENV}=<this commit SHA> on the project's production environment and redeploy.`);
  }
  for (const line of lines) error(`migration-deploy-gate: ${line}`);
}

async function checkNames({ label, branch, connectionString, requiredNames, readAppliedNames, log, error }) {
  let applied;
  try {
    applied = await readAppliedNames(connectionString);
  } catch (readError) {
    error(`migration-deploy-gate: FAILED: could not read the ${label} migration ledger (${errorCode(readError)}); failing closed.`);
    if (branch) error(`migration-deploy-gate: If the database is down and this deploy must ship, use ${BREAK_GLASS_ENV}=<this commit SHA>.`);
    return 1;
  }
  const missing = missingMigrationNames(requiredNames, applied);
  if (missing.length === 0) {
    log(`migration-deploy-gate: ${label} database has all ${requiredNames.length} required migration(s).`);
    return 0;
  }
  error(`migration-deploy-gate: FAILED: the ${label} database lacks ${missing.length} migration(s) this code needs:`);
  for (const name of missing) error(`  ${name}`);
  failureHelp(error, label, branch);
  return 1;
}

async function runExplicit({ env, explicit, readAppliedNames, log, error }) {
  const invalid = explicit.names.filter((name) => !migrationNamePattern.test(name));
  if (invalid.length > 0 || explicit.names.length === 0) {
    error("migration-deploy-gate: --names must list migration folder names (YYYYMMDDHHMMSS_name).");
    return 1;
  }
  const connectionString = envValue(env, explicit.databaseUrlEnv);
  if (!connectionString) {
    error(`migration-deploy-gate: FAILED: ${explicit.databaseUrlEnv} is not set; cannot verify the ${explicit.label} database.`);
    return 1;
  }
  return checkNames({ label: explicit.label, connectionString, requiredNames: explicit.names, readAppliedNames, log, error });
}

/**
 * Runs the gate and returns the process exit code. Dependencies are injected
 * so the decision is testable without a database.
 *
 * @param {{
 *   env?: Record<string, string | undefined>,
 *   webDir?: string,
 *   explicit?: { label: string, databaseUrlEnv: string, names: string[] },
 *   readAppliedNames?: (connectionString: string) => Promise<(string | null)[]>,
 *   log?: (line: string) => void,
 *   error?: (line: string) => void,
 * }} [options]
 * @returns {Promise<number>}
 */
export async function runMigrationGate({
  env = process.env,
  webDir = defaultWebDir,
  explicit,
  readAppliedNames = (connectionString) => readAppliedMigrationNames(connectionString),
  log = console.log,
  error = console.error,
} = {}) {
  if (explicit) return runExplicit({ env, explicit, readAppliedNames, log, error });

  const mode = resolveGateMode(env);
  if (mode.action === "skip") {
    log(`migration-deploy-gate: skipped (${mode.reason}).`);
    return 0;
  }
  const breakGlass = breakGlassDecision(env);
  if (breakGlass.active) {
    printBreakGlass(error, mode.label ?? "unidentified");
    return 0;
  }
  if (breakGlass.refusal) error(`migration-deploy-gate: ${breakGlass.refusal}`);
  if (mode.action === "fail") {
    error(`migration-deploy-gate: FAILED: ${mode.reason}.`);
    return 1;
  }
  const connectionString = envValue(env, "DIRECT_DATABASE_URL") ?? envValue(env, "DATABASE_URL");
  if (!connectionString) {
    error(`migration-deploy-gate: FAILED: DATABASE_URL is not set for the ${mode.label} production build; failing closed.`);
    return 1;
  }
  return checkNames({
    label: mode.label,
    branch: mode.branch,
    connectionString,
    requiredNames: localMigrationNames(webDir),
    readAppliedNames,
    log,
    error,
  });
}

function optionValue(args, name) {
  const index = args.indexOf(name);
  return index < 0 ? undefined : args[index + 1];
}

function parseArgs(args) {
  if (args.length === 0) return {};
  const label = optionValue(args, "--label");
  const databaseUrlEnv = optionValue(args, "--database-url-env");
  const names = optionValue(args, "--names");
  if (!label || !databaseUrlEnv || names === undefined || args.length !== 6) {
    throw new Error("usage: migration-deploy-gate.mjs [--label <name> --database-url-env <VAR> --names <a,b>]");
  }
  return { explicit: { label, databaseUrlEnv, names: names.split(",").map((name) => name.trim()).filter(Boolean) } };
}

if (import.meta.main ?? process.argv[1] === fileURLToPath(import.meta.url)) {
  let options;
  try {
    options = parseArgs(process.argv.slice(2));
  } catch (usageError) {
    console.error(usageError.message);
    process.exit(2);
  }
  process.exitCode = await runMigrationGate(options);
}
