import { describe, expect, test } from "bun:test";
import { IncrementalMarkdown } from "./incrementalMarkdown";

// A fling over a long chat mounts each reply it passes; every mount parsed the reply's whole text
// again on the frame that showed it. A finished text parses once.
describe("IncrementalMarkdown whole parses", () => {
  const text = "Answer.\n\n- one\n- two\n\n```ts\nlet x = 1\n```\n\nLast paragraph.";

  test("a row mounted again reads the blocks its text parsed to", () => {
    const first = new IncrementalMarkdown();
    const drawn = first.update(text, { messageAt: 7 });
    expect(first.lastParsedLength).toBeGreaterThan(0);
    const again = new IncrementalMarkdown();
    const redrawn = again.update(text, { messageAt: 7 });
    expect(again.lastParsedLength).toBe(0);
    expect(redrawn.map((entry) => entry.block)).toEqual(drawn.map((entry) => entry.block));
    expect(redrawn.map((entry) => entry.key)).toEqual(drawn.map((entry) => entry.key));
    expect(again.fenceOpen).toBe(first.fenceOpen);
  });

  test("another time stamp or a streaming text parses again", () => {
    new IncrementalMarkdown().update(text, { messageAt: 7 });
    const other = new IncrementalMarkdown();
    other.update(text, { messageAt: 8 });
    expect(other.lastParsedLength).toBeGreaterThan(0);
    const streaming = new IncrementalMarkdown();
    streaming.update(text, { messageAt: 7, streaming: true });
    expect(streaming.lastParsedLength).toBeGreaterThan(0);
  });

  test("a parser restored from a known text goes on as one that parsed it", () => {
    const more = `${text}\n\nA new paragraph.`;
    new IncrementalMarkdown().update(text, { messageAt: 9 });
    const restored = new IncrementalMarkdown();
    restored.update(text, { messageAt: 9 });
    const grown = restored.update(more, { messageAt: 9 });
    const whole = new IncrementalMarkdown().update(more, { messageAt: 10 });
    expect(grown.map((entry) => entry.key)).toEqual(whole.map((entry) => entry.key));
    expect(grown.length).toBe(whole.length);
    // A restored parser's arrays are its own: growing it leaves the known parse as it was.
    expect(new IncrementalMarkdown().update(text, { messageAt: 9 }).length).toBe(grown.length - 1);
  });
});
