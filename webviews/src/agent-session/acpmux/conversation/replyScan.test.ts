// l10n-allow-file: test fixture replies, not shipped UI.
// A streaming reply's footnote order and folders (replyScan.ts) read at the cost of its tail, with
// the same results as a scan of its whole text. The reveal draws the reply again on every display
// frame; reading its whole text each time made a frame cost more the longer the reply grew.
import { expect, test } from "bun:test";
import { IncrementalMarkdown } from "./incrementalMarkdown";
import { footnoteOrder } from "./markdownModel";
import { replyFolders } from "../chips/replyFolders";
import { ReplyScan } from "./replyScan";
import { streamedReply } from "../loadFixture";

/// Streams `text` in `step`-character deltas through the parser and the scan, checking each read
/// against the whole-text scans; returns the characters each read scanned.
function stream(text: string, step: number): number[] {
  const parser = new IncrementalMarkdown();
  const scan = new ReplyScan();
  const reads: number[] = [];
  for (let at = step; at < text.length + step; at += step) {
    const source = text.slice(0, at);
    parser.advance(source, { streaming: true });
    const read = scan.read(source, parser.closedState);
    expect(read.noteIds).toBe(footnoteOrder(source).join(" "));
    expect(read.folderKey).toBe(replyFolders(source).join("\n"));
    reads.push(scan.lastReadLength);
  }
  return reads;
}

test("each frame of a 20,000-word reply reads its tail, not the whole reply", () => {
  let text = "";
  for (let turn = 1; text.split(" ").length < 20_000; turn += 1) text += streamedReply(turn, 400);
  const parser = new IncrementalMarkdown();
  const scan = new ReplyScan();
  // The reply as the row first shows it, then a frame a word longer.
  parser.advance(text, { streaming: true });
  scan.read(text, parser.closedState);
  for (const word of [" more", " words", " arrive", "\n\nA new paragraph starts", " and grows."]) {
    text += word;
    parser.advance(text, { streaming: true });
    const read = scan.read(text, parser.closedState);
    expect(read.folderKey).toBe(replyFolders(text).join("\n"));
    expect(read.noteIds).toBe(footnoteOrder(text).join(" "));
    // Its newest paragraph, at most twice (folders and notes), never the 120 KB before it.
    expect(scan.lastReadLength).toBeLessThan(4_000);
    expect(text.length).toBeGreaterThan(100_000);
  }
});

test("folders and footnotes stream the same as a whole-text scan", () => {
  const text = [
    "Read [the plan](docs/plan.md) first.[^a]\n\n",
    "Then `src/app/main.ts` and webviews/src/ui/Button.tsx.\n\n",
    "A span `opens here\n\nand closes` past a blank line [^skipped] and a note.[^b]\n\n",
    "```ts\nconst x = [^not-a-note];\n```\n\n",
    "```\nan open fence [^inside]\n\nstill code\n```\n\n",
    "More paths: lib/one/a.rs, lib/two/b.rs, lib/three/c.rs.[^c]\n\n",
    "- item [^a] again\n- item [^d]\n\n",
    "[^a]: The first note.\n\n[^b]: The second.\n",
  ].join("");
  for (const step of [1, 3, 17]) stream(text, step);
});

test("a fence inside a $$ display and stray backticks still match the whole-text scan", () => {
  const text = [
    "$$\n```\n$$\n\nprose [^x] after\n\n",
    "one ` backtick [^y]\n\n",
    "and its pair ` then [^z]\n\n",
    "path/to/file.ts done.[^w]\n",
  ].join("");
  for (const step of [1, 5]) stream(text, step);
});

test("a reply that is replaced starts its scan over", () => {
  const parser = new IncrementalMarkdown();
  const scan = new ReplyScan();
  const first = "See /repo/a/one.ts.[^a]\n\nNext paragraph.\n\n";
  parser.advance(first, { streaming: true });
  scan.read(first, parser.closedState);
  const second = "Other /repo/b/two.ts.[^b]\n\nNext.\n\n";
  parser.advance(second, { streaming: true });
  const read = scan.read(second, parser.closedState);
  expect(read.folderKey).toBe("/repo/b/");
  expect(read.noteIds).toBe("b");
});
