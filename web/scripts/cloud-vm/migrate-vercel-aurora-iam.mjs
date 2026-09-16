#!/usr/bin/env node
import { createRequire } from "node:module";
import path from "node:path";
import {
  loadTargetEnv,
  parseWebDirAndTarget,
} from "./projects.mjs";

import { createAuroraOperatorPool } from "./aurora-operator.mjs";

const usage = "Usage: migrate-vercel-aurora-iam.mjs [web-dir] <staging|production>";
const { webDir, project } = parseWebDirAndTarget(process.argv.slice(2), usage);
const pkgPath = path.join(webDir, "package.json");
const migrationsFolder = path.join(webDir, "db/migrations");
const requireFromWeb = createRequire(pkgPath);
const { drizzle } = requireFromWeb("drizzle-orm/node-postgres");
const { migrate } = requireFromWeb("drizzle-orm/node-postgres/migrator");

try {
  const env = loadTargetEnv(project);
  const pool = createAuroraOperatorPool(webDir, env, project.projectName);

  try {
    const db = drizzle({ client: pool });
    await migrate(db, { migrationsFolder });
  } finally {
    await pool.end();
  }

  console.log(`${project.label} migration applied`);
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}
