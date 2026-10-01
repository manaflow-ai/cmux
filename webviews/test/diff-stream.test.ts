import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { streamPatch } from "../src/diff-stream";
import { createDiffViewerLabelResolver } from "../src/labels";

const originalGlobals = new Map<string, any>();
for (const key of ["document", "fetch", "window"]) {
  originalGlobals.set(key, (globalThis as any)[key]);
}

afterEach(() => {
  for (const [key, value] of originalGlobals) {
    if (value === undefined) {
      delete (globalThis as any)[key];
    } else {
      (globalThis as any)[key] = value;
    }
  }
});

test("streamPatch replaces already-flushed repeated-path items immutably", async () => {
  const dom = new JSDOM("<!doctype html><html><body></body></html>");
  (globalThis as any).document = dom.window.document;
  (globalThis as any).window = dom.window;
  (globalThis as any).fetch = () => Promise.resolve({
    ok: true,
    text: () => Promise.resolve("patch"),
  });
  dom.window.document.hasFocus = () => false;

  const label = createDiffViewerLabelResolver(undefined);
  const batches: any[][] = [];
  const renames: Array<{ oldId: string; newId: string }> = [];

  await streamPatch({
    getCollapsed: () => false,
    initialFileTreeRowCount: 1,
    label,
    onBatch: (items) => batches.push(items),
    onComplete: () => {},
    onMetrics: () => {},
    onRename: (rename) => renames.push(rename),
    onTreeSource: () => {},
    parsePatchFiles: () => [{
      files: [
        { name: "README.md", type: "modified", hunks: [] },
        { name: "README.md", type: "modified", hunks: [] },
      ],
    }],
    patchURL: "/patch.diff",
    processFile: (patchText) => ({ name: patchText, type: "modified", hunks: [] }),
  });

  expect(batches).toHaveLength(2);
  expect(renames).toEqual([{ oldId: "README.md", newId: "README.md?previous" }]);
  expect(batches[0][0].id).toBe("README.md");
  expect(batches[1][0].id).toBe("README.md?2");
});

test("streamPatch uses localized fallback for unnamed file tree paths", async () => {
  const dom = new JSDOM("<!doctype html><html><body></body></html>");
  (globalThis as any).document = dom.window.document;
  (globalThis as any).window = dom.window;
  (globalThis as any).fetch = () => Promise.resolve({
    ok: true,
    text: () => Promise.resolve("patch"),
  });
  dom.window.document.hasFocus = () => false;

  const label = createDiffViewerLabelResolver({ untitled: "Localized untitled" });
  const treePaths: string[][] = [];
  const treeSources: any[] = [];

  await streamPatch({
    getCollapsed: () => false,
    initialFileTreeRowCount: 1,
    label,
    onBatch: () => {},
    onComplete: () => {},
    onMetrics: () => {},
    onRename: () => {},
    onTreeSource: (source) => {
      treePaths.push(source.paths);
      treeSources.push(source);
    },
    parsePatchFiles: () => [{
      files: [
        { type: "modified", hunks: [] },
      ],
    }],
    patchURL: "/patch.diff",
    processFile: (patchText) => ({ name: patchText, type: "modified", hunks: [] }),
  });

  expect(treePaths.at(-1)).toEqual(["Localized untitled"]);
  expect(treeSources.at(-1)?.preparedInput).toBeUndefined();
});

