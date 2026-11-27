import { describe, expect, test } from "bun:test";
import { quoteLines, type QuoteSourceMap } from "../src/pages/markdown/selectionQuote";

// A source map like the Markdown page's: each block's text range and its top-level nodes.
function map(text: string, blocks: [number, number, number][]): QuoteSourceMap {
  return { text, blocks: blocks.map(([start, end, nodes]) => ({ start, end, nodes: Array(nodes).fill(0) })) };
}

const source = "# Title\n\nFirst paragraph\nstill first.\n\n- one\n- two\n- three\n\nLast.\n";
//               line 1  2  3               4             5  6     7     8       9  10
// Each block: its text's offsets in `source` and one top-level node.
const at = (text: string): [number, number, number] => [source.indexOf(text), source.indexOf(text) + text.length, 1];
const blocks = [at("# Title"), at("First paragraph\nstill first."), at("- one\n- two\n- three"), at("Last.")];

describe("quoteLines", () => {
  test("a selection inside one paragraph line maps to that line", () => {
    expect(quoteLines(map(source, blocks), 1, 1, "still first")).toEqual({ startLine: 4, endLine: 4 });
  });

  test("a selection across blocks spans from the first to the last line it touches", () => {
    expect(quoteLines(map(source, blocks), 1, 2, "first.\none\ntwo")).toEqual({ startLine: 4, endLine: 7 });
  });

  test("text the source writes differently falls back to the whole block", () => {
    expect(quoteLines(map(source, blocks), 2, 2, "ONE\nTHREE")).toEqual({ startLine: 6, endLine: 8 });
  });

  test("a block of several nodes maps each node index to it", () => {
    const multi = map("a\nb\n\nc\n", [
      [0, 3, 2],
      [5, 6, 1],
    ]);
    expect(quoteLines(multi, 1, 2, "b\nc")).toEqual({ startLine: 2, endLine: 4 });
  });

  test("an index past the map is null", () => {
    expect(quoteLines(map(source, blocks), 0, 9, "x")).toBeNull();
  });
});
