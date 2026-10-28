import { expect, test } from "bun:test";
import type { TurnFile } from "../src/agent-session/acpmux/diff";
import {
  diffFileFingerprint,
  diffFileViewedState,
  isCurrentViewedRequest,
  nextViewedRequest,
  observeDiffPanelSize,
  viewedSourceKey,
} from "../src/agent-session/acpmux/diffPanelState";
import { changeSetFiles, readChangeSet } from "../src/agent-session/acpmux/changes/model";
import { applyLoadedViewed, beginViewedLoad, recordViewedChange } from "../src/viewed-files";

const file = (patch?: string): TurnFile => ({
  path: "/repo/src/a.txt",
  displayPath: "src/a.txt",
  edits: [
    {
      toolId: "git",
      numbered: true,
      hunks: [
        {
          lines: [
            { type: "del", text: "old" },
            { type: "add", text: "new" },
          ],
        },
      ],
    },
  ],
  additions: 1,
  deletions: 1,
  created: false,
  patch,
});

test("the pane uses the shared branch scope for uncommitted marks", () => {
  expect(viewedSourceKey("uncommitted")).toBe("branch:HEAD");
  expect(viewedSourceKey("branch", "main")).toBe("branch:main");
  expect(viewedSourceKey("branch")).toBe("branch:HEAD");
  expect(viewedSourceKey("staged")).toBe("staged");
});

test("blob fingerprints survive hunk reshaping and detect changed blobs", () => {
  const header = [
    "diff --git a/src/a.txt b/src/a.txt",
    "index 1111111..2222222 100644",
    "--- a/src/a.txt",
    "+++ b/src/a.txt",
  ].join("\n");
  const first = file(`${header}\n@@ -1 +1 @@\n-old\n+new\n`);
  const sameBlob = file(`${header}\n@@ -1,2 +1,2 @@\n-old\n+new\n context\n`);
  const changedBlob = file(first.patch!.replace("2222222", "3333333"));
  const entry = { path: "src/a.txt", fingerprint: diffFileFingerprint(first) };
  expect(diffFileFingerprint(sameBlob)).toBe(entry.fingerprint);
  expect(diffFileViewedState(entry, sameBlob)).toBe("viewed");
  expect(diffFileViewedState(entry, changedBlob)).toBe("changed");
});

test("native hunk-only and binary summaries carry the full viewer blob identity", () => {
  const native = readChangeSet(
    {
      root: "/repo",
      files: [
        {
          path: "src/a.txt",
          status: "modified",
          additions: 1,
          deletions: 1,
          patch: "@@ -1 +1 @@\n-old\n+new\n",
          blob_fingerprint: "blob:aaaa1111",
        },
        {
          path: "assets/logo.png",
          status: "modified",
          additions: 0,
          deletions: 0,
          binary: true,
          blob_fingerprint: "blob:bbbb2222",
        },
      ],
    },
    "uncommitted",
  )!;
  const files = changeSetFiles(native);
  expect(files[0]!.edits[0]!.hunks).toHaveLength(1);
  expect(files[0]!.patch).toStartWith("@@");
  expect(diffFileFingerprint(files[0]!)).toBe("blob:aaaa1111");
  expect(diffFileViewedState({ path: files[0]!.displayPath, fingerprint: "blob:aaaa1111" }, files[0]!)).toBe("viewed");
  expect(files[1]!.patch).toBeUndefined();
  expect(diffFileFingerprint(files[1]!)).toBe("blob:bbbb2222");
  expect(diffFileViewedState({ path: files[1]!.displayPath, fingerprint: "blob:bbbb2222" }, files[1]!)).toBe("viewed");
});

test("native binary without an identity never revives a persisted path mark", () => {
  const binary = { ...file(), binary: true, edits: [{ toolId: "git", numbered: true, hunks: [] }] };
  const oldPathMark = { path: binary.displayPath, fingerprint: patchFingerprintForTest(`file:${binary.displayPath}`) };
  expect(diffFileViewedState(oldPathMark, binary)).toBe("changed");
  expect(diffFileViewedState(undefined, binary)).toBe("unviewed");
});

