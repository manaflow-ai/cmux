// Compares the migrations in a source tree with a database's Drizzle ledger.
//
// Merging main deploys web/ to production and the deploy never migrates, so a
// migration that is on main but absent from production's ledger is code that
// may already be querying a missing table or column. Everything that decides
// lives here as pure functions; check-migration-ledger.mjs only fetches.
import { createHash } from "node:crypto";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import path from "node:path";

export const LEDGER_EXIT = Object.freeze({
  ok: 0,
  // The tree holds a migration the database has not applied.
  drift: 1,
  usage: 2,
  // The ledger could not be read. A gate that cannot see must not pass.
  unverified: 3,
});

export const LEDGER_MODES = Object.freeze(["gate", "pull-request", "advisory"]);

export const MIGRATE_WORKFLOW = "cloud-vm-migrate.yml";

/**
 * Local migrations exactly as drizzle-orm 1.0's readMigrationFiles sees them:
 * every subdirectory holding a migration.sql, sorted by name, hashed as the
 * sha256 of the whole file.
 */
export function readLocalMigrations(migrationsDir) {
  return readdirSync(migrationsDir)
    .map((name) => ({ name, file: path.join(migrationsDir, name, "migration.sql") }))
    .filter((entry) => existsSync(entry.file))
    .sort((a, b) => a.name.localeCompare(b.name))
    .map(({ name, file }) => ({ name, hash: createHash("sha256").update(readFileSync(file).toString()).digest("hex") }));
}

/**
 * Drizzle 1.0 selects pending migrations by name (getMigrationsToRun), not by
 * the newest applied timestamp, so an older name missing from the ledger is
 * still pending and will run on the next migrate.
 *
 * `baseNames`, when given, marks which pending migrations the change itself
 * introduces; without it `introduced` is null.
 */
export function compareLedger({ local, applied, baseNames }) {
  const appliedByName = new Map();
  for (const row of applied) {
    if (typeof row.name === "string") appliedByName.set(row.name, row.hash);
  }
  const base = baseNames ? new Set(baseNames) : null;
  const localNames = new Set(local.map((migration) => migration.name));
  const pending = [];
  const hashMismatches = [];
  for (const migration of local) {
    if (!appliedByName.has(migration.name)) {
      pending.push({ name: migration.name, introduced: base ? !base.has(migration.name) : null });
    } else if (appliedByName.get(migration.name) !== migration.hash) {
      hashMismatches.push(migration.name);
    }
  }
  const appliedOnly = [...appliedByName.keys()].filter((name) => !localNames.has(name)).sort();
  return { pending, hashMismatches, appliedOnly };
}

/**
 * gate: any pending migration fails. Used for the merge queue and main,
 * where the tree is exactly what will deploy.
 * pull-request: only migrations the pull request adds fail; drift that is
 * already on the base branch warns, because the pull request cannot fix it.
 * advisory: never fails (staging).
 */
export function ledgerVerdict(result, mode) {
  if (!LEDGER_MODES.includes(mode)) throw new Error(`unknown ledger mode ${mode}`);
  const failing = mode === "advisory" ? [] :
    mode === "pull-request" ? result.pending.filter((migration) => migration.introduced !== false) :
    result.pending;
  if (failing.length > 0) return { status: "fail", exitCode: LEDGER_EXIT.drift };
  if (result.pending.length > 0 || result.hashMismatches.length > 0) return { status: "warn", exitCode: LEDGER_EXIT.ok };
  return { status: "ok", exitCode: LEDGER_EXIT.ok };
}

function plural(count, word) {
  return `${count} ${word}${count === 1 ? "" : "s"}`;
}

function pendingLabel(migration) {
  if (migration.introduced === true) return `${migration.name} (added by this change)`;
  if (migration.introduced === false) return `${migration.name} (already on the base branch)`;
  return migration.name;
}

/** The operator sequence that makes the check pass, in the order it must run. */
export function operatorSequence({ sourceRef, repository }) {
  const source = sourceRef ?? "<pull request head SHA or number>";
  const repo = repository ? ` --repo ${repository}` : "";
  return [
    "Merging deploys web/ to production at once, and deploys never run migrations. Apply first:",
    `  1. Staging: gh workflow run ${MIGRATE_WORKFLOW}${repo} --ref main -f target=staging -f source_ref=${source}`,
    "     and confirm the run is green.",
    `  2. Production: gh workflow run ${MIGRATE_WORKFLOW}${repo} --ref main -f target=production -f source_ref=${source}`,
    "     A cloud-vm-production reviewer approves the job after reading the SQL in the run summary.",
    "     (Operator alternative from a checkout of that commit: cd web && bun run cloud-vm:migrate -- staging,",
    "     then bun run cloud-vm:migrate -- production.)",
    "  3. Then re-run this check, or re-add the pull request to the merge queue.",
    "Migrations must be additive and backward compatible: production runs the old code against the new schema",
    "until the merge deploys.",
  ];
}

export function formatLedgerReport({ target, result, verdict, sourceRef, repository }) {
  const lines = [];
  if (result.pending.length === 0) {
    lines.push(`${target} has every migration in this tree.`);
  } else {
    lines.push(`${target} is missing ${plural(result.pending.length, "migration")} from this tree:`);
    for (const migration of result.pending) lines.push(`  - ${pendingLabel(migration)}`);
  }
  if (result.hashMismatches.length > 0) {
    lines.push(
      `${plural(result.hashMismatches.length, "migration")} changed after ${target} applied them. Drizzle never re-runs an applied`,
      "name, so the edit will not reach this database; add a new migration instead:",
      ...result.hashMismatches.map((name) => `  - ${name}`),
    );
  }
  if (result.appliedOnly.length > 0) {
    lines.push(
      `${target} also records ${plural(result.appliedOnly.length, "migration")} that this tree lacks (applied from an unmerged branch):`,
      ...result.appliedOnly.map((name) => `  - ${name}`),
    );
  }
  if (verdict.status === "fail" || result.pending.length > 0) lines.push("", ...operatorSequence({ sourceRef, repository }));
  return lines.join("\n");
}

/**
 * Which source migration folders an operator run may add to the base tree.
 * Each argument maps folder name -> Map(file name -> git blob id). A folder
 * that exists on both sides with different content is a conflict: drizzle
 * would skip it by name, so the edit could never reach any database.
 */
export function planMigrationOverlay({ base, source }) {
  const add = [];
  const conflicts = [];
  for (const [name, files] of source) {
    const baseFiles = base.get(name);
    if (!baseFiles) {
      add.push(name);
      continue;
    }
    const same = baseFiles.size === files.size && [...files].every(([file, blob]) => baseFiles.get(file) === blob);
    if (!same) conflicts.push(name);
  }
  return { add: add.sort(), conflicts: conflicts.sort() };
}
