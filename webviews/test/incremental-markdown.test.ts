import { expect, test } from "bun:test";
import { footnoteOrder, parseMarkdown } from "../src/agent-session/acpmux/conversation/Markdown";
import { IncrementalMarkdown } from "../src/agent-session/acpmux/conversation/incrementalMarkdown";
import { safeTail } from "../src/agent-session/acpmux/conversation/safeTail";

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

// Markdown.tsx opens a fence on three or more backticks and closes it on a line of at least as many
// (a reply that quotes Markdown opens with four to show its own three); a line like "```x``` y" has
// backticks in its info string and opens nothing. The streaming helpers follow the same rule, or
// the text after such a line is cut into blocks the whole text never has.
const quoted = [
  "Intro.\n\n````md\n```js\nx\n\nstill inside the four-tick fence\n\n- not a list\n```\n````\n\nAfter.\n\n- real list",
  "Before.\n\n```x``` not a fence\n\n```\ncode\n\nmore code\n```\n\nAfter.",
  "Para.\n\n``````\n`````\ninner five\n\nstill code\n``````\n\nEnd.",
  "Math.\n\n````md\n```js\n$$\nx\n\n\\[ not an equation \\]\n```\n````\n\nAfter $$y$$ done.",
];

for (const [index, fixture] of quoted.entries()) {
  test(`an incremental parse equals the whole parse at every prefix: quoted fences ${index}`, () => {
    const parser = new IncrementalMarkdown();
    for (let end = 0; end <= fixture.length; end++) {
      const prefix = fixture.slice(0, end);
      const blocks = parser.update(prefix).map((entry) => entry.block);
      expect([end, blocks]).toEqual([end, parseMarkdown(prefix)]);
    }
  });
}

test("inside a four-backtick fence a line of three is code, and a list marker is not held back", () => {
  const tail = "````md\n```js\n- ";
  expect(safeTail(tail)).toBe(tail);
});

test("inside a four-backtick fence a closer still being typed is held with its newline", () => {
  expect(safeTail("````md\n```js\n``")).toBe("````md\n```js");
});
