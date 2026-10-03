#!/usr/bin/env bun
/**
 * Reports whether the devbox image the manifest serves was baked from the
 * devbox source that is checked in now.
 *
 * The manifest is the source of truth for the image users boot, and merging a
 * manifest bump ships it. Editing the image SOURCE (`services/vms/images/devbox`
 * or the builder script) ships nothing on its own: a snapshot has to be baked
 * and promoted first. Without this check that gap is invisible, and a merged
 * change to the shell config or the Dockerfile silently never reaches a machine.
 *
 * Each default manifest entry records the `repoCommit` it was baked from, so
 * drift is the diff between the image inputs at that commit and the ones in the
 * working tree. No manifest schema change and no provider credential needed.
 *
 * Two failures live here, and they are not the same severity:
 *
 *   PIN   the manifest itself is wrong. A default was baked from a commit that
 *         is not in main's history (a branch bake), or one kind's size ladder
 *         mixes bakes (the shape a hand-resolved manifest conflict takes). Both
 *         mean the deployed image is not the one main describes, so `--pin`
 *         is safe to make a required check.
 *   DRIFT main's image source moved past the pinned bake. Expected right after
 *         an image source PR merges, and only a bake clears it, so this reports
 *         and never gates.
 *
 * Usage:
 *   bun scripts/check-devbox-image-drift.ts            # pin + drift, exit 1 on either
 *   bun scripts/check-devbox-image-drift.ts --pin      # pin only
 *   bun scripts/check-devbox-image-drift.ts --warn     # always exit 0
 */
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import {
  DEVBOX_DESKTOP_FILES,
  DEVBOX_TEMPLATE_FILES,
  devboxDesktopDir,
  devboxDir,
  readImageManifest,
  repoRoot,
  webRoot,
} from "./devbox-image-common";

/**
 * Every file whose content ends up in a baked image, as repo-relative paths.
 * The builder script is included because it writes files into the image that
 * the devbox directory does not carry (the ble.sh install, the cache bake).
 */
export function devboxImageInputPaths(): string[] {
  const rel = (dir: string, name: string) => path.relative(repoRoot, path.join(dir, name));
  return [
    ...DEVBOX_TEMPLATE_FILES.map((name) => rel(devboxDir, name)),
    ...DEVBOX_DESKTOP_FILES.map((name) => rel(devboxDesktopDir, name)),
    path.relative(repoRoot, path.join(webRoot, "scripts/build-devbox-freestyle.ts")),
  ].sort();
}

/** Reads one input from a commit; a file the commit predates reads as absent. */
function readAtCommit(commit: string, relPath: string): string | null {
  try {
    return execFileSync("git", ["show", `${commit}:${relPath}`], {
      cwd: repoRoot,
      encoding: "utf8",
      maxBuffer: 32 * 1024 * 1024,
    });
  } catch {
    return null;
  }
}

function readFromTree(relPath: string): string | null {
  const full = path.join(repoRoot, relPath);
  return existsSync(full) ? readFileSync(full, "utf8") : null;
}

/** Input paths whose content differs between a baked commit and the tree. */
export function driftedInputs(
  baked: ReadonlyMap<string, string | null>,
  tree: ReadonlyMap<string, string | null>,
): string[] {
  const paths = new Set([...baked.keys(), ...tree.keys()]);
  return [...paths].filter((p) => baked.get(p) !== tree.get(p)).sort();
}

/**
 * The ref a bake must have landed on. A feature branch is usually behind main,
 * so testing against HEAD alone would call every recent bake a branch bake.
 * CI checks out the PR's merge commit, where HEAD already contains the base.
 */
function landedRef(): string {
  for (const ref of [process.env.CMUX_DEVBOX_BASE_REF, "origin/main", "main"]) {
    if (!ref) continue;
    try {
      execFileSync("git", ["rev-parse", "--verify", "--quiet", `${ref}^{commit}`], { cwd: repoRoot, stdio: "ignore" });
      return ref;
    } catch {
      continue;
    }
  }
  return "HEAD";
}

/** True when `commit` is in the landed history (or in this checkout's HEAD). */
function isLanded(commit: string, ref = landedRef()): boolean | null {
  for (const target of [ref, "HEAD"]) {
    try {
      execFileSync("git", ["merge-base", "--is-ancestor", commit, target], { cwd: repoRoot, stdio: "ignore" });
      return true;
    } catch {
      continue;
    }
  }
  try {
    execFileSync("git", ["cat-file", "-e", `${commit}^{commit}`], { cwd: repoRoot, stdio: "ignore" });
  } catch {
    // A commit this clone does not have is a shallow checkout, not a branch
    // bake, and must not be reported as one.
    return null;
  }
  return false;
}

