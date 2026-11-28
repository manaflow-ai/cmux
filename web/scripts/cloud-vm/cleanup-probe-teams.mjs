#!/usr/bin/env bun
// Lists, then optionally deletes, the empty personal teams earlier probe runs
// left in the sign-in directory (probeTeams.mjs explains where they came
// from). Only teams with a probe account's exact name and no members qualify,
// and each is re-checked for members right before it is deleted.
//
//   bun scripts/cloud-vm/cleanup-probe-teams.mjs production               # list only
//   bun scripts/cloud-vm/cleanup-probe-teams.mjs production --delete --max-delete 500
//
// Needs the target's server key (STACK_SECRET_SERVER_KEY), read the way the
// smoke reads it (CMUX_CLOUD_VM_ENV_SOURCE=process in CI).
import { createRequire } from "node:module";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { loadTargetEnv, optionValue, parseWebDirAndTarget, requireEnvKeys } from "./projects.mjs";
import { listOrphanProbeTeams } from "./probeTeams.mjs";

const usage = "Usage: cleanup-probe-teams.mjs [web-dir] <staging|production> [--delete] [--max-delete <n>] [--max-pages <n>]";
const { webDir, project, rest } = parseWebDirAndTarget(process.argv.slice(2), usage);
const shouldDelete = rest.includes("--delete");
const maxDelete = Number(optionValue(rest, "--max-delete") ?? 200);
const maxPages = Number(optionValue(rest, "--max-pages") ?? 50);
if (!(Number.isInteger(maxDelete) && maxDelete > 0) || !(Number.isInteger(maxPages) && maxPages > 0)) {
  console.error(usage);
  process.exit(2);
}

const env = loadTargetEnv(project);
requireEnvKeys(env, ["NEXT_PUBLIC_STACK_PROJECT_ID", "STACK_SECRET_SERVER_KEY"], `${project.projectName} probe team cleanup`);
const requireFromWeb = createRequire(path.join(webDir, "package.json"));
const { StackServerApp } = await import(pathToFileURL(requireFromWeb.resolve("@hexclave/js")).href);
const app = new StackServerApp({
  projectId: env.NEXT_PUBLIC_STACK_PROJECT_ID,
  ...(env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY ? { publishableClientKey: env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY } : {}),
  secretServerKey: env.STACK_SECRET_SERVER_KEY,
});

const { orphans, scanned, complete } = await listOrphanProbeTeams(app, { maxPages });
for (const team of orphans) {
  console.log(JSON.stringify({ orphan: team.id, displayName: team.displayName, createdAt: team.createdAt?.toISOString?.() ?? null }));
}
const summary = { target: project.label, scanned, complete, orphans: orphans.length, deleted: 0, kept: [] };
if (shouldDelete) {
  for (const team of orphans.slice(0, maxDelete)) {
    try {
      if ((await team.listUsers()).length > 0) {
        summary.kept.push(team.id);
        continue;
      }
      await team.delete();
      summary.deleted += 1;
    } catch {
      summary.kept.push(team.id);
    }
  }
}
console.log(JSON.stringify(summary));
