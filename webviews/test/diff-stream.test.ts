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
