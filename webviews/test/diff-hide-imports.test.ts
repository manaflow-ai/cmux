// Hide imports ("..." menu) leaves each import-only hunk out of a file's patch text before the page
// parses it, and a file whose only changes are imports out of the diff. A hunk that mixes imports
// and code stays whole: every kept hunk is the hunk git printed, so its Stage and Revert still
// match the host's own diff of the file.
import { expect, test } from "bun:test";
import { importSyntaxFor, isImportOnlyHunk, withoutImportOnlyHunks } from "../src/diff-viewer/importHunks";

const file = (path: string, ...hunks: string[]) =>
  `diff --git a/${path} b/${path}\nindex 1111111..2222222 100644\n--- a/${path}\n+++ b/${path}\n${hunks.join("")}`;

const importHunk =
  '@@ -1,3 +1,4 @@\n import { a } from "./a";\n+import { b } from "./b";\n import { c } from "./c";\n \n';
const codeHunk = "@@ -20,3 +21,3 @@ function f() {\n   const x = 1;\n-  return x;\n+  return x + 1;\n }\n";
const mixedHunk = '@@ -1,3 +1,4 @@\n+import { d } from "./d";\n-const y = 2;\n+const y = 3;\n \n';

test("each language has its own import lines", () => {
  const imports: [string, string][] = [
    ["src/a.ts", 'import { b } from "./b";'],
    ["src/a.tsx", "import React from 'react';"],
    ["src/a.js", 'const fs = require("node:fs");'],
    ["src/a.ts", 'export { x } from "./x";'],
    ["a.py", "from os import path"],
    ["a.py", "import json"],
    ["main.go", 'import "fmt"'],
    ["lib.rs", "use std::collections::HashMap;"],
    ["lib.rs", "pub(crate) use crate::thing;"],
    ["App.swift", "@testable import CmuxNext"],
    ["Main.java", "import java.util.List;"],
    ["a.c", "#include <stdio.h>"],
    ["A.m", "#import <Foundation/Foundation.h>"],
    ["A.cs", "using System.Linq;"],
    ["a.rb", "require_relative 'helper'"],
  ];
  for (const [path, line] of imports) expect([path, importSyntaxFor(path)?.line.test(line)]).toEqual([path, true]);
  const code: [string, string][] = [
    ["src/a.ts", "const important = 1;"],
    ["a.py", "imported = True"],
    ["lib.rs", "let used = 1;"],
    ["App.swift", "let imports = []"],
  ];
  for (const [path, line] of code) expect([path, importSyntaxFor(path)?.line.test(line)]).toEqual([path, false]);
  // No known syntax: nothing is ever hidden.
  expect(importSyntaxFor("README.md")).toBeUndefined();
  expect(importSyntaxFor("Makefile")).toBeUndefined();
});

test("an import-only hunk leaves the file's patch, and a code hunk stays as git printed it", () => {
  const text = file("src/app.ts", importHunk, codeHunk);
  expect(withoutImportOnlyHunks(text)).toBe(file("src/app.ts", codeHunk));
});

test("a hunk that mixes imports and code stays whole", () => {
  const text = file("src/app.ts", mixedHunk, codeHunk);
  expect(withoutImportOnlyHunks(text)).toBe(text);
});

test("a file whose only changes are imports leaves the diff", () => {
  expect(withoutImportOnlyHunks(file("src/app.ts", importHunk))).toBeNull();
});

test("the lines of a multi-line import count as the import", () => {
  const hunk = '@@ -1,2 +1,6 @@\n+import {\n+  alpha,\n+  beta as b,\n+} from "./greek";\n const z = 0;\n';
  expect(isImportOnlyHunk(hunk, importSyntaxFor("a.ts")!)).toBe(true);
  const python = "@@ -1,1 +1,4 @@\n+from x import (\n+    one,\n+    two,\n+)\n";
  expect(isImportOnlyHunk(python, importSyntaxFor("a.py")!)).toBe(true);
  const go = '@@ -1,3 +1,4 @@\n import (\n+\t"fmt"\n+\tstrs "strings"\n )\n';
  expect(isImportOnlyHunk(go, importSyntaxFor("main.go")!)).toBe(true);
});

test("a hunk of only blank lines is not an import hunk", () => {
  expect(isImportOnlyHunk("@@ -1,1 +1,2 @@\n a\n+\n", importSyntaxFor("a.ts")!)).toBe(false);
});

test("a deleted file uses its old path, and a file with no known language passes through", () => {
  const deleted =
    "diff --git a/old.py b/old.py\ndeleted file mode 100644\n--- a/old.py\n+++ /dev/null\n@@ -1,1 +0,0 @@\n-import os\n";
  expect(withoutImportOnlyHunks(deleted)).toBeNull();
  const readme = file("README.md", "@@ -1,1 +1,1 @@\n-import this\n+import that\n");
  expect(withoutImportOnlyHunks(readme)).toBe(readme);
});

test("the stream leaves a file whose only changes are imports out of the diff, and keeps the rest", async () => {
  const { streamPatch } = await import("../src/diff-stream");
  const { processFile, parsePatchFiles } = await import("@pierre/diffs");
  const { createDiffViewerLabelResolver, loadDiffViewerLabels } = await import("../src/labels");
  await loadDiffViewerLabels("en");
  const patch = file("src/imports.ts", importHunk) + file("src/code.ts", codeHunk);
  const saved = globalThis.fetch;
  const scope = globalThis as Record<string, unknown>;
  const savedDocument = Object.getOwnPropertyDescriptor(scope, "document");
  // A hidden page: the stream yields between batches through a message channel, not a frame.
  scope.document = { visibilityState: "hidden", hasFocus: () => false };
  globalThis.fetch = (async () => new Response(patch)) as unknown as typeof fetch;
  const names: string[] = [];
  try {
    await streamPatch({
      getCollapsed: () => false,
      initialFileTreeRowCount: 25,
      label: createDiffViewerLabelResolver(undefined, { language: "en" }),
      onBatch: (items) => names.push(...items.map((item) => item.fileDiff?.name)),
      onComplete: () => {},
      onMetrics: () => {},
      onRename: () => {},
      onTreeSource: () => {},
      parsePatchFiles: (text, key) => parsePatchFiles(text, key),
      patchURL: "cmux-page://cmux.diff/__patch/token/patch.diff",
      processFile: (text, options) => processFile(text, options),
      filterFileText: withoutImportOnlyHunks,
    });
  } finally {
    globalThis.fetch = saved;
    if (savedDocument) Object.defineProperty(scope, "document", savedDocument);
    else delete scope.document;
  }
  expect(names).toEqual(["src/code.ts"]);
});

test("a line shaped like an import's inside is code unless the hunk shows the import's end", () => {
  const ts = importSyntaxFor("a.ts")!;
  // An import beside an object shorthand rename: the rename is code, so the hunk stays.
  const shorthand =
    '@@ -1,6 +1,7 @@\n import { a } from "./a";\n+import { b } from "./b";\n \n const value = {\n-  oldName,\n+  newName,\n };\n';
  expect(isImportOnlyHunk(shorthand, ts)).toBe(false);
  // The block opens above the hunk's context, and its end shows: the lines are the import's.
  const openedAbove = '@@ -8,3 +8,4 @@\n   seven,\n+  eight,\n   nine,\n } from "./numbers";\n';
  expect(isImportOnlyHunk(openedAbove, ts)).toBe(true);
  // No end in view: kept.
  expect(isImportOnlyHunk("@@ -8,3 +8,4 @@\n   seven,\n+  eight,\n   nine,\n", ts)).toBe(false);
});