/**
 * Manifest problems that no bake can fix, so they must not reach main.
 *
 * A promote PR writes twelve entries at once. Two agents promoting in parallel
 * therefore collide in one file, and resolving that conflict by hand is how a
 * ladder ends up half from each bake: valid JSON, one default per kind and
 * size, and machines of different sizes running different images.
 */
export function pinProblems(
  defaults: readonly { version: string; kind?: string; repoCommit?: string }[],
  ancestry: (commit: string) => boolean | null,
): string[] {
  const problems: string[] = [];
  const byKind = new Map<string, Map<string, string[]>>();
  for (const entry of defaults) {
    const kind = entry.kind ?? "base";
    if (!entry.repoCommit) continue;
    const lineages = byKind.get(kind) ?? new Map<string, string[]>();
    lineages.set(entry.repoCommit, [...(lineages.get(entry.repoCommit) ?? []), entry.version]);
    byKind.set(kind, lineages);
  }
  for (const [kind, lineages] of byKind) {
    if (lineages.size > 1) {
      const shown = [...lineages]
        .map(([commit, versions]) => `${commit.slice(0, 10)} (${versions.join(", ")})`)
        .join(" and ");
      problems.push(
        `${kind}: the size ladder mixes bakes: ${shown}. ` +
          "One bake feeds one ladder; re-run the promotion instead of merging two.",
      );
    }
    for (const commit of lineages.keys()) {
      if (ancestry(commit) === false) {
        problems.push(
          `${kind}: default baked from ${commit.slice(0, 10)}, which is not in this history. ` +
            "A branch bake (CMUX_BAKE_ALLOW_BRANCH=1) must not be promoted: rebake from main.",
        );
      }
    }
  }
  return problems;
}

function main(): void {
  const warnOnly = process.argv.includes("--warn");
  const manifest = readImageManifest();
  const defaults = manifest.images.filter((entry) => entry.defaultForKind);
  if (defaults.length === 0) {
    console.error("devbox image drift: the manifest has no default entry to check");
    process.exit(1);
  }
  const pin = pinProblems(defaults, (commit) => isLanded(commit));
  if (pin.length > 0) {
    console.error(`devbox image pin is invalid:\n  ${pin.join("\n  ")}`);
    if (!warnOnly) process.exit(1);
  } else {
    console.log(`devbox image pin ok: ${defaults.length} defaults, one bake per kind, all in this history`);
  }
  if (process.argv.includes("--pin")) return;

  const inputs = devboxImageInputPaths();
  const tree = new Map(inputs.map((p) => [p, readFromTree(p)] as const));

  const bakedCommits = [...new Set(defaults.map((entry) => entry.repoCommit).filter((c): c is string => !!c))];
  const missing = defaults.filter((entry) => !entry.repoCommit);
  if (missing.length > 0) {
    console.warn(
      `devbox image drift: ${missing.length} default entr${missing.length === 1 ? "y has" : "ies have"} no repoCommit; ` +
        "rebake to record one (pre-2026-09 bakes did not).",
    );
  }

  let drifted = false;
  for (const commit of bakedCommits) {
    const baked = new Map(inputs.map((p) => [p, readAtCommit(commit, p)] as const));
    if ([...baked.values()].every((value) => value === null)) {
      console.warn(`devbox image drift: commit ${commit.slice(0, 10)} is not in this checkout; skipping (fetch depth?)`);
      continue;
    }
    const changed = driftedInputs(baked, tree);
    const versions = defaults.filter((entry) => entry.repoCommit === commit).map((entry) => entry.version);
    if (changed.length === 0) {
      console.log(`devbox image ok: ${versions.length} default(s) baked from ${commit.slice(0, 10)} match the tree`);
      continue;
    }
    drifted = true;
    console.error(
      `devbox image drift: the default image(s) baked from ${commit.slice(0, 10)} predate ${changed.length} ` +
        `image input change(s), so these edits are NOT on any machine:\n  ${changed.join("\n  ")}\n` +
        `  defaults: ${versions.join(", ")}\n` +
        "  Bake and promote (from web/, with the deployment's FREESTYLE_API_KEY):\n" +
        "    bun run devbox:promote freestyle --no-desktop   # base ladder\n" +
        "    bun run devbox:promote freestyle                # desktop ladder\n" +
        "  then merge the manifest diff. Until then main's devbox source is ahead of production.",
    );
  }

  if (drifted && !warnOnly) process.exit(1);
}

if (import.meta.main) main();
