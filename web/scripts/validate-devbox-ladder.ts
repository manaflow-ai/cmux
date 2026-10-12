#!/usr/bin/env bun
/**
 * Validate the checked-in Freestyle image manifest: its invariants, its
 * complete ladder, and that every default was baked from this checkout's
 * devbox sources (epoch and source digest), so the manifest keeps describing
 * the machine users get.
 */
import {
  DEVBOX_AWAITING_REBAKE,
  devboxImageLadderProblems,
  devboxDriftAwaitingRebake,
  devboxSourceDriftProblems,
  imageManifestProblems,
  readImageManifest,
} from "./devbox-image-common";

const manifest = readImageManifest();
const problems = [
  ...imageManifestProblems(manifest),
  ...devboxImageLadderProblems(manifest),
  // Drifts awaiting their rebake (DEVBOX_AWAITING_REBAKE) are excused, exactly.
  ...devboxSourceDriftProblems(manifest).filter((problem) => !devboxDriftAwaitingRebake(problem)),
];
if (problems.length > 0) {
  console.error(`devbox image manifest is invalid:\n  ${problems.join("\n  ")}`);
  process.exit(1);
}

const defaults = manifest.images.filter((entry) => entry.provider === "freestyle" && entry.defaultForKind);
const awaiting = DEVBOX_AWAITING_REBAKE.map((pending) => `${pending.layers} ${pending.current.slice(0, 12)}…`);
console.log(
  awaiting.length > 0
    ? `devbox image manifest ok: ${defaults.length} validated Freestyle defaults across base and desktop ladders; sources awaiting their rebake: ${awaiting.join(", ")}`
    : `devbox image manifest ok: ${defaults.length} validated Freestyle defaults across base and desktop ladders, all baked from this checkout's devbox sources`,
);
