#!/usr/bin/env node
// Read-only check that a database's Drizzle ledger holds every migration in a
// tree. Exit codes are LEDGER_EXIT in migration-ledger.mjs.
import { appendFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import {
  compareLedger,
  formatLedgerReport,
  LEDGER_EXIT,
  LEDGER_MODES,
  ledgerVerdict,
  readLocalMigrations,
} from "./migration-ledger.mjs";
import { createPlanetScaleOperatorPool, PlanetScaleOperatorConfigError } from "./planetscale-operator.mjs";
import { loadTargetEnv, parseWebDirAndTarget } from "./projects.mjs";

const usage = "Usage: check-migration-ledger.mjs [web-dir] <staging|production> [--mode gate|pull-request|advisory] " +
  "[--migrations <dir>] [--base-migrations <dir>] [--source-ref <sha|pr>] [--repository <owner/repo>] [--json <file>]";
const valueOptions = new Set(["--mode", "--migrations", "--base-migrations", "--source-ref", "--repository", "--json"]);

function usageExit() {
  console.error(usage);
  process.exit(LEDGER_EXIT.usage);
}

function parseOptions(args) {
  const options = {};
  for (let index = 0; index < args.length; index += 1) {
    const flag = args[index];
    const value = args[index + 1];
    if (!valueOptions.has(flag) || value === undefined || value.startsWith("--")) usageExit();
    options[flag.slice(2)] = value;
    index += 1;
  }
  return options;
}

const { webDir, project, rest } = parseWebDirAndTarget(process.argv.slice(2), usage);
const options = parseOptions(rest);
const mode = options.mode ?? "gate";
if (!LEDGER_MODES.includes(mode)) usageExit();
const inActions = process.env.GITHUB_ACTIONS === "true";

function annotate(level, message) {
  if (inActions) console.log(`::${level} title=Migration ledger (${project.label})::${message}`);
}

function summarize(text) {
  const file = process.env.GITHUB_STEP_SUMMARY;
  if (inActions && file) appendFileSync(file, `### Migration ledger: ${project.label}\n\n\`\`\`\n${text}\n\`\`\`\n`);
}

function writeJson(payload) {
  if (options.json) writeFileSync(options.json, `${JSON.stringify({ target: project.label, mode, ...payload }, null, 2)}\n`);
}

/** A driver error can carry SQL, rows, or a connection string; keep only its code. */
function safeReason(error) {
  if (error instanceof PlanetScaleOperatorConfigError) return error.message;
  const code = error && typeof error === "object" && "code" in error ? String(error.code) : "";
  return /^[A-Z0-9_]{1,32}$/.test(code) ? `database error ${code}` : "connection or query failed";
}

async function readAppliedLedger() {
  const pool = createPlanetScaleOperatorPool(webDir, loadTargetEnv(project), project.label);
  try {
    await pool.query("begin read only");
    try {
      const { rows } = await pool.query("select name, hash from drizzle.__drizzle_migrations");
      return rows;
    } finally {
      await pool.query("rollback");
    }
  } finally {
    await pool.end();
  }
}

const local = readLocalMigrations(path.resolve(options.migrations ?? path.join(webDir, "db/migrations")));
const baseNames = options["base-migrations"]
  ? readLocalMigrations(path.resolve(options["base-migrations"])).map((migration) => migration.name)
  : undefined;

let applied;
try {
  applied = await readAppliedLedger();
} catch (error) {
  const message = `could not read the ${project.label} migration ledger: ${safeReason(error)}`;
  writeJson({ status: "unverified", exitCode: mode === "advisory" ? LEDGER_EXIT.ok : LEDGER_EXIT.unverified, reason: message });
  summarize(message);
  if (mode === "advisory") {
    annotate("warning", message);
    console.log(message);
    process.exit(LEDGER_EXIT.ok);
  }
  annotate("error", message);
  console.error(message);
  process.exit(LEDGER_EXIT.unverified);
}

const result = compareLedger({ local, applied, baseNames });
const verdict = ledgerVerdict(result, mode);
const report = formatLedgerReport({
  target: project.label,
  result,
  verdict,
  sourceRef: options["source-ref"],
  repository: options.repository,
});
writeJson({ status: verdict.status, exitCode: verdict.exitCode, ...result });
summarize(report);
if (verdict.status === "fail") {
  annotate("error", `${project.label} has not applied ${result.pending.map((migration) => migration.name).join(", ")}. Apply staging, then production, before merging; see the job log.`);
  console.error(report);
} else {
  if (verdict.status === "warn") annotate("warning", `${project.label} ledger differs from this tree; see the job log.`);
  console.log(report);
}
process.exit(verdict.exitCode);