test("unmarked files never compute legacy hashes, including after a refresh", () => {
  let legacyHashCalls = 0;
  for (let refresh = 0; refresh < 3; refresh += 1) {
    const unmarked = { ...file(), blobFingerprint: "blob:native" };
    Object.defineProperty(unmarked, "edits", {
      get: () => {
        legacyHashCalls += 1;
        return file().edits;
      },
    });
    expect(diffFileViewedState(undefined, unmarked)).toBe("unviewed");
    expect(legacyHashCalls).toBe(0);
  }
});

test("legacy hunk identity is computed once and only after the primary identity misses", () => {
  let reads = 0;
  const cached = { ...file(), blobFingerprint: "blob:native" };
  Object.defineProperty(cached, "edits", {
    configurable: true,
    get: () => {
      reads += 1;
      return file().edits;
    },
  });
  const primary = diffFileFingerprint(cached);
  expect(reads).toBe(0);
  expect(diffFileViewedState({ path: cached.displayPath, fingerprint: primary }, cached)).toBe("viewed");
  expect(reads).toBe(0);
  expect(diffFileViewedState({ path: cached.displayPath, fingerprint: "legacy" }, cached)).toBe("changed");
  expect(reads).toBe(1);
  expect(diffFileViewedState({ path: cached.displayPath, fingerprint: "legacy" }, cached)).toBe("changed");
  expect(reads).toBe(1);
});

function patchFingerprintForTest(text: string): string {
  let hash = 0x811c9dc5;
  for (let index = 0; index < text.length; index += 1)
    hash = Math.imul(hash ^ text.charCodeAt(index), 0x01000193) >>> 0;
  return hash.toString(16).padStart(8, "0");
}

test("a slow native viewed reply preserves local toggles and rejects stale scopes", () => {
  const started = beginViewedLoad("/repo\nbranch:HEAD");
  const marked = recordViewedChange(started, {
    kind: "set",
    entry: { path: "src/a.txt", fingerprint: "local" },
  });
  const merged = applyLoadedViewed(marked, "/repo\nbranch:HEAD", [
    { path: "src/a.txt", fingerprint: "native-old" },
    { path: "src/b.txt", fingerprint: "native" },
  ]);
  expect(merged?.viewedByPath.get("src/a.txt")?.fingerprint).toBe("local");
  expect(merged?.viewedByPath.get("src/b.txt")?.fingerprint).toBe("native");
  expect(applyLoadedViewed(marked, "/repo\nbranch:main", [])).toBeNull();
});

test("same-key replies use the newest request after leaving and returning", () => {
  const generations = new Map<string, number>();
  const a1 = nextViewedRequest(generations, "repo\nbranch:HEAD");
  const b = nextViewedRequest(generations, "repo\nbranch:main");
  const a2 = nextViewedRequest(generations, "repo\nbranch:HEAD");
  expect(isCurrentViewedRequest(generations, "repo\nbranch:HEAD", a1)).toBe(false);
  expect(isCurrentViewedRequest(generations, "repo\nbranch:HEAD", a2)).toBe(true);
  expect(isCurrentViewedRequest(generations, "repo\nbranch:main", b)).toBe(true);
});

test("the resize observer is measured once and disconnected on cleanup", () => {
  const scope = globalThis as unknown as { ResizeObserver?: typeof ResizeObserver };
  const previous = scope.ResizeObserver;
  let disconnects = 0;
  let observes = 0;
  let callback: (() => void) | undefined;
  class FakeResizeObserver {
    constructor(next: () => void) {
      callback = next;
    }
    observe() {
      observes += 1;
    }
    disconnect() {
      disconnects += 1;
    }
  }
  Object.defineProperty(scope, "ResizeObserver", { configurable: true, value: FakeResizeObserver });
  try {
    const widths: number[] = [];
    const node = { getBoundingClientRect: () => ({ width: 321 }) } as HTMLElement;
    const stop = observeDiffPanelSize(node, (width) => widths.push(width));
    expect(widths).toEqual([321]);
    expect(observes).toBe(1);
    callback?.();
    expect(widths).toEqual([321, 321]);
    stop();
    expect(disconnects).toBe(1);
  } finally {
    if (previous === undefined) delete scope.ResizeObserver;
    else Object.defineProperty(scope, "ResizeObserver", { configurable: true, value: previous });
  }
});
