/**
 * Generated and large files open collapsed behind "Load diff"
 * (deferred-diffs.ts). Parsing such a file's patch into Pierre's
 * FileDiffMetadata is the most expensive main-thread work of a big diff (a
 * 100 MB generated bundle took 6 s of long tasks), and it bought nothing
 * while the file stays collapsed. So the stream parses only the file's
 * header (name, rename, mode) and counts its changed lines, and keeps the
 * patch text on the placeholder. The full parse runs when the file is first
 * expanded (`hydrateDeferredFileDiff`).
 *
 * A file is deferred without parsing when its patch alone is large
 * (LARGE_DIFF_PATCH_BYTES) or its path is generated (a lockfile or a
 * `linguist-generated` path). A file that is large only by changed lines is
 * under the byte limit, so parsing it is cheap and it keeps the normal path.
 */
import { isWellKnownLockfile, LARGE_DIFF_PATCH_BYTES } from "./deferred-diffs";

type ProcessFile = (patchText: string, options: { cacheKey: string; isGitDiff: boolean }) => any;

/** The patch text a deferred placeholder keeps until it is expanded. */
export const DEFERRED_PATCH_KEY = "cmuxDeferredPatchText";

export function deferredFileDiff(
  fileText: string,
  cacheKey: string,
  processFile: ProcessFile,
  isGeneratedPath: (path: string) => boolean,
): any | null {
  const firstHunk = fileText.startsWith("@@") ? 0 : fileText.indexOf("\n@@");
  if (firstHunk < 0) {
    // No hunks (binary, mode or pure rename): the parse is the header already.
    return null;
  }
  const large = fileText.length >= LARGE_DIFF_PATCH_BYTES;
  if (!large) {
    const path = headerPath(fileText.slice(0, firstHunk));
    if (path == null || !(isWellKnownLockfile(path) || isGeneratedPath(path))) {
      return null;
    }
  }
  const header = processFile(fileText.slice(0, firstHunk + 1), { cacheKey, isGitDiff: true });
  if (header == null || typeof header !== "object") {
    return null;
  }
  header.hunks = [];
  header.additionLines = [];
  header.deletionLines = [];
  header.cmuxDeferredStats = countChangedLines(fileText, firstHunk);
  header[DEFERRED_PATCH_KEY] = fileText;
  return header;
}

/** The new path from a git file header (`+++ b/path`, else `diff --git a/x b/path`). */
function headerPath(header: string): string | null {
  const plus = header.match(/^\+\+\+ (?:b\/)?(.+)$/m);
  if (plus != null && plus[1] !== "/dev/null") {
    return plus[1];
  }
  const git = header.match(/^diff --git a\/.+ b\/(.+)$/m);
  return git?.[1] ?? null;
}

/** Added and deleted lines after `from`, without splitting the text. */
export function countChangedLines(text: string, from: number): { added: number; deleted: number } {
  let added = 0;
  let deleted = 0;
  let index = from;
  while (index < text.length) {
    const start = text.charCodeAt(index) === 10 ? index + 1 : index;
    const first = text.charCodeAt(start);
    if (first === 43) {
      added += 1;
    } else if (first === 45) {
      deleted += 1;
    }
    const next = text.indexOf("\n", start);
    if (next < 0) {
      break;
    }
    index = next;
  }
  return { added, deleted };
}

/**
 * Parses a deferred placeholder's kept patch into the full file diff, keeping
 * the placeholder's identity fields (cache key, fingerprint, deferral
 * reason); null when `fileDiff` is not a deferred placeholder.
 */
export function hydrateDeferredFileDiff(fileDiff: any, processFile: ProcessFile): any | null {
  const text = fileDiff?.[DEFERRED_PATCH_KEY];
  if (typeof text !== "string") {
    return null;
  }
  const parsed = processFile(text, { cacheKey: fileDiff.cmuxBaseCacheKey ?? fileDiff.cacheKey, isGitDiff: true });
  if (parsed == null || typeof parsed !== "object") {
    return null;
  }
  const {
    [DEFERRED_PATCH_KEY]: _text,
    cmuxDeferredStats: _stats,
    hunks: _h,
    additionLines: _a,
    deletionLines: _d,
    ...identity
  } = fileDiff;
  // A cache key of its own: no worker result of the empty placeholder applies.
  const baseCacheKey = `${fileDiff.cmuxBaseCacheKey ?? fileDiff.cacheKey}:loaded`;
  return {
    ...parsed,
    ...identity,
    hunks: parsed.hunks,
    additionLines: parsed.additionLines,
    deletionLines: parsed.deletionLines,
    cmuxBaseCacheKey: baseCacheKey,
    cacheKey: baseCacheKey,
  };
}
