#!/usr/bin/env bun
/** Validate the checked-in Freestyle image manifest and its complete ladder. */
import {
  devboxImageLadderProblems,
  imageManifestProblems,
  readImageManifest,
} from "./devbox-image-common";

const manifest = readImageManifest();
const problems = [...imageManifestProblems(manifest), ...devboxImageLadderProblems(manifest)];
if (problems.length > 0) {
  console.error(`devbox image manifest is invalid:\n  ${problems.join("\n  ")}`);
  process.exit(1);
}

const defaults = manifest.images.filter((entry) => entry.provider === "freestyle" && entry.defaultForKind);
console.log(`devbox image manifest ok: ${defaults.length} validated Freestyle defaults across base and desktop ladders`);
