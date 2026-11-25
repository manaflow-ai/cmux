#!/usr/bin/env node
// Holds "contract" migrations back from the automatic run.
//
// cloud-vm-migrate.yml applies migrations on every push to main that adds one,
// while the previous deployment is still serving (the deploy gate in
// tools/migration-deploy-gate.mjs keeps the new code from going live until
// they are applied). That is safe for expand-only changes: new tables,
// nullable or defaulted columns, non-unique indexes, enum values, backfills. A
// statement that removes, reshapes or newly restricts something the live code
// may still read or write can break that live code the moment it applies, so
// the automatic run stops and a person dispatches the workflow after
// confirming nothing deployed depends on it.
//
// The check runs against the migrations the target database has not recorded
// (the set apply-migrations.mjs is about to apply), not the push's diff, so a
// migration held on one push is held again on every later push until a person
// applies it.
//
// This is a floor, not a substitute for review: it reads statements, not
// intent, and errs toward holding a migration back.
//
// Usage: bun scripts/cloud-vm/contract-migrations.mjs [web-dir] <staging|production>
// Reads the target's migration ledger read-only (CMUX_CLOUD_VM_ENV_SOURCE and
// DATABASE_URL as for cloud-vm:migrate). Exit 0 when every pending migration
// is expand-only, 1 when any is held (each statement is listed), 2 on a usage,
// configuration or read error.
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const identifier = String.raw`(?:"[^"]+"|[A-Za-z_][\w$]*)`;
const qualified = String.raw`(?:${identifier}\.)?(${identifier})`;
const createTablePattern = new RegExp(String.raw`^CREATE\s+(?:UNLOGGED\s+)?TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?${qualified}`, "i");
const alterTablePattern = new RegExp(String.raw`^ALTER\s+TABLE\s+(?:IF\s+EXISTS\s+)?(?:ONLY\s+)?${qualified}`, "i");
const uniqueIndexPattern = new RegExp(String.raw`^CREATE\s+UNIQUE\s+INDEX\b[\s\S]*?\bON\s+(?:ONLY\s+)?${qualified}`, "i");

// Every DROP holds except loosening a column (DROP DEFAULT, DROP NOT NULL).
// A dropped index or constraint can be the ON CONFLICT target of a live upsert.
const anyDrop = /\bDROP\b(?!\s+(?:DEFAULT|NOT\s+NULL)\b)/i;

// Rules that only matter for a table that existed before this migration.
const existingTableRules = [
  { test: (s) => /\bADD\s+(?:CONSTRAINT|UNIQUE|PRIMARY\s+KEY|FOREIGN\s+KEY|CHECK)\b/i.test(s), reason: "adds a constraint live writes may violate" },
  { test: (s) => uniqueIndexPattern.test(s), reason: "adds a unique index live writes may violate" },
  {
    test: (s) => /\bADD\s+(?:COLUMN\s+)?/i.test(s) && /\bNOT\s+NULL\b/i.test(s) && !/\bDEFAULT\b/i.test(s) && !/\bGENERATED\b/i.test(s) && !/\bADD\s+CONSTRAINT\b/i.test(s),
    reason: "adds a NOT NULL column without a default",
  },
];

const rules = [
  { test: (s) => anyDrop.test(s), reason: "drops something" },
  { test: (s) => /\bRENAME\b/i.test(s), reason: "renames something" },
  { test: (s) => new RegExp(String.raw`\bALTER\s+COLUMN\s+${identifier}\s+(?:SET\s+DATA\s+)?TYPE\b`, "i").test(s), reason: "changes a column type" },
  { test: (s) => /\bSET\s+NOT\s+NULL\b/i.test(s), reason: "makes a column NOT NULL" },
  { test: (s) => /^TRUNCATE\b/i.test(s), reason: "truncates a table" },
  { test: (s) => /^REVOKE\b/i.test(s), reason: "revokes a privilege" },
];

