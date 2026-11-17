#!/usr/bin/env node
import { applyPendingMigrations } from "./apply-migrations.mjs";
import { loadTargetEnv, parseWebDirAndTarget } from "./projects.mjs";
import { createPlanetScaleOperatorPool, PlanetScaleOperatorConfigError } from "./planetscale-operator.mjs";

const usage = "Usage: migrate-planetscale.mjs [web-dir] <staging|production> [--check]";
const { webDir, project, rest } = parseWebDirAndTarget(process.argv.slice(2), usage);
if (rest.some((arg) => arg !== "--check")) {
  console.error(usage);
  process.exit(2);
}
const checkOnly = rest.includes("--check");
let appliedCount = 0;
try {
  const pool = createPlanetScaleOperatorPool(webDir, loadTargetEnv(project), project.projectName);
  try {
    if (checkOnly) {
      await pool.query("begin read only");
      try {
        await pool.query("select 1");
      } finally {
        await pool.query("rollback");
      }
    } else {
      // Not drizzle's migrate(): it runs every pending migration in one
      // transaction, where CREATE INDEX CONCURRENTLY fails (see apply-migrations.mjs).
      appliedCount = await applyPendingMigrations(pool, webDir);
    }
  } finally {
    await pool.end();
  }
  console.log(`${project.label} PlanetScale ${checkOnly ? "connection verified (read only)" : `migration applied (${appliedCount} pending)`}`);
} catch (error) {
  // Keep credentials, SQL text, and customer rows out of logs while exposing
  // the stable driver fields needed to repair a failed managed migration.
  if (error instanceof PlanetScaleOperatorConfigError) {
    console.error(error.message);
  } else {
    const cause = error?.cause && typeof error.cause === "object" ? error.cause : error;
    const code = typeof cause?.code === "string" ? cause.code : "unknown_code";
    const detail = typeof cause?.message === "string"
      ? cause.message.replace(/(?:postgres(?:ql)?:\/\/)[^\s]+/gi, "postgres://<redacted>").slice(0, 300)
      : typeof error?.message === "string" ? error.message.slice(0, 300) : "unknown database error";
    console.error(`${project.label} PlanetScale ${checkOnly ? "connection check" : "migration"} failed (${code}): ${detail}`);
  }
  process.exitCode = 1;
}
