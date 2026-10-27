import { expect, test } from "bun:test";
import type { TurnFile } from "../src/agent-session/acpmux/diff";
import {
  diffFileFingerprint,
  diffFileViewedState,
  observeDiffPanelSize,
  viewedSourceKey,
} from "../src/agent-session/acpmux/diffPanelState";
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
