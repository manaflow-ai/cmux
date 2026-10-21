// The streamed patch splitter (diff-stream.ts) returns one text per file whatever the chunking,
// and text that holds no file boundary stays out of its search buffer until one arrives (a
// 60 MB file streamed in 256 KB chunks was quadratic: every chunk flattened the whole buffer).
import { expect, test } from "bun:test";
import { createStreamingPatchFileSplitter } from "../src/diff-stream";

const file = (name: string, lines: number) =>
  `diff --git a/${name} b/${name}\n--- a/${name}\n+++ b/${name}\n@@ -1,${lines} +1,${lines} @@\n` +
  Array.from({ length: lines }, (_, k) => `-old ${k}\n+new ${k}`).join("\n") +
  "\n";

/** Pushes `patch` in `size`-character chunks, draining after each, as streamPatch does. */
function split(patch: string, size: number): string[] {
  const splitter = createStreamingPatchFileSplitter();
  const files: string[] = [];
  const drain = () => {
    let text: string | null;
    while ((text = splitter.takeAvailableFile()) != null) files.push(text);
  };
  for (let offset = 0; offset < patch.length; offset += size) {
    splitter.push(patch.slice(offset, offset + size));
    drain();
  }
  const last = splitter.finish();
  if (last.fileText != null) files.push(last.fileText);
  drain();
  return files;
}

test("every chunking yields the same files, a marker split across chunks included", () => {
  const files = [file("a.ts", 3), file("src/b.ts", 40), file("c.ts", 1), file("d/e.ts", 7)];
  const patch = files.join("");
  for (const size of [1, 2, 5, 11, 12, 13, 64, 1000, patch.length]) {
    expect(split(patch, size)).toEqual(files);
  }
});

test("a big file streamed in small chunks is returned once, whole, when the next file starts", () => {
  const big = file("dist/bundle.js", 20_000);
  const small = file("src/after.ts", 2);
  const splitter = createStreamingPatchFileSplitter();
  const taken: string[] = [];
  for (let offset = 0; offset < big.length; offset += 4096) {
    splitter.push(big.slice(offset, offset + 4096));
    let text: string | null;
    while ((text = splitter.takeAvailableFile()) != null) taken.push(text);
  }
  // Nothing to return while only the first file has arrived.
  expect(taken).toEqual([]);
  splitter.push(small);
  const first = splitter.takeAvailableFile();
  expect(first).toBe(big);
  expect(splitter.takeAvailableFile()).toBeNull();
  expect(splitter.finish().fileText).toBe(small);
});

test("a patch with no git headers falls back to the whole text", () => {
  const plain = "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n";
  const splitter = createStreamingPatchFileSplitter();
  for (const chunk of plain.match(/[\s\S]{1,4}/g) ?? []) splitter.push(chunk);
  expect(splitter.takeAvailableFile()).toBeNull();
  expect(splitter.finish()).toEqual({ fallbackPatchContent: plain });
});

test("commit headers between files still split where `git format-patch` puts them", () => {
  const commit = (hash: string) => `From ${hash} Mon Sep 17 00:00:00 2001\nSubject: change\n\n`;
  const patch = commit("a".repeat(40)) + file("one.ts", 2) + commit("b".repeat(40)) + file("two.ts", 2);
  const whole = split(patch, patch.length);
  for (const size of [3, 17, 50]) expect(split(patch, size)).toEqual(whole);
  expect(whole.length).toBe(2);
  expect(whole[1]!.startsWith("From ")).toBe(true);
});
