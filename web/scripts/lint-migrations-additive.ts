/**
 * Classifies Cloud VM migrations (web/db/migrations/<name>/migration.sql) as
 * additive or destructive, and fails CI for destructive migrations that are
 * not explicitly acknowledged.
 *
 * Web code auto-deploys to Vercel on merge, while database migrations are
 * applied separately through the cloud-vm-migrate workflow. During that
 * window the OLD schema serves NEW code and, after the migration, the NEW
 * schema can serve OLD code. Additive statements (new tables, nullable or
 * defaulted columns, new indexes, new enum values) are safe in both
 * directions; destructive ones (DROP, type changes, NOT NULL on existing
 * columns, renames, data backfills) are not, so they need a human to plan the
 * deploy/migrate ordering.
 *
 * A destructive migration is acknowledged in the migration file itself with:
 *
 *   -- cmux:allow-destructive: <why this is safe to apply>
 *
 * which downgrades the failure to a warning. Unrecognized statements fail
 * closed as destructive.
 *
 * Usage: bun scripts/lint-migrations-additive.ts [--all]
 *   --all lints every migration, ignoring the LINT_BASELINE grandfather cut.
 */

import { existsSync, readdirSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

/**
 * Migrations up to and including this name predate the linter and are
 * grandfathered; editing an applied migration's sql would change its drizzle
 * hash, so they must stay byte-identical. Only names sorting after this are
 * linted.
 */
export const LINT_BASELINE = "20260824010000_cloud_vm_preview_leases";

export const ALLOW_DESTRUCTIVE_MARKER = "cmux:allow-destructive:";

export type Finding = {
  readonly statement: string;
  readonly reason: string;
};

/** Strips comments and splits on top-level semicolons, respecting single
 * quotes, double quotes, and (tagged) dollar quoting, so DO $$..$$ bodies and
 * string literals never split or hide statements. */
export function splitSqlStatements(sqlText: string): string[] {
  const text = sqlText.replace(/^\uFEFF/, "").replace(/\r\n/g, "\n");
  const statements: string[] = [];
  let current = "";
  let index = 0;

  while (index < text.length) {
    const rest = text.slice(index);

    // Line comment (includes drizzle's `--> statement-breakpoint`).
    if (rest.startsWith("--")) {
      const end = text.indexOf("\n", index);
      index = end === -1 ? text.length : end + 1;
      current += " ";
      continue;
    }
    // Block comment; PostgreSQL block comments nest.
    if (rest.startsWith("/*")) {
      let depth = 1;
      let scan = index + 2;
      while (scan < text.length && depth > 0) {
        if (text.startsWith("/*", scan)) {
          depth += 1;
          scan += 2;
        } else if (text.startsWith("*/", scan)) {
          depth -= 1;
          scan += 2;
        } else {
          scan += 1;
        }
      }
      index = scan;
      current += " ";
      continue;
    }
    // Single-quoted literal ('' escapes a quote).
    if (text[index] === "'") {
      let scan = index + 1;
      while (scan < text.length) {
        if (text[scan] === "'" && text[scan + 1] === "'") {
          scan += 2;
        } else if (text[scan] === "'") {
          scan += 1;
          break;
        } else {
          scan += 1;
        }
      }
      current += text.slice(index, scan);
      index = scan;
      continue;
    }
    // Double-quoted identifier.
    if (text[index] === '"') {
      let scan = index + 1;
      while (scan < text.length && text[scan] !== '"') scan += 1;
      scan = Math.min(scan + 1, text.length);
      current += text.slice(index, scan);
      index = scan;
      continue;
    }
    // Dollar quoting: $$ ... $$ or $tag$ ... $tag$.
    if (text[index] === "$") {
      const tagMatch = /^\$[A-Za-z_][A-Za-z0-9_]*\$|^\$\$/.exec(rest);
      if (tagMatch) {
        const tag = tagMatch[0];
        const close = text.indexOf(tag, index + tag.length);
        const end = close === -1 ? text.length : close + tag.length;
        current += text.slice(index, end);
        index = end;
        continue;
      }
    }
    if (text[index] === ";") {
      statements.push(current);
      current = "";
      index += 1;
      continue;
    }
    current += text[index];
    index += 1;
  }
  statements.push(current);

  return statements.map((statement) => statement.trim()).filter((statement) => statement.length > 0);
}

function normalize(statement: string): string {
  return statement.replace(/\s+/g, " ").trim().toLowerCase();
}

/** Splits the action list of an ALTER TABLE statement on top-level commas
 * (commas inside parens, e.g. numeric(10,2) or default exprs, do not split). */
function splitAlterTableActions(actions: string): string[] {
  const parts: string[] = [];
  let depth = 0;
  let current = "";
  for (const char of actions) {
    if (char === "(") depth += 1;
    if (char === ")") depth -= 1;
    if (char === "," && depth === 0) {
      parts.push(current);
      current = "";
      continue;
    }
    current += char;
  }
  parts.push(current);
  return parts.map((part) => part.trim()).filter((part) => part.length > 0);
}

function classifyAlterTableAction(rawAction: string): string | null {
  // Blank out string literals so e.g. DEFAULT 'not null' cannot confuse the
  // keyword checks below.
  const action = rawAction.replace(/'(?:[^']|'')*'/g, "''");
  if (/^add (constraint|check|unique|primary key|foreign key|exclude)\b/.test(action)) {
    if (/\bnot valid\b/.test(action)) return null;
    return "adds a constraint that validates existing rows and takes locks; use ADD CONSTRAINT ... NOT VALID plus a later VALIDATE CONSTRAINT";
  }
  // ADD [COLUMN] name type ... (the COLUMN keyword is optional in PostgreSQL).
  if (/^add\b/.test(action)) {
    const addsNotNull = /\bnot null\b/.test(action);
    const hasDefault = /\bdefault\b/.test(action);
    const isIdentity = /\bgenerated (always|by default) as identity\b/.test(action);
    if (addsNotNull && !hasDefault && !isIdentity) {
      return "adds a NOT NULL column without a DEFAULT; this fails on non-empty tables and breaks inserts from already-deployed code";
    }
    return null;
  }
  if (/^validate constraint\b/.test(action)) return null;
  if (/^alter column\b/.test(action)) {
    if (/\bset default\b/.test(action)) return null;
    if (/\bdrop not null\b/.test(action)) return null;
    if (/\bset not null\b/.test(action)) {
      return "sets NOT NULL on an existing column; already-deployed code may still write NULLs and the table scan can fail";
    }
    if (/\b(set data )?type\b/.test(action)) {
      return "changes a column type; this can rewrite/lock the table and break already-deployed readers";
    }
    return "unrecognized ALTER COLUMN action (fail closed)";
  }
  if (/^drop\b/.test(action)) {
    return "drops a column/constraint that already-deployed code may still use";
  }
  if (/^rename\b/.test(action)) {
    return "renames a table/column out from under already-deployed code";
  }
  if (/^(enable|disable|force|no force) (trigger|row level security|rule)\b/.test(action)) {
    return "changes enforcement (trigger/RLS) semantics for already-deployed code";
  }
  return "unrecognized ALTER TABLE action (fail closed)";
}

