import { afterEach, expect, test } from "bun:test";
import { processFile } from "@pierre/diffs";
import { JSDOM } from "jsdom";
import { presentedItem } from "../src/App";
import { LARGE_DIFF_PATCH_BYTES } from "../src/deferred-diffs";
import {
  countChangedLines,
  deferredFileDiff,
  DEFERRED_PATCH_KEY,
  hydrateDeferredFileDiff,
} from "../src/deferred-parse";
import { fileStats, streamPatch, type DiffItem } from "../src/diff-stream";
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

/** A modified file of `count` lines with every `every`-th line replaced. */
function modifiedPatch(name: string, count: number, every: number): string {
  const body: string[] = [];
  for (let k = 0; k < count; k += 1) {
    if (k % every === 0) {
      body.push(`-const line_${k} = "before ${"x".repeat(40)}";`, `+const line_${k} = "after ${"y".repeat(40)}";`);
    } else {
      body.push(` const line_${k} = "same ${"z".repeat(40)}";`);
    }
  }
  return `diff --git a/${name} b/${name}\nindex 1111111..2222222 100644\n--- a/${name}\n+++ b/${name}\n@@ -1,${count} +1,${count} @@\n${body.join("\n")}\n`;
}

const largePatch = modifiedPatch("src/big.ts", 12_000, 3);
const smallPatch = modifiedPatch("src/small.ts", 40, 13);

test("a large file is not parsed: only its header, its counts and its kept patch text", () => {
  expect(largePatch.length).toBeGreaterThan(LARGE_DIFF_PATCH_BYTES);
  const calls: number[] = [];
  const spy = (text: string, options: { cacheKey: string; isGitDiff: boolean }) => {
    calls.push(text.length);
    return processFile(text, options);
  };
  const placeholder = deferredFileDiff(largePatch, "k", spy, () => false);
  expect(placeholder.name).toBe("src/big.ts");
  expect(placeholder.hunks).toEqual([]);
  expect(placeholder[DEFERRED_PATCH_KEY]).toBe(largePatch);
  expect(fileStats(placeholder)).toEqual({ added: 4000, deleted: 4000 });
  // The one parse covered only the header, not the 12,000 lines.
  expect(calls).toHaveLength(1);
  expect(calls[0]).toBeLessThan(200);

  // Opening it parses the kept text into the same diff a full parse gives.
  const full = processFile(largePatch, { cacheKey: "k", isGitDiff: true })!;
  const hydrated = hydrateDeferredFileDiff(placeholder, processFile);
  expect(hydrated.hunks.length).toBe(full.hunks.length);
  expect(hydrated.additionLines.length).toBe(full.additionLines.length);
  expect(fileStats(hydrated)).toEqual(fileStats(full));
  expect(hydrated[DEFERRED_PATCH_KEY]).toBeUndefined();
  expect(hydrated.cacheKey).not.toBe(placeholder.cacheKey);
});

test("small files and files with no hunks keep the normal parse; lockfiles defer", () => {
  expect(deferredFileDiff(smallPatch, "k", processFile, () => false)).toBeNull();
  const binary = "diff --git a/a.png b/a.png\nindex 1..2 100644\nBinary files a/a.png and b/a.png differ\n";
  expect(deferredFileDiff(binary, "k", processFile, () => false)).toBeNull();
  const lock = smallPatch.replaceAll("src/small.ts", "bun.lock");
  expect(deferredFileDiff(lock, "k", processFile, () => false)?.name).toBe("bun.lock");
  const generated = smallPatch.replaceAll("src/small.ts", "gen/schema.ts");
  expect(deferredFileDiff(generated, "k", processFile, (path) => path === "gen/schema.ts")?.name).toBe("gen/schema.ts");
});

test("changed lines are counted without splitting the patch", () => {
  const text = "@@ -1,3 +1,3 @@\n-a\n+b\n c\n+d\n";
  expect(countChangedLines(text, 0)).toEqual({ added: 2, deleted: 1 });
});

test("the stream never hands a large file's text to the full parser", async () => {
  const dom = new JSDOM("<!doctype html><html><body></body></html>");
  (globalThis as any).document = dom.window.document;
  (globalThis as any).window = dom.window;
  const patch = smallPatch + largePatch;
  (globalThis as any).fetch = () => Promise.resolve(new Response(patch, { status: 200 }));
  const parsed: number[] = [];
  const items: DiffItem[] = [];
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
    patchURL: "/patch.diff",
    processFile: (text, options) => {
      parsed.push(text.length);
      return processFile(text, options);
    },
  });
  expect(items.map((item) => item.id)).toEqual(["src/small.ts", "src/big.ts"]);
  expect(Math.max(...parsed)).toBeLessThan(LARGE_DIFF_PATCH_BYTES);
  expect(fileStats(items[1].fileDiff)).toEqual({ added: 4000, deleted: 4000 });
});

test("a collapsed file is presented to CodeView as plain text, stably, and an open one as is", () => {
  const fileDiff = { name: "a.ts", lang: "typescript", cacheKey: "a:typescript", hunks: [] };
  const collapsed = { id: "a.ts", type: "diff", collapsed: true, version: 1, fileDiff } as unknown as DiffItem;
  const presented = presentedItem(collapsed);
  expect(presented.fileDiff.lang).toBe("text");
  expect(presented.fileDiff.cacheKey).not.toBe("a:typescript");
  expect(presentedItem(collapsed)).toBe(presented);
  // The model item is untouched; expanding presents the real language.
  expect(fileDiff.lang).toBe("typescript");
  const open = { ...collapsed, collapsed: false, version: 2 } as DiffItem;
  expect(presentedItem(open)).toBe(open);
});