const unquote = (name) => name.replace(/^"|"$/g, "").toLowerCase();
const withoutComments = (sql) => sql.replace(/\/\*[\s\S]*?\*\//g, "").replace(/--[^\n]*/g, "");

/** Splits SQL into normalized statements; breakpoints first, since stripping comments would remove them. */
function statementsOf(sql) {
  const parts = Array.isArray(sql) ? sql : sql.split(/-->\s*statement-breakpoint/);
  return parts
    .flatMap((part) => withoutComments(part).split(";"))
    .map((statement) => statement.replace(/\s+/g, " ").trim())
    .filter(Boolean);
}

function targetTable(statement) {
  const match = statement.match(alterTablePattern) ?? statement.match(uniqueIndexPattern);
  return match ? unquote(match[1]) : undefined;
}

/**
 * Contract findings in one migration's SQL (a string, or drizzle's list of
 * statements); empty when it is expand-only.
 */
export function contractStatements(sql) {
  const statements = statementsOf(sql);
  const created = new Set(statements.map((s) => s.match(createTablePattern)?.[1]).filter(Boolean).map(unquote));
  const findings = [];
  for (const statement of statements) {
    let rule = rules.find(({ test }) => test(statement));
    if (!rule) {
      const table = targetTable(statement);
      if (table && !created.has(table)) rule = existingTableRules.find(({ test }) => test(statement));
    }
    if (rule) findings.push({ reason: rule.reason, statement: statement.slice(0, 160) });
  }
  return findings;
}

/**
 * Prints the verdict for the given pending migrations and returns the exit
 * code. `migrations` are drizzle migration objects ({ name, sql }).
 */
export function reportPending(label, migrations, { log = console.log, error = console.error } = {}) {
  if (migrations.length === 0) {
    log(`contract-migrations: ${label} has no pending migrations.`);
    return 0;
  }
  let held = 0;
  for (const migration of migrations) {
    const findings = contractStatements(migration.sql);
    if (findings.length === 0) {
      log(`contract-migrations: ${migration.name}: expand-only`);
      continue;
    }
    held += 1;
    for (const finding of findings) error(`contract-migrations: ${migration.name}: ${finding.reason}: ${finding.statement}`);
  }
  if (held === 0) return 0;
  error(`contract-migrations: ${held} pending ${label} migration(s) can break the deployment that is live while they apply, so the automatic run stops here.`);
  error("contract-migrations: Confirm no deployed code still depends on what they change, then dispatch cloud-vm-migrate.yml with target=production.");
  return 1;
}

/** Applied names from the ledger, read-only; an absent ledger means nothing is applied. */
export async function readLedgerNames(client) {
  await client.query("begin read only");
  try {
    const exists = await client.query("select to_regclass('drizzle.__drizzle_migrations') is not null as present");
    if (!exists.rows[0]?.present) return [];
    const result = await client.query("select name from drizzle.__drizzle_migrations");
    return result.rows.map((row) => row.name);
  } finally {
    await client.query("rollback");
  }
}

/** The local migrations the database has not recorded, by drizzle's name rule (as apply-migrations.mjs). */
export function pendingMigrations(webDir, appliedNames, { migrationsFolder } = {}) {
  const requireFromWeb = createRequire(path.join(webDir, "package.json"));
  const { readMigrationFiles } = requireFromWeb("drizzle-orm/migrator");
  const { getMigrationsToRun } = requireFromWeb("drizzle-orm/migrator.utils");
  const local = readMigrationFiles({ migrationsFolder: migrationsFolder ?? path.join(webDir, "db/migrations") });
  return getMigrationsToRun({ localMigrations: local, dbMigrations: appliedNames.map((name) => ({ name })) });
}

async function cli(args) {
  const { loadTargetEnv, parseWebDirAndTarget } = await import("./projects.mjs");
  const { createPlanetScaleOperatorPool, PlanetScaleOperatorConfigError } = await import("./planetscale-operator.mjs");
  const usage = "Usage: contract-migrations.mjs [web-dir] <staging|production>";
  const { webDir, project, rest } = parseWebDirAndTarget(args, usage);
  if (rest.length > 0) {
    console.error(usage);
    return 2;
  }
  let applied;
  try {
    const pool = createPlanetScaleOperatorPool(webDir, loadTargetEnv(project), project.projectName);
    try {
      const client = await pool.connect();
      try {
        applied = await readLedgerNames(client);
      } finally {
        client.release();
      }
    } finally {
      await pool.end();
    }
  } catch (readError) {
    if (readError instanceof PlanetScaleOperatorConfigError) {
      console.error(readError.message);
    } else {
      const code = typeof readError?.code === "string" ? readError.code : "unknown_code";
      console.error(`contract-migrations: could not read the ${project.label} migration ledger (${code}); stopping.`);
    }
    return 2;
  }
  return reportPending(project.label, pendingMigrations(webDir, applied));
}

if (import.meta.main ?? process.argv[1] === fileURLToPath(import.meta.url)) {
  process.exitCode = await cli(process.argv.slice(2));
}
