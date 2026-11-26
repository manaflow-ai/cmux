// l10n-allow-file: geometry fixtures, not shipped UI.
// A streaming reply's height estimate (model.ts measuredRowHeight) measures only the blocks that
// closed since the last delta and its tail: a delta into a 20,000-word reply measured each of its
// hundreds of blocks again, so the transcript's layout cost grew with the reply. The estimate is
// the same as a fresh measure of the whole reply.
import { expect, test } from "bun:test";
import { layoutConversation, type AcpmuxRow, type PreparedRow } from "./model";
import { streamedReply } from "./loadFixture";

const reply = (text: string, version: number): AcpmuxRow => ({ id: "a1", version, at: 0, kind: "assistant", text });

test("a delta into a 20,000-word reply measures its tail, and the estimate matches a fresh one", () => {
  let text = "";
  for (let turn = 1; text.split(" ").length < 20_000; turn += 1) text += streamedReply(turn, 400);
  const cache = new Map<string, PreparedRow>();
  layoutConversation([reply(text, 1)], 720, cache);
  const words = [" more", " words", " arrive", "\n\nA new paragraph starts", " and grows", " a line longer."];
  words.forEach((word, index) => {
    text += word;
    const streamed = layoutConversation([reply(text, index + 2)], 720, cache);
    const entry = cache.get("a1")!;
    expect(entry.blocks.length).toBeGreaterThan(300);
    // The blocks that closed with this delta and the tail's, never the hundreds before them.
    expect(entry.measuredBlocks).toBeLessThanOrEqual(3);
    const fresh = layoutConversation([reply(text, index + 2)], 720);
    expect(streamed.heights[0]).toBeCloseTo(fresh.heights[0]!, 6);
  });
  // Another width measures every block again, at that width.
  const narrow = layoutConversation([reply(text, 99)], 500, cache);
  expect(cache.get("a1")!.measuredBlocks).toBe(cache.get("a1")!.blocks.length);
  expect(narrow.heights[0]).toBeCloseTo(layoutConversation([reply(text, 99)], 500).heights[0]!, 6);
});

test("a reply replaced by another text measures the new text whole", () => {
  const cache = new Map<string, PreparedRow>();
  const first = "First paragraph of the reply.\n\nSecond paragraph.\n\nThird, still";
  layoutConversation([reply(first, 1)], 720, cache);
  const other = "Another reply entirely, with one paragraph that runs on and on.\n\nAnd a second one.\n\nTail";
  const replaced = layoutConversation([reply(other, 2)], 720, cache);
  expect(replaced.heights[0]).toBeCloseTo(layoutConversation([reply(other, 2)], 720).heights[0]!, 6);
});