/** Returns null when the statement is additive, or a reason when it is not. */
export function classifyStatement(statement: string): string | null {
  const s = normalize(statement);

  if (/^create table\b/.test(s)) return null;
  if (/^create( unique)? index\b/.test(s)) return null;
  if (/^create type\b/.test(s)) return null;
  if (/^create (sequence|extension|schema|collation)\b/.test(s)) return null;
  if (/^create (function|procedure|trigger|view|materialized view|policy)\b/.test(s)) return null;
  if (/^create or replace\b/.test(s)) {
    return "CREATE OR REPLACE overwrites an existing object that already-deployed code may depend on";
  }
  if (/^alter type\b/.test(s)) {
    if (/\badd value\b/.test(s)) return null;
    return "ALTER TYPE beyond ADD VALUE (rename/drop) breaks already-deployed readers";
  }
  if (/^alter table\b/.test(s)) {
    const match = /^alter table (if exists )?(only )?("[^"]+"|[a-z0-9_.]+)( \*)? (.*)$/.exec(s);
    if (!match) return "unparseable ALTER TABLE statement (fail closed)";
    const reasons = splitAlterTableActions(match[5]!)
      .map((action) => classifyAlterTableAction(action))
      .filter((reason): reason is string => reason !== null);
    return reasons.length > 0 ? reasons.join("; ") : null;
  }
  if (/^comment on\b/.test(s)) return null;
  if (/^set\b/.test(s)) return null; // session-local settings, e.g. statement_timeout

  if (/^drop\b/.test(s)) return "DROP removes an object that already-deployed code may still use";
  if (/^truncate\b/.test(s)) return "TRUNCATE deletes data";
  if (/^(update|delete|merge)\b/.test(s)) return "data backfill (UPDATE/DELETE/MERGE) needs an explicit deploy/migrate ordering plan";
  if (/^insert\b/.test(s)) return "data seeding/backfill (INSERT) needs an explicit deploy/migrate ordering plan";
  if (/^with\b/.test(s)) return "CTE data backfill needs an explicit deploy/migrate ordering plan";
  if (/^do\b/.test(s)) return "opaque procedural DO block cannot be verified as additive (fail closed)";
  if (/^(grant|revoke|reassign)\b/.test(s)) return "permission change can revoke access already-deployed code relies on";
  if (/^(lock|cluster|reindex|vacuum)\b/.test(s)) return "lock-heavy maintenance statement in a migration (fail closed)";

  return "unrecognized statement (fail closed)";
}