test("streamPatch stops callbacks after its abort signal fires", async () => {
  const dom = new JSDOM("<!doctype html><html><body></body></html>");
  (globalThis as any).document = dom.window.document;
  (globalThis as any).window = dom.window;
  dom.window.document.hasFocus = () => false;
  const encoder = new TextEncoder();
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(encoder.encode("diff --git a/a.ts b/a.ts\n--- a/a.ts\n+++ b/a.ts\ndiff --git a/b.ts b/b.ts\n"));
      setTimeout(() => {
        controller.enqueue(encoder.encode("--- a/b.ts\n+++ b/b.ts\n"));
        controller.close();
      }, 0);
    },
  });
  (globalThis as any).fetch = () => Promise.resolve(new Response(stream, { status: 200 }));

  const controller = new AbortController();
  let batches = 0;
  let completed = 0;
  const options = {
    getCollapsed: () => false,
    initialFileTreeRowCount: 1,
    label: createDiffViewerLabelResolver(undefined),
    onBatch: () => {
      batches += 1;
      controller.abort();
    },
    onComplete: () => { completed += 1; },
    onMetrics: () => {},
    onRename: () => {},
    onTreeSource: () => {},
    parsePatchFiles: () => [],
    patchURL: "/patch.diff",
    processFile: () => ({ name: "unused", type: "modified", hunks: [] }),
    signal: controller.signal,
  };

  await streamPatch(options).catch(() => {});

  expect(batches).toBe(1);
  expect(completed).toBe(0);
  dom.window.close();
});

test("streamPatch publishes revision-stable tree snapshots", async () => {
  const dom = new JSDOM("<!doctype html><html><body></body></html>");
  (globalThis as any).document = dom.window.document;
  (globalThis as any).window = dom.window;
  (globalThis as any).fetch = () => Promise.resolve({
    ok: true,
    text: () => Promise.resolve("patch"),
  });
  dom.window.document.hasFocus = () => false;

  const treeSources: any[] = [];
  await streamPatch({
    getCollapsed: () => false,
    initialFileTreeRowCount: 1,
    label: createDiffViewerLabelResolver(undefined),
    onBatch: () => {},
    onComplete: () => {},
    onMetrics: () => {},
    onRename: () => {},
    onTreeSource: (source) => treeSources.push(source),
    parsePatchFiles: () => [{
      files: [
        { name: "a.ts", type: "new", hunks: [] },
        { name: "b.ts", type: "deleted", hunks: [] },
        { name: "c.ts", type: "change", hunks: [] },
      ],
    }],
    patchURL: "/patch.diff",
    processFile: (patchText) => ({ name: patchText, type: "modified", hunks: [] }),
  });

  expect(treeSources.map((source) => source.revision)).toEqual([1, 2]);
  expect(treeSources.map((source) => source.previousRevision)).toEqual([undefined, 1]);
  expect(treeSources.map((source) => source.pathCount)).toEqual([1, 3]);
  expect(treeSources[0].paths).not.toBe(treeSources[1].paths);
  expect(treeSources[0].pathToItemId).not.toBe(treeSources[1].pathToItemId);
  expect(treeSources[0].statsByPath).not.toBe(treeSources[1].statsByPath);
  expect(treeSources[0].treePathByItemId).not.toBe(treeSources[1].treePathByItemId);
  expect(treeSources[0].gitStatus).not.toBe(treeSources[1].gitStatus);
  expect(treeSources[0].paths).toEqual(["a.ts"]);
  expect(treeSources[0].gitStatus).toEqual([{ path: "a.ts", status: "added" }]);
  expect(treeSources[1].paths).toEqual(["a.ts", "b.ts", "c.ts"]);
  expect(treeSources[1].gitStatus).toEqual([
    { path: "a.ts", status: "added" },
    { path: "b.ts", status: "deleted" },
  ]);
});

test("streamPatch grows batches after first paint for large diffs", async () => {
  const dom = new JSDOM("<!doctype html><html><body></body></html>");
  (globalThis as any).document = dom.window.document;
  (globalThis as any).window = dom.window;
  (globalThis as any).fetch = () => Promise.resolve({
    ok: true,
    text: () => Promise.resolve("patch"),
  });
  dom.window.document.hasFocus = () => false;
  const files = Array.from({ length: 10_000 }, (_, index) => ({
    name: `src/file-${index}.ts`,
    type: "change",
    hunks: [],
  }));
  const batches: any[][] = [];
  let completedMetrics: any;

  await streamPatch({
    getCollapsed: () => false,
    initialFileTreeRowCount: 32,
    label: createDiffViewerLabelResolver(undefined),
    onBatch: (batch) => batches.push(batch),
    onComplete: (metrics) => {
      completedMetrics = metrics;
    },
    onMetrics: () => {},
    onRename: () => {},
    onTreeSource: () => {},
    parsePatchFiles: () => [{ files }],
    patchURL: "/patch.diff",
    processFile: (patchText) => ({ name: patchText, type: "change", hunks: [] }),
  });

  expect(batches[0]).toHaveLength(32);
  const renderedItems = batches.flat();
  expect(renderedItems).toHaveLength(10_000);
  expect(renderedItems.map((item) => item.id)).toEqual(files.map((file) => file.name));
  expect(completedMetrics.fileCount).toBe(10_000);
  expect(completedMetrics.flushCount).toBeLessThanOrEqual(8);
  expect(completedMetrics.maxBatchSize).toBeGreaterThanOrEqual(2_048);
  dom.window.close();
});

