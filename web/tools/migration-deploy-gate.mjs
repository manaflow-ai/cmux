#!/usr/bin/env node
// Read-only deploy gate. A production Vercel build of the cmux or cmux-staging
// project does not go live until the database that deployment will use has
// recorded every migration in this build's web/db/migrations. While migrations
// are missing it re-reads the ledger (cloud-vm-migrate.yml applies them on the
// same push to main); if they are still missing when the wait ends, the build
// fails and Vercel keeps the previous deployment live.
//
// Migrations never run here. Each read opens one read-only transaction, reads
// drizzle.__drizzle_migrations names, and compares them with the local folder
// by name, the rule drizzle's getMigrationsToRun (and apply-migrations.mjs)
// uses to pick pending migrations, so an older-timestamp migration behind newer
// applied ones still counts as missing. Output names migrations and error
// codes only, never URLs, SQL, or driver messages.
//
// Lives in tools/ because the root .vercelignore drops every scripts/ dir.
// Adapted from Lawrence Chen's gate in https://github.com/manaflow-ai/cmux/pull/16582.
//
// Break-glass: set CMUX_MIGRATION_GATE_BREAK_GLASS to the commit SHA being
// deployed (at least 7 hex characters). It skips the check for that commit
// only, so a forgotten value cannot disable the gate for later commits.
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const BREAK_GLASS_ENV = "CMUX_MIGRATION_GATE_BREAK_GLASS";
export const WAIT_SECONDS_ENV = "CMUX_MIGRATION_GATE_WAIT_SECONDS";
// A normal cloud-vm-migrate.yml run takes about 2 minutes once it has runners;
// the wait also covers a runner queue. The gate runs after `next build`, so the
// build itself already gave the migration several minutes.
export const DEFAULT_WAIT_SECONDS = 20 * 60;
export const DEFAULT_POLL_SECONDS = 20;
export const MAX_WAIT_SECONDS = 30 * 60;

// Keep in sync with scripts/cloud-vm/projects.mjs (a test enforces it).
export const gatedProjects = {
  prj_kH8qcuoliyJ2TLI4vMM03rnNVzr4: { label: "production", projectName: "cmux", branch: "main" },
  prj_804LTAUdOwulMvEfcmfnU8bvGo3T: { label: "staging", projectName: "cmux-staging", branch: "staging" },
};

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
  if (!vercelEnv) {
    return { action: "fail", reason: "VERCEL_ENV is not set on a Vercel build, so the gate cannot tell a production build from a preview" };
  }
  if (vercelEnv !== "production") return { action: "skip", reason: `Vercel ${vercelEnv ?? "unknown"} environment` };
  const projectId = envValue(env, "VERCEL_PROJECT_ID");
  if (!projectId) {
    return {
      action: "fail",
      reason: "VERCEL_PROJECT_ID is not set on a Vercel production build, so the gate cannot tell whether this project serves the production database",
    };
  }
  const project = gatedProjects[projectId];
  // The docs channel projects build web/ with --prod and have no database.
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

export function localMigrationNames(webDir) {
  const { readMigrationFiles } = requireFromWeb("drizzle-orm/migrator");
  return readMigrationFiles({ migrationsFolder: path.join(webDir, "db/migrations") }).map((migration) => migration.name);
}

/** Wait budget in milliseconds; a malformed value falls back to the default rather than disabling the gate. */
export function resolveWaitMs(env) {
  const raw = envValue(env, WAIT_SECONDS_ENV);
  if (raw === undefined || !/^\d+$/.test(raw)) return DEFAULT_WAIT_SECONDS * 1000;
  // Stay well inside Vercel's 45-minute build limit, after `next build`.
  return Math.min(Number(raw), MAX_WAIT_SECONDS) * 1000;
}

// Driver messages can contain hosts, users, or SQL. Report only a stable code.
export function errorCode(error) {
  const code = error && typeof error === "object" ? error.code : undefined;
  if (typeof code === "string" && /^(?:[0-9A-Z]{5}|E[A-Z_]+)$/.test(code)) return code;
  const message = error instanceof Error ? error.message : "";
  if (/timeout/i.test(message)) return "timeout";
  return "unknown";
}

