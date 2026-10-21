import { expect, test } from "bun:test";
import { footnoteOrder } from "../src/agent-session/acpmux/conversation/Markdown";
import { IncrementalMarkdown } from "../src/agent-session/acpmux/conversation/incrementalMarkdown";

// A streaming reply re-renders on every reveal frame. These pin that the per-frame shortcuts
// (the parser's fence count, footnoteOrder's early exit, one block comparison) answer exactly
// what the whole-text scans answered.

const fixtures = [
  "Intro paragraph.\n\n```ts\nconst a = 1;\n```\n\nAfter the fence.\n\n```\nopen fence that never closes\nmore",
  "- item\n\n  ```sh\n  indented fence in a list\n  ```\n\n- next item\n\nText\n\n   ```\nthree-space fence\n```\n",
  "$$\n```\n$$\n\nDisplay math holding a fence line.\n\n```py\nprint(1)\n```\n\n\\[\n```\n\\]\n\nend",
  "CRLF line\r\n\r\n```js\r\nlet x;\r\n```\r\n\r\nParagraph\r\n\r\n```\r\nopen",
  "Blank lines then a fence:\n\n\n\n```\ncode\n```\n\n  \n```\nsecond\n```\n\nInline ``` not a fence line.\n\n``````\nsix\n",
];

const wholeTextFenceOpen = (text: string) => (text.match(/^\s*```/gm)?.length ?? 0) % 2 === 1;

for (const [index, fixture] of fixtures.entries()) {
  test(`fenceOpen matches the whole-text count at every prefix: fixture ${index}`, () => {
    const parser = new IncrementalMarkdown();
    for (let end = 0; end <= fixture.length; end++) {
      const prefix = fixture.slice(0, end);
      parser.update(prefix, { streaming: true });
      expect([end, parser.fenceOpen]).toEqual([end, wholeTextFenceOpen(prefix)]);
    }
  });
}

test("fenceOpen follows a source that is replaced rather than extended", () => {
  // The first source closes an odd count (the fence line inside `$$`), so a count left over from
  // it would flip the answer for the second.
  const parser = new IncrementalMarkdown();
  const first = "$$\n```\n$$\n\nNext\n\nTail";
  parser.update(first, { streaming: true });
  expect(parser.fenceOpen).toBe(wholeTextFenceOpen(first));
  parser.update("Other\n\nno fences here", { streaming: true });
  expect(parser.fenceOpen).toBe(false);
});

test("an unchanged tail block keeps its object across frames", () => {
  const parser = new IncrementalMarkdown();
  const first = parser.update("Done paragraph.\n\nStill streaming", { streaming: false });
  const second = parser.update("Done paragraph.\n\nStill streaming", { streaming: true });
  const third = parser.update("Done paragraph.\n\nStill streaming more", { streaming: true });
  expect(second[0]).toBe(first[0]);
  expect(third[0]).toBe(first[0]);
  expect(third.at(-1)).not.toBe(second.at(-1));
});

test("footnoteOrder's early exit returns what the full scan returns", () => {
  const sources = [
    "No footnotes at all.",
    "A caret ^ but no bracket.",
    "A [bracket] but no caret.",
    "First[^b] then[^a] and[^b] again.\n\n[^a]: note a\n[^b]: note b",
    "Code removal joins them: [`x`^joined] here.",
    "```\n[^in-code]\n```\n\nOutside[^out].",
    "Inline `[^code]` is skipped, [^kept] is not.",
  ];
  const fullScan = (source: string) => {
    const prose = source.replace(/^\s*```[\s\S]*?(?:^\s*```|(?![\s\S]))/gm, "").replace(/(`+)[^`]*?\1/g, "");
    const ids: string[] = [];
    for (const match of prose.matchAll(/\[\^([\w-]+)\](?!:)/g)) {
      const id = match[1]!;
      if (!/^\w-\w$/.test(id) && !ids.includes(id)) ids.push(id);
    }
    return ids;
  };
  for (const source of sources) expect([source, footnoteOrder(source)]).toEqual([source, fullScan(source)]);
});
