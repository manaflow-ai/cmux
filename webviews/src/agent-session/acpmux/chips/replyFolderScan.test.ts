// A streaming reply's folder and footnote scans read only its new text (ReplyFolderScan,
// FootnoteScan) and give what the whole-text scans give at every length.
import { expect, test } from "bun:test";
import { ReplyFolderScan, replyFolders } from "./replyFolders";
import { FootnoteScan, footnoteOrder } from "../conversation/markdownModel";

const REPLY = [
  "I changed `src/app/main.ts` and [the notes](docs/notes/today.md) beside it.",
  "The build in /Users/me/build/out/ failed; see ./logs/run/last.log:12 for the line.",
  "A footnote here[^a] and in code `[^b]` and again [^c] with [`x`^d] after.",
  "```",
  "const re = /[^a-z]/; // [^skip]",
  "```",
  "Then web/src/x/y.tsx:40 and tools/bin/run.sh:3, and lib/z/w.rs:1 at the end[^a].",
  "[^a]: The first note.",
].join("\n");

test("the incremental scans match the whole-text scans at every prefix", () => {
  const folders = new ReplyFolderScan();
  const notes = new FootnoteScan();
  for (let length = 0; length <= REPLY.length; length += 1) {
    const source = REPLY.slice(0, length);
    expect([...folders.update(source)]).toEqual([...replyFolders(source)]);
    expect([...notes.update(source)]).toEqual(footnoteOrder(source));
  }
  // A text that is not the last one grown (a replaced body) starts over.
  const other = "Only tools/other/file.ts here.";
  expect([...folders.update(other)]).toEqual([...replyFolders(other)]);
  expect([...notes.update(other)]).toEqual(footnoteOrder(other));
});
