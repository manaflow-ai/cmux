#!/usr/bin/env bun
/**
 * The steps of the devbox rebake workflow (.github/workflows/cloud-devbox-image-rebake.yml)
 * that are not the bake itself. The bake, verify, size derivation and manifest write stay
 * promote-devbox-image.ts's; this only decides, names, settles and prunes.
 *
 *   bun scripts/devbox-rebake.ts plan [--force]
 *       needed=true when a Freestyle default in the manifest was not baked from this
 *       checkout's devbox sources (devboxSourceDriftProblems, the same check promote
 *       enforces), and the version this run would publish:
 *       <UTC yyyymmddHHMM>-<commit 10>-<desktop source digest 12>. Prints key=value lines
 *       for $GITHUB_OUTPUT (also the image-stamp line the bake writes). No credential.
 *   bun scripts/devbox-rebake.ts settle
 *       After a promotion: drop every awaiting-rebake.json entry the new defaults satisfy
 *       (its drift is gone), so the manifest check and test pass with the promotion.
 *   FREESTYLE_API_KEY=... bun scripts/devbox-rebake.ts prune --keep N [--dry-run]
 *       Keep the newest N rebake versions' snapshots (slug cmux-devbox-ci-<version>[-<size>])
 *       and every manifest default; delete the other rebake snapshots. Never touches a
 *       snapshot without the rebake prefix.
 */
import { writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";
import { VM_IMAGE_SIZE_NAMES } from "../services/vms/images/sizes";
import {
  devboxAwaitingRebakePath,
  devboxSourceDigest,
  devboxImageEpoch,
  devboxSourceDriftProblems,
  hasFlag,
  argValue,
  isAwaitingRebake,
  readDevboxAwaitingRebake,
  readImageManifest,
  repoRoot,
  type DevboxAwaitingRebake,
  type DevboxImageManifest,
} from "./devbox-image-common";

export const REBAKE_SLUG_PREFIX = "cmux-devbox-ci-";

/** `<yyyymmddHHMM>-<commit 10>-<digest 12>`: sortable by time, names its commit and its sources. */
export function rebakeVersion(now: Date, commit: string, digest: string): string {
  const stamp = now.toISOString().replace(/[-:T]/g, "").slice(0, 12);
  return `${stamp}-${commit.slice(0, 10)}-${digest.slice(0, 12)}`;
}

/** The awaiting entries a manifest still needs; the rest were baked by the promotion. */
export function settledAwaiting(
  awaiting: readonly DevboxAwaitingRebake[],
  drift: readonly string[],
): DevboxAwaitingRebake[] {
  return awaiting.filter((pending) => drift.some((problem) => isAwaitingRebake(problem, pending)));
}

export type SnapshotRow = { id: string; slug?: string | null; createdAt?: string };

/** The rebake version a snapshot slug belongs to, or null for any snapshot the rebake did not make. */
export function rebakeVersionOfSlug(slug: string | null | undefined): string | null {
  if (!slug || !slug.startsWith(REBAKE_SLUG_PREFIX)) return null;
  const rest = slug.slice(REBAKE_SLUG_PREFIX.length);
  const sizes = [...VM_IMAGE_SIZE_NAMES].sort((a, b) => b.length - a.length);
  for (const size of sizes) {
    if (rest.endsWith(`-${size}`)) return rest.slice(0, -size.length - 1);
  }
  return rest;
}

/**
 * Which rebake snapshots to delete: not among the newest `keep` versions and not a
 * manifest default (the image users get now). Rollback by manifest revert works to
 * any of the `keep` newest versions.
 */
export function pruneSelection(
  snapshots: readonly SnapshotRow[],
  manifest: Pick<DevboxImageManifest, "images">,
  keep: number,
): SnapshotRow[] {
  if (!Number.isInteger(keep) || keep < 1) throw new Error(`--keep must be a positive integer, got ${keep}`);
  const referenced = new Set(manifest.images.filter((entry) => entry.defaultForKind).map((entry) => entry.imageId));
  const versions = [...new Set(snapshots.map((row) => rebakeVersionOfSlug(row.slug)).filter((v): v is string => v !== null))]
    .sort()
    .reverse();
  const kept = new Set(versions.slice(0, keep));
  return snapshots.filter((row) => {
    const version = rebakeVersionOfSlug(row.slug);
    return version !== null && !kept.has(version) && !referenced.has(row.id);
  });
}

function plan(): void {
  const manifest = readImageManifest();
  const drift = devboxSourceDriftProblems(manifest);
  const commit = execFileSync("git", ["rev-parse", "HEAD"], { cwd: repoRoot, encoding: "utf8" }).trim();
  const digest = devboxSourceDigest("desktop");
  const version = rebakeVersion(new Date(), commit, digest);
  const needed = drift.length > 0 || hasFlag("--force");
  for (const problem of drift) console.error(`drift: ${problem}`);
  console.log(`needed=${needed}`);
  console.log(`version=${version}`);
  console.log(`slug=${REBAKE_SLUG_PREFIX}${version}`);
  console.log(`digest=${digest}`);
  console.log(`commit=${commit}`);
  // The known-good marker the smoke test reads back from a booted machine.
  console.log(`stamp=cmux-devbox ${devboxImageEpoch()} desktop`);
}

function settle(): void {
  const awaiting = readDevboxAwaitingRebake();
  const keep = settledAwaiting(awaiting, devboxSourceDriftProblems(readImageManifest()));
  if (keep.length === awaiting.length) {
    console.log(`awaiting-rebake: nothing settled (${awaiting.length} entries)`);
    return;
  }
  writeFileSync(devboxAwaitingRebakePath, `${JSON.stringify(keep, null, 2)}\n`);
  console.log(`awaiting-rebake: settled ${awaiting.length - keep.length} entries, ${keep.length} left`);
}

async function prune(): Promise<void> {
  const keep = Number(argValue("--keep") ?? "5");
  const dryRun = hasFlag("--dry-run");
  const { Freestyle } = await import("freestyle");
  const fs = new Freestyle({ baseUrl: process.env.FREESTYLE_API_URL?.trim() || undefined });
  const { snapshots } = await fs.vms.snapshots.list();
  const doomed = pruneSelection(snapshots as unknown as SnapshotRow[], readImageManifest(), keep);
  console.log(`prune: keeping the newest ${keep} rebake versions and every manifest default; ${doomed.length} snapshots to delete`);
  let failed = 0;
  for (const row of doomed) {
    if (dryRun) {
      console.log(`would delete ${row.id} (${row.slug})`);
      continue;
    }
    try {
      await fs.vms.snapshots.delete(row.id);
      console.log(`deleted ${row.id} (${row.slug})`);
    } catch (error) {
      failed += 1;
      console.error(`could not delete ${row.id} (${row.slug}): ${error instanceof Error ? error.message : String(error)}`);
    }
  }
  if (failed > 0) process.exit(1);
}

const isEntryPoint = process.argv[1] !== undefined && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isEntryPoint) {
  const command = process.argv[2];
  if (command === "plan") plan();
  else if (command === "settle") settle();
  else if (command === "prune") await prune();
  else {
    console.error("usage: bun scripts/devbox-rebake.ts plan [--force] | settle | prune --keep N [--dry-run]");
    process.exit(2);
  }
}