test("streamPatch replaces many repeated paths by stable file order", async () => {
  const dom = new JSDOM("<!doctype html><html><body></body></html>");
  (globalThis as any).document = dom.window.document;
  (globalThis as any).window = dom.window;
  (globalThis as any).fetch = () => Promise.resolve({ ok: true, text: () => Promise.resolve("patch") });
  dom.window.document.hasFocus = () => false;

  const batches: any[][] = [];
  await streamPatch({
    getCollapsed: () => false,
    initialFileTreeRowCount: 1,
    label: createDiffViewerLabelResolver(undefined),
    onBatch: (items) => batches.push(items),
    onComplete: () => {},
    onMetrics: () => {},
    onRename: () => {},
    onTreeSource: () => {},
    parsePatchFiles: () => [{ files: Array.from({ length: 2_000 }, () => ({ name: "repeat.ts", type: "change", hunks: [] })) }],
    patchURL: "/patch.diff",
    processFile: () => ({ name: "unused", type: "change", hunks: [] }),
  });

  expect(batches.reduce((count, batch) => count + batch.length, 0)).toBe(2_000);
  expect(batches.at(-1)?.at(-1)?.id).toBe("repeat.ts?2");
});

test("streamed file diffs carry a patch fingerprint and patch size for viewed state", async () => {
  const dom = new JSDOM("<!doctype html><html><body></body></html>");
  (globalThis as any).document = dom.window.document;
  (globalThis as any).window = dom.window;
  dom.window.document.hasFocus = () => false;
  const fileA = "diff --git a/a.txt b/a.txt\nindex 1111111..2222222 100644\n--- a/a.txt\n+++ b/a.txt\n@@ -1,2 +1,3 @@\n one\n+two\n three\n";
  const fileB = "diff --git a/b.txt b/b.txt\nnew file mode 100644\nindex 0000000..3333333\n--- /dev/null\n+++ b/b.txt\n@@ -0,0 +1 @@\n+hello\n";
  (globalThis as any).fetch = () => Promise.resolve(new Response(fileA + fileB, { status: 200 }));

  const items: any[] = [];
  await streamPatch({
    getCollapsed: () => false,
    initialFileTreeRowCount: 10,
    label: createDiffViewerLabelResolver(undefined),
    onBatch: (batch) => items.push(...batch),
    onComplete: () => {},
    onMetrics: () => {},
    onRename: () => {},
    onTreeSource: () => {},
    parsePatchFiles: () => [],
    patchURL: "http://127.0.0.1/p.patch",
    processFile: (text) => ({ name: /b\/(\S+)/.exec(text)?.[1] ?? "", type: "change", hunks: [], additionLines: [], deletionLines: [] }),
  });

  expect(items).toHaveLength(2);
  const fingerprints = items.map((item) => item.fileDiff.cmuxPatchFingerprint);
  expect(fingerprints[0]).toMatch(/^[0-9a-f]{8}$/);
  expect(fingerprints[1]).toMatch(/^[0-9a-f]{8}$/);
  expect(fingerprints[0]).not.toBe(fingerprints[1]);
  expect(items[0].fileDiff.cmuxPatchByteLength).toBeGreaterThan(0);
  expect(items[0].fileDiff.cmuxPatchByteLength).toBeLessThanOrEqual(fileA.length);
});
