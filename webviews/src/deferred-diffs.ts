/**
 * Generated and large files start collapsed with a "Load diff" affordance
 * (GitHub "Files changed" parity). Generated = a path the local repository
 * marks `linguist-generated` or `-diff` in `.gitattributes` (computed by the
 * Rust sidecar for typed sessions) or a well-known lockfile; large = a patch
 * with at least LARGE_DIFF_CHANGED_LINES changed lines or at least
 * LARGE_DIFF_PATCH_BYTES of patch text.
 */
export type DeferredDiffReason = "generated" | "large";

export const LARGE_DIFF_CHANGED_LINES = 2_000;
export const LARGE_DIFF_PATCH_BYTES = 400 * 1024;

export const WELL_KNOWN_LOCKFILES: ReadonlySet<string> = new Set([
  "bun.lock",
  "bun.lockb",
  "package-lock.json",
  "yarn.lock",
  "pnpm-lock.yaml",
  "Cargo.lock",
  "Package.resolved",
  "go.sum",
  "Gemfile.lock",
  "poetry.lock",
  "uv.lock",
]);

export function isWellKnownLockfile(path: string): boolean {
  const slash = path.lastIndexOf("/");
  return WELL_KNOWN_LOCKFILES.has(slash >= 0 ? path.slice(slash + 1) : path);
}

export function deferredDiffReason(input: {
  path: string;
  changedLines: number;
  patchBytes: number;
  generatedPaths: ReadonlySet<string>;
}): DeferredDiffReason | undefined {
  if (input.generatedPaths.has(input.path) || isWellKnownLockfile(input.path)) {
    return "generated";
  }
  if (input.changedLines >= LARGE_DIFF_CHANGED_LINES || input.patchBytes >= LARGE_DIFF_PATCH_BYTES) {
    return "large";
  }
  return undefined;
}