export function classifyMigrationSql(sqlText: string): Finding[] {
  const findings: Finding[] = [];
  for (const statement of splitSqlStatements(sqlText)) {
    const reason = classifyStatement(statement);
    if (reason !== null) {
      const summary = statement.replace(/\s+/g, " ").trim();
      findings.push({
        statement: summary.length > 120 ? `${summary.slice(0, 117)}...` : summary,
        reason,
      });
    }
  }
  return findings;
}

/** The justification following the allow-destructive marker, if present. */
export function destructiveApproval(sqlText: string): string | null {
  // [^\S\n] = horizontal whitespace only, so the justification must sit on
  // the marker's own line.
  const match = new RegExp(`^\\s*--[^\\S\\n]*${ALLOW_DESTRUCTIVE_MARKER}[^\\S\\n]*(\\S.*)$`, "m").exec(sqlText);
  return match ? match[1]!.trim() : null;
}

export type MigrationLintResult = {
  readonly name: string;
  readonly findings: readonly Finding[];
  readonly approval: string | null;
};

export function lintMigrationsDirectory(
  migrationsDir: string,
  options: { readonly all?: boolean } = {},
): MigrationLintResult[] {
  const names = readdirSync(migrationsDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && existsSync(join(migrationsDir, entry.name, "migration.sql")))
    .map((entry) => entry.name)
    .sort((a, b) => a.localeCompare(b))
    .filter((name) => options.all || name.localeCompare(LINT_BASELINE) > 0);

  return names.map((name) => {
    const sqlText = readFileSync(join(migrationsDir, name, "migration.sql"), "utf8");
    return { name, findings: classifyMigrationSql(sqlText), approval: destructiveApproval(sqlText) };
  });
}

function main(): number {
  const all = process.argv.includes("--all");
  const migrationsDir = join(dirname(fileURLToPath(import.meta.url)), "..", "db", "migrations");
  const results = lintMigrationsDirectory(migrationsDir, { all });

  let failures = 0;
  for (const result of results) {
    const file = `web/db/migrations/${result.name}/migration.sql`;
    if (result.findings.length === 0) {
      console.log(`additive     ${result.name}`);
      continue;
    }
    const kind = result.approval ? "warning" : "error";
    for (const finding of result.findings) {
      console.log(`::${kind} file=${file}::${result.name}: ${finding.reason} [${finding.statement}]`);
    }
    if (result.approval) {
      console.log(`destructive  ${result.name} (acknowledged: ${result.approval})`);
    } else {
      console.log(`destructive  ${result.name} (NOT acknowledged)`);
      failures += 1;
    }
  }

  console.log(`\n${results.length} migration(s) linted after baseline ${all ? "(--all)" : LINT_BASELINE}, ${failures} unacknowledged destructive`);
  if (failures > 0) {
    console.log(
      `\nDestructive migrations need a deploy/migrate ordering plan. If this migration is safe, acknowledge it inside the .sql file:\n  -- ${ALLOW_DESTRUCTIVE_MARKER} <why this is safe>`,
    );
    return 1;
  }
  return 0;
}

if (resolve(process.argv[1] ?? "") === fileURLToPath(import.meta.url)) {
  process.exit(main());
}
