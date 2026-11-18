#!/usr/bin/env node
// Holds "contract" migrations back from the automatic production run.
//
// cloud-vm-migrate.yml applies migrations on every push to main that adds one,
// while the previous deployment is still serving (the deploy gate in
// tools/migration-deploy-gate.mjs keeps the new code from going live until
// they are applied). That is safe for expand-only changes: new tables,
// nullable or defaulted columns, indexes, enum values, backfills. A statement
// that removes or reshapes something the live code may still read or write
// breaks that live code the moment it applies, so the automatic run stops and
// a person dispatches the workflow after confirming nothing deployed uses it.
//
// This is a floor, not a substitute for review: it reads statements, not
// intent, and errs toward holding a migration back.
//
// Usage: bun scripts/cloud-vm/contract-migrations.mjs <migration.sql>...
// Exit 0 when every file is expand-only, 1 when any holds a contract
// statement (each is listed), 2 on a usage or read error.
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const rules = [
  { pattern: /\bDROP\s+(?:TABLE|VIEW|MATERIALIZED\s+VIEW|SCHEMA|TYPE|FUNCTION|SEQUENCE)\b/i, reason: "drops an object" },
  { pattern: /\bDROP\s+COLUMN\b/i, reason: "drops a column" },
  { pattern: /\bALTER\s+TABLE\b[\s\S]*?\bDROP\s+(?!CONSTRAINT\b|DEFAULT\b|NOT\s+NULL\b|INDEX\b)(?:IF\s+EXISTS\s+)?"?[A-Za-z_]/i, reason: "drops a column" },
  { pattern: /\bRENAME\b/i, reason: "renames an object or column" },
  { pattern: /\bALTER\s+COLUMN\s+(?:"[^"]+"|[A-Za-z_][\w$]*)\s+(?:SET\s+DATA\s+)?TYPE\b/i, reason: "changes a column type" },
  { pattern: /\bSET\s+NOT\s+NULL\b/i, reason: "makes a column NOT NULL" },
  { pattern: /\bTRUNCATE\b/i, reason: "truncates a table" },
];

const withoutComments = (sql) => sql.replace(/\/\*[\s\S]*?\*\//g, "").replace(/--[^\n]*/g, "");

/** Contract findings in one migration's SQL; empty when it is expand-only. */
export function contractStatements(sql) {
  const findings = [];
  const statements = withoutComments(sql)
    .split(/;|-->\s*statement-breakpoint/)
    .map((statement) => statement.replace(/\s+/g, " ").trim())
    .filter(Boolean);
  for (const statement of statements) {
    const rule = rules.find(({ pattern }) => pattern.test(statement));
    if (rule) findings.push({ reason: rule.reason, statement: statement.slice(0, 160) });
  }
  return findings;
}

/** @returns {number} the process exit code */
export function main(files, { read = (file) => readFileSync(file, "utf8"), log = console.log, error = console.error } = {}) {
  if (files.length === 0) {
    log("contract-migrations: no added migrations to check.");
    return 0;
  }
  let held = 0;
  for (const file of files) {
    let sql;
    try {
      sql = read(file);
    } catch {
      error(`contract-migrations: cannot read ${file}`);
      return 2;
    }
    const name = path.basename(path.dirname(file));
    const findings = contractStatements(sql);
    if (findings.length === 0) {
      log(`contract-migrations: ${name}: expand-only`);
      continue;
    }
    held += 1;
    for (const finding of findings) error(`contract-migrations: ${name}: ${finding.reason}: ${finding.statement}`);
  }
  if (held === 0) return 0;
  error(`contract-migrations: ${held} migration(s) can break the deployment that is live while they apply, so the automatic run stops here.`);
  error("contract-migrations: Confirm no deployed code still reads or writes what they change, then dispatch cloud-vm-migrate.yml with target=production.");
  return 1;
}

if (import.meta.main ?? process.argv[1] === fileURLToPath(import.meta.url)) {
  process.exitCode = main(process.argv.slice(2));
}
