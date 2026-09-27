#!/usr/bin/env node
import { createRequire } from "node:module";
import path from "node:path";
import { loadTargetEnv, parseWebDirAndTarget } from "./projects.mjs";
import { createPlanetScaleOperatorPool, PlanetScaleOperatorConfigError } from "./planetscale-operator.mjs";

const usage = "Usage: migrate-planetscale.mjs [web-dir] <staging|production> [--check]";
const { webDir, project, rest } = parseWebDirAndTarget(process.argv.slice(2), usage);
if (rest.some((arg) => arg !== "--check")) {
  console.error(usage);
  process.exit(2);
}
const checkOnly = rest.includes("--check");
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
      const requireFromWeb = createRequire(path.join(webDir, "package.json"));
      const { drizzle } = requireFromWeb("drizzle-orm/node-postgres");
      const { migrate } = requireFromWeb("drizzle-orm/node-postgres/migrator");
      await migrate(drizzle({ client: pool }), { migrationsFolder: path.join(webDir, "db/migrations") });
    }
  } finally {
    await pool.end();
  }
  console.log(`${project.label} PlanetScale ${checkOnly ? "connection verified (read only)" : "migration applied"}`);
} catch (error) {
  // Driver errors may contain credentials, SQL, or customer rows.
  console.error(error instanceof PlanetScaleOperatorConfigError ? error.message :
    `${project.label} PlanetScale ${checkOnly ? "connection check" : "migration"} failed; check target credentials, access, and migration state.`);
  process.exitCode = 1;
}
