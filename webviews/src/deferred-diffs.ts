/**
 * Generated and large files start collapsed with a "Load diff" affordance
 * (GitHub "Files changed" parity). Generated = what the shared file-kind
 * classifier calls generated (fileKinds.ts): a path the local repository marks
 * `linguist-generated` or `-diff` in `.gitattributes` (computed by the Rust
 * sidecar for typed sessions), a lockfile, tool output such as `*.min.js`,
 * `project.pbxproj` or a `generated/` tree, or a translation catalog. Large =
 * a patch with at least LARGE_DIFF_CHANGED_LINES changed lines or at least
 * LARGE_DIFF_PATCH_BYTES of patch text.
 */
import { fileKind } from "./fileKinds";

export type DeferredDiffReason = "generated" | "large";

export const LARGE_DIFF_CHANGED_LINES = 2_000;
export const LARGE_DIFF_PATCH_BYTES = 400 * 1024;

/** True when the viewer opens this file collapsed because nobody wrote it by hand. */
export function isGeneratedDiffPath(path: string, generatedPaths: ReadonlySet<string>): boolean {
  return fileKind(path, generatedPaths) === "generated";
}

export function deferredDiffReason(input: {
  path: string;
  changedLines: number;
  patchBytes: number;
  generatedPaths: ReadonlySet<string>;
}): DeferredDiffReason | undefined {
  if (isGeneratedDiffPath(input.path, input.generatedPaths)) {
    return "generated";
  }
  if (input.changedLines >= LARGE_DIFF_CHANGED_LINES || input.patchBytes >= LARGE_DIFF_PATCH_BYTES) {
    return "large";
  }
  return undefined;
}