// Authentication (28xxx) and access or missing-ledger (42xxx) errors will not
// fix themselves while the build waits; anything else (connection refused,
// timeout, admin shutdown) is retried until the wait ends.
function isPermanentReadError(error) {
  return /^(?:28|42)[0-9A-Z]{3}$/.test(errorCode(error));
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

/** Reads applied migration names in one read-only transaction. */
export async function readAppliedMigrationNames(connectionString, { timeoutMs = 15_000 } = {}) {
  const { Client } = requireFromWeb("pg");
  return readOnce(Client, connectionString, timeoutMs);
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
  for (const line of [
    "Vercel keeps the previous deployment live; nothing was migrated by this build.",
    `Apply the migrations through .github/workflows/cloud-vm-migrate.yml (a push to main that adds one runs it; otherwise dispatch it with target=${label === "staging" ? "staging" : "production"}),`,
    `or from web/ run \`bun run cloud-vm:migrate -- ${label}\` (PlanetScale cmux-prod branch \`${branch}\`), then redeploy this commit.`,
    `Emergency only: set ${BREAK_GLASS_ENV}=<this commit SHA> on the project's production environment and redeploy.`,
  ]) error(`migration-deploy-gate: ${line}`);
}

/**
 * Reads the ledger until it has every required migration or the wait ends.
 * Returns 0 when the database is ready, 1 otherwise.
 */
async function waitForMigrations({ label, branch, connectionString, requiredNames, readAppliedNames, waitMs, pollMs, now, sleep, log, error }) {
  const deadline = now() + waitMs;
  let lastReported = "";
  for (;;) {
    let missing;
    let readFailure;
    try {
      missing = missingMigrationNames(requiredNames, await readAppliedNames(connectionString));
    } catch (readError) {
      readFailure = readError;
    }
    if (missing && missing.length === 0) {
      log(`migration-deploy-gate: ${label} database has all ${requiredNames.length} required migration(s).`);
      return 0;
    }
    const permanent = readFailure && isPermanentReadError(readFailure);
    const remainingMs = deadline - now();
    if (permanent || remainingMs <= 0) {
      if (readFailure) {
        error(`migration-deploy-gate: FAILED: could not read the ${label} migration ledger (${errorCode(readFailure)}); failing closed.`);
      } else {
        error(`migration-deploy-gate: FAILED: the ${label} database still lacks ${missing.length} migration(s) this code needs:`);
        for (const name of missing) error(`  ${name}`);
      }
      failureHelp(error, label, branch);
      return 1;
    }
    const report = readFailure ? `read failed (${errorCode(readFailure)})` : `missing ${missing.join(", ")}`;
    if (report !== lastReported) {
      log(`migration-deploy-gate: ${label} database not ready: ${report}. Waiting up to ${Math.ceil(remainingMs / 1000)}s for cloud-vm-migrate.yml to apply it.`);
      lastReported = report;
    }
    await sleep(Math.min(pollMs, remainingMs));
  }
}

/**
 * Runs the gate and returns the process exit code. Dependencies are injected
 * so the decision is testable without a database or a real clock.
 *
 * @param {{
 *   env?: Record<string, string | undefined>,
 *   webDir?: string,
 *   readAppliedNames?: (connectionString: string) => Promise<(string | null)[]>,
 *   now?: () => number,
 *   sleep?: (ms: number) => Promise<void>,
 *   pollMs?: number,
 *   log?: (line: string) => void,
 *   error?: (line: string) => void,
 * }} [options]
 * @returns {Promise<number>}
 */
export async function runMigrationGate({
  env = process.env,
  webDir = defaultWebDir,
  readAppliedNames = (connectionString) => readAppliedMigrationNames(connectionString),
  now = Date.now,
  sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  pollMs = DEFAULT_POLL_SECONDS * 1000,
  log = console.log,
  error = console.error,
} = {}) {
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
  // The same precedence as db/config.ts: the database this deployment will use.
  const connectionString = envValue(env, "DIRECT_DATABASE_URL") ?? envValue(env, "DATABASE_URL");
  if (!connectionString) {
    error(`migration-deploy-gate: FAILED: DATABASE_URL is not set for the ${mode.label} production build; failing closed.`);
    return 1;
  }
  return waitForMigrations({
    label: mode.label,
    branch: mode.branch,
    connectionString,
    requiredNames: localMigrationNames(webDir),
    readAppliedNames,
    waitMs: resolveWaitMs(env),
    pollMs,
    now,
    sleep,
    log,
    error,
  });
}

if (import.meta.main ?? process.argv[1] === fileURLToPath(import.meta.url)) {
  process.exitCode = await runMigrationGate();
}
