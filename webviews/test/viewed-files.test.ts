import { expect, test } from "bun:test";
import {
  applyLoadedViewed,
  beginViewedLoad,
  fileDiffFingerprint,
  formatViewedProgress,
  patchFingerprint,
  recordViewedChange,
  toggleViewedItem,
  viewedFileState,
  viewedProgress,
  viewedScopeFor,
} from "../src/viewed-files";

const patchA = `diff --git a/a.txt b/a.txt
index 1111111..2222222 100644
--- a/a.txt
+++ b/a.txt
@@ -1,2 +1,3 @@
 one
+two
 three
`;

test("patchFingerprint hashes the hunk text and ignores the index line", () => {
  const fingerprint = patchFingerprint(patchA);
  expect(fingerprint).toMatch(/^[0-9a-f]{8}$/);
  expect(patchFingerprint(patchA.replace("1111111..2222222", "aaaaaaa..bbbbbbb"))).toBe(fingerprint);
  expect(patchFingerprint(patchA.replace("+two", "+two!"))).not.toBe(fingerprint);
  // A binary or hunk-less patch still gets a stable fingerprint.
  const binary = "diff --git a/x.png b/x.png\nindex 1..2\nBinary files differ\n";
  expect(patchFingerprint(binary)).toBe(patchFingerprint(binary));
  expect(patchFingerprint(binary)).not.toBe(fingerprint);
});

test("fileDiffFingerprint prefers the streamed patch fingerprint and falls back to hunk content", () => {
  expect(fileDiffFingerprint({ cmuxPatchFingerprint: "deadbeef", hunks: [] })).toBe("deadbeef");
  const hunks = [{ additionStart: 1, additionCount: 1, deletionStart: 1, deletionCount: 0, hunkContent: [{ type: "change", lines: ["+x"] }] }];
  const fallback = fileDiffFingerprint({ name: "a.txt", hunks });
  expect(fallback).toMatch(/^[0-9a-f]{8}$/);
  expect(fileDiffFingerprint({ name: "a.txt", hunks: [{ ...hunks[0], additionStart: 2 }] })).not.toBe(fallback);
});

test("viewedFileState reports viewed, changed since viewed, or unviewed", () => {
  expect(viewedFileState(undefined, "abc")).toBe("unviewed");
  expect(viewedFileState({ path: "a.txt", fingerprint: "abc" }, "abc")).toBe("viewed");
  expect(viewedFileState({ path: "a.txt", fingerprint: "abc" }, "def")).toBe("changed");
});

test("viewedScopeFor keys typed git sources by repo and source identity", () => {
  expect(viewedScopeFor({ kind: "unstaged", repoRoot: "/tmp/repo" }, {})).toEqual({ repoRoot: "/tmp/repo", source: "unstaged" });
  expect(viewedScopeFor({ kind: "staged", repoRoot: "/tmp/repo" }, {})).toEqual({ repoRoot: "/tmp/repo", source: "staged" });
  expect(viewedScopeFor({ kind: "branch", repoRoot: "/tmp/repo", baseRef: "main" }, {}))
    .toEqual({ repoRoot: "/tmp/repo", source: "branch:main" });
  // An unresolved branch base has no stable identity yet.
  expect(viewedScopeFor({ kind: "branch", repoRoot: "/tmp/repo" }, {})).toBeNull();
  // Patch sessions and remote PR pages key on the patch path or the external URL.
  expect(viewedScopeFor({ kind: "patch", path: "/last-turn.patch" }, { repoRoot: "/tmp/repo" }))
    .toEqual({ repoRoot: "/tmp/repo", source: "patch:/last-turn.patch" });
  expect(viewedScopeFor(null, { externalURL: "https://github.com/o/r/pull/1", patchURL: "http://127.0.0.1/x.patch" }))
    .toEqual({ repoRoot: "https://github.com/o/r/pull/1", source: "external" });
  expect(viewedScopeFor(null, {})).toBeNull();
});

test("viewedProgress counts only files whose stored fingerprint still matches", () => {
  const items = [
    { id: "a.txt", fileDiff: { name: "a.txt", cmuxPatchFingerprint: "aaa", hunks: [] } },
    { id: "b.txt", fileDiff: { name: "b.txt", cmuxPatchFingerprint: "bbb", hunks: [] } },
    { id: "c.txt", fileDiff: { name: "c.txt", cmuxPatchFingerprint: "ccc", hunks: [] } },
  ];
  const viewedByPath = new Map([
    ["a.txt", { path: "a.txt", fingerprint: "aaa" }],
    ["b.txt", { path: "b.txt", fingerprint: "stale" }],
  ]);
  expect(viewedProgress(items, viewedByPath)).toEqual({ viewed: 1, total: 3 });
  expect(formatViewedProgress("{viewed} of {total} files viewed", { viewed: 1, total: 3 })).toBe("1 of 3 files viewed");
});

