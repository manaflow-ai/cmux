#!/usr/bin/env bun
// Detector for "paths filter misses inputs" (cmuxterm-hq docs/handbook): every repo file the gallery build
// bundles must be routed by gallery health. The build's own module list (the Rolldown metafile,
// CMUX_WEBVIEWS_METAFILE) is the truth; two routers read it and either can miss a file:
//   1. the workflow's `paths` (a change outside them starts no gallery health run at all), and
//   2. touched.ts, which must place a bundled source file on some entry (its imports, its host frame's
//      imports, its host's stylesheets, its folder) or render everything for it. A bundled file it places on
//      nothing renders nothing when it changes, so a broken render would merge green.
// The plan job runs this on every run after its one build. A red names each file and why; the run still renders
// what the plan chose, and the red fails the check, so the router is fixed in the pull request that added the
// input (cmuxterm-hq#12794; the cargo twin is scripts/ci/affected_jobs.py check, manaflow-ai/cmux#45420).
//
//   bun scripts/gallery/route-check.ts --metafile meta.json --workflow ../.github/workflows/gallery-health.yml
import fs from "node:fs";
import path from "node:path";
import { parseArgs } from "node:util";
import { SRC } from "./entries";
import { loadEntryRoots, reachableFiles } from "./touched";

/** GitHub's `paths` rule (unplaced.py's): the last pattern that matches decides, a `!` pattern excluding. */
export function routed(repoPath: string, patterns: string[]): boolean {
  let hit = false;
  for (const pattern of patterns) {
    const body = pattern.replace(/^!/, "");
    let out = "";
    for (let index = 0; index < body.length;) {
      if (body.startsWith("**/", index)) ((out += "(?:.*/)?"), (index += 3));
      else if (body.startsWith("**", index)) ((out += ".*"), (index += 2));
      else if (body[index] === "*") ((out += "[^/]*"), (index += 1));
      else ((out += body[index]!.replace(/[.+?^${}()|[\]\\]/g, "\\$&")), (index += 1));
    }
    if (new RegExp(`^${out}$`).test(repoPath)) hit = !pattern.startsWith("!");
  }
  return hit;
}

/** The workflow's `on.pull_request.paths`, read as unplaced.py reads them. */
export function pullRequestPaths(workflow: string): string[] {
  const lines = workflow.split("\n");
  const start = lines.indexOf("  pull_request:");
  const paths: string[] = [];
  let inside = false;
  for (const line of lines.slice(start + 1)) {
    if (/^ {0,2}\S/.test(line)) break;
    if (line.trim() === "paths:") {
      inside = true;
      continue;
    }
    if (!inside || !line.trim() || line.trim().startsWith("#")) continue;
    const item = /^\s+- "([^"]+)"\s*$/.exec(line);
    if (!item) break;
    paths.push(item[1]!);
  }
  return paths;
}

/** Repo paths of the modules a Rolldown metafile (bundle-metafile.mjs) lists: no virtual modules, no packages. */
export function bundledFiles(
  metafile: { outputs: Record<string, { inputs: Record<string, unknown> }> },
  repoRoot: string,
): string[] {
  const out = new Set<string>();
  for (const output of Object.values(metafile.outputs))
    for (const id of Object.keys(output.inputs ?? {})) {
      const file = id.replace(/^\0/, "").replace(/\?.*$/, "");
      if (!file.startsWith(`${repoRoot}/`) || file.includes("/node_modules/")) continue;
      out.add(path.relative(repoRoot, file));
    }
  return [...out].sort();
}

const SOURCE = /\.(ts|tsx|js|mjs|css)$/;

export type Miss = { file: string; why: string };

/** The bundled repo files the workflow's paths or touched.ts would miss. */
export function misses(
  bundled: string[],
  patterns: string[],
  reachable: { has: (file: string) => boolean },
  broad: (repoPath: string) => boolean,
  repoRoot: string,
): Miss[] {
  const found: Miss[] = [];
  for (const file of bundled) {
    if (!routed(file, patterns)) {
      found.push({ file, why: "the gallery bundles it, but gallery-health.yml's paths do not start a run for it" });
      continue;
    }
    // A routed file that is not webviews/src source renders every entry when nothing places it (unplaced.py).
    if (!file.startsWith("webviews/src/") || !SOURCE.test(file) || broad(file)) continue;
    if (!reachable.has(path.join(repoRoot, file)))
      found.push({
        file,
        why: "the gallery bundles it, but touched.ts places it on no entry (no entry, host frame or host stylesheet reaches it), so a change to it renders nothing",
      });
  }
  return found;
}

if (import.meta.main) {
  const { values } = parseArgs({ options: { metafile: { type: "string" }, workflow: { type: "string" } } });
  if (!values.metafile || !values.workflow) throw new Error("--metafile and --workflow are required");
  const repoRoot = path.resolve(SRC, "../..");
  const metafile = JSON.parse(fs.readFileSync(values.metafile, "utf8"));
  const bundled = bundledFiles(metafile, repoRoot);
  const patterns = pullRequestPaths(fs.readFileSync(values.workflow, "utf8"));
  const { reachable, broad } = reachableFiles(await loadEntryRoots());
  const found = misses(bundled, patterns, reachable, broad, repoRoot);
  console.log(`gallery route check: ${bundled.length} bundled repo files, ${found.length} missed by routing`);
  for (const miss of found) console.log(`::error file=${miss.file},title=gallery routing misses an input::${miss.why}`);
  process.exit(found.length ? 1 : 0);
}
