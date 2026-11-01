// Pierre keeps a file's highlighted lines by `cacheKey` and treats two diffs with one key as the
// same diff (areDiffTargetsEqual). A key by the file's place alone ("cmux-diff-file-0") made a
// refreshed file (after a revert, a stage, Hide white space) reuse its old patch's highlight and
// fail with "deletionLine and additionLine are null". The key now carries the patch text's hash.
import { expect, test } from "bun:test";
import { diffFileCacheKey } from "../src/diff-stream";

const head = "diff --git a/README.md b/README.md\n--- a/README.md\n+++ b/README.md\n";
const before = head + "@@ -1,3 +1,4 @@\n # Readme\n \n Some text.\n+A new line.\n";
const after = head + "@@ -1,3 +1,6 @@\n # Readme\n \n Some text.\n+A new line.\n+staged line\n+unstaged line\n";

test("a file whose patch changed gets a new cache key at the same place", () => {
  expect(diffFileCacheKey(0, after)).not.toBe(diffFileCacheKey(0, before));
});

test("the same patch at the same place keeps its key, so an unchanged file reuses its highlight", () => {
  expect(diffFileCacheKey(0, before)).toBe(diffFileCacheKey(0, before));
  expect(diffFileCacheKey(1, before)).not.toBe(diffFileCacheKey(0, before));
  expect(diffFileCacheKey(0, before)).toStartWith("cmux-diff-file-0-");
});
