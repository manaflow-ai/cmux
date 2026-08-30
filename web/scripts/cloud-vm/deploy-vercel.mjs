#!/usr/bin/env node
import { existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { parseWebDirAndTarget, runVercel } from "./projects.mjs";

const usage = "Usage: deploy-vercel.mjs [web-dir] <staging|production>";
const { target, project, webDir } = parseWebDirAndTarget(process.argv.slice(2), usage);

if (!process.env.VERCEL_TOKEN) {
  console.error("Missing VERCEL_TOKEN in the environment.");
  process.exit(1);
}

// Vercel builds from the repo root; the linked project's Root Directory
// setting (web) picks the app. Link via .vercel/project.json exactly like
// docs-deploy-reusable.yml so no `vercel link` prompt can appear in CI.
const repoRoot = path.dirname(webDir);
const vercelDir = path.join(repoRoot, ".vercel");
if (existsSync(vercelDir)) {
  console.error(`Refusing to overwrite existing ${vercelDir}; remove it first.`);
  process.exit(1);
}

try {
  mkdirSync(vercelDir, { recursive: true });
  writeFileSync(
    path.join(vercelDir, "project.json"),
    JSON.stringify({ orgId: project.orgId, projectId: project.projectId }),
  );
  const stdout = runVercel(["deploy", "--prod", "--yes", "--cwd", repoRoot], {
    stdio: ["ignore", "pipe", "inherit"],
  });
  const deploymentURL = stdout.toString().trim();
  console.log(
    JSON.stringify({ ok: true, target, project: project.projectName, url: project.url, deploymentURL }, null, 2),
  );
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
} finally {
  rmSync(vercelDir, { recursive: true, force: true });
}