test("toggleViewedItem collapses a viewed file, expands an unviewed one, and reports the persistence change", () => {
  const items = [
    { id: "a.txt", type: "diff", version: 0, collapsed: false, fileDiff: { name: "a.txt", cmuxPatchFingerprint: "aaa", hunks: [] } },
    { id: "b.txt", type: "diff", version: 0, collapsed: false, fileDiff: { name: "b.txt", cmuxPatchFingerprint: "bbb", hunks: [] } },
  ];
  const marked = toggleViewedItem(items, new Map(), "a.txt");
  expect(marked.change).toEqual({ kind: "set", entry: { path: "a.txt", fingerprint: "aaa" } });
  expect(marked.viewedByPath.get("a.txt")).toEqual({ path: "a.txt", fingerprint: "aaa" });
  expect(marked.items[0]).toMatchObject({ id: "a.txt", collapsed: true, version: 1 });
  expect(marked.items[1]).toBe(items[1]);

  // A file whose patch changed since it was viewed is "changed"; toggling it
  // re-marks it viewed with the new fingerprint instead of clearing it.
  const stale = new Map([["b.txt", { path: "b.txt", fingerprint: "old" }]]);
  const remarked = toggleViewedItem(items, stale, "b.txt");
  expect(remarked.change).toEqual({ kind: "set", entry: { path: "b.txt", fingerprint: "bbb" } });
  expect(remarked.items[1]).toMatchObject({ collapsed: true, version: 1 });

  const cleared = toggleViewedItem(marked.items, marked.viewedByPath, "a.txt");
  expect(cleared.change).toEqual({ kind: "clear", path: "a.txt" });
  expect(cleared.viewedByPath.has("a.txt")).toBe(false);
  expect(cleared.items[0]).toMatchObject({ collapsed: false, version: 2 });

  expect(toggleViewedItem(items, new Map(), "missing.txt").change).toBeNull();
});

test("a stored-marks reply keeps toggles made while it was loading", () => {
  let session = beginViewedLoad("repo\nunstaged");
  session = recordViewedChange(session, { kind: "set", entry: { path: "a.txt", fingerprint: "new-a" } });
  session = recordViewedChange(session, { kind: "clear", path: "b.txt" });

  const merged = applyLoadedViewed(session, "repo\nunstaged", [
    { path: "a.txt", fingerprint: "old-a" },
    { path: "b.txt", fingerprint: "b" },
    { path: "c.txt", fingerprint: "c" },
  ]);

  expect(merged).not.toBeNull();
  expect([...merged!.viewedByPath.values()]).toEqual([
    { path: "a.txt", fingerprint: "new-a" },
    { path: "c.txt", fingerprint: "c" },
  ]);
});

test("a stored-marks reply for an older scope is ignored", () => {
  const session = beginViewedLoad("repo\nstaged");
  expect(applyLoadedViewed(session, "repo\nunstaged", [{ path: "a.txt", fingerprint: "a" }])).toBeNull();
});

test("starting a scope load drops the previous scope's marks at once", () => {
  const previous = applyLoadedViewed(beginViewedLoad("repo\nunstaged"), "repo\nunstaged", [{ path: "a.txt", fingerprint: "a" }]);
  expect(previous!.viewedByPath.size).toBe(1);
  const next = beginViewedLoad("repo\nstaged");
  expect(next.viewedByPath.size).toBe(0);
  expect(next.scopeKey).toBe("repo\nstaged");
});

test("the fallback fingerprint is computed once per parsed file diff", () => {
  let reads = 0;
  const hunk = { deletionStart: 1, deletionCount: 1, additionStart: 1, additionCount: 1, hunkContent: [] as unknown[] };
  const fileDiff = { name: "a.txt", type: "change", get hunks() { reads += 1; return [hunk]; } };
  const first = fileDiffFingerprint(fileDiff);
  const readsForFirst = reads;
  expect(readsForFirst).toBeGreaterThan(0);
  expect(fileDiffFingerprint(fileDiff)).toBe(first);
  expect(reads).toBe(readsForFirst);
});
