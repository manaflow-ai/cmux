import { describe, expect, test } from "bun:test";
import { IncrementalMarkdown } from "./incrementalMarkdown";
import { parseMarkdown } from "./Markdown";

const corpus = [
  "Hello **world**.\n\nSecond paragraph with `code` and a [link](https://example.com).\n\n# Heading\n\nTail text",
  "- one\n- two\n\n- three after a blank\n  - nested\n\nParagraph after the list.\n\n1. first\n2. second",
  "Intro\n\n```ts\nconst a = 1;\n\nconst b = 2;\n```\n\nAfter the fence.\n\n```\nunclosed fence\n\nstill code",
  "| a | b |\n| --- | :-: |\n| 1 | 2 |\n| 3 | 4 |\n\nAfter the table.\n\n> quoted\n> more\n\nend",
  "Math:\n\n\\[\nx = 1\n\ny = 2\n\\]\n\nInline \\(a+b\\) here.\n\n$$e = mc^2$$\n\n---\n\nDone.",
  "Line one\nline two\n\n   indented after blank\n\n- [ ] task\n- [x] done\n\nFinal",
];

/// The blocks without their keys, to compare with parseMarkdown.
const plain = (blocks: ReturnType<IncrementalMarkdown["update"]>) => blocks.map((entry) => entry.block);

describe("IncrementalMarkdown", () => {
  test("every streamed prefix parses exactly like the whole-text parser", () => {
    for (const source of corpus) {
      const incremental = new IncrementalMarkdown();
      for (let length = 0; length <= source.length; length += 1) {
        const prefix = source.slice(0, length);
        expect({ length, blocks: plain(incremental.update(prefix)) }).toEqual({ length, blocks: parseMarkdown(prefix) });
      }
    }
  });

  test("closed blocks keep their objects and keys while the tail streams", () => {
    const incremental = new IncrementalMarkdown();
    const first = incremental.update("Para one.\n\nPara two.\n\nTail");
    const second = incremental.update("Para one.\n\nPara two.\n\nTail grows");
    expect(second[0]).toBe(first[0]);
    expect(second[1]).toBe(first[1]);
    expect(second.map((entry) => entry.key)).toEqual(first.map((entry) => entry.key));
    expect(second[2]!.block).toEqual({ type: "paragraph", text: "Tail grows" });
  });

  test("a tail block keeps its key when it closes", () => {
    const incremental = new IncrementalMarkdown();
    const open = incremental.update("A\n\nB is streaming");
    const closed = incremental.update("A\n\nB is streaming\n\nC");
    expect(closed[1]!.key).toBe(open[1]!.key);
    expect(new Set(closed.map((entry) => entry.key)).size).toBe(closed.length);
  });

  test("only the tail is parsed again on a delta", () => {
    const incremental = new IncrementalMarkdown();
    const long = "Paragraph number one with words.\n\n".repeat(200);
    incremental.update(long + "tail");
    incremental.update(long + "tail and more");
    expect(incremental.lastParsedLength).toBeLessThan(40);
  });

  test("a text that is not a continuation (a superseded message) parses from scratch", () => {
    const incremental = new IncrementalMarkdown();
    incremental.update("Old first.\n\nOld second.\n\nx");
    expect(plain(incremental.update("New text"))).toEqual(parseMarkdown("New text"));
  });

  test("a blank line inside a fence or before a continuing list is not a boundary", () => {
    const incremental = new IncrementalMarkdown();
    const source = "```\na\n\nb\n```\n\n- x\n\n- y\n\nz";
    expect(plain(incremental.update(source))).toEqual(parseMarkdown(source));
    expect(incremental.update(source).filter((entry) => entry.block.type === "list")).toHaveLength(1);
  });
});
