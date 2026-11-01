// Reply Markdown a longer fence or an escaped pipe has to survive: an agent that quotes Markdown opens
// with four backticks to show its own three, and shell pipes in a table cell arrive as `\|`.
import { expect, test } from "bun:test";
import { parseMarkdown } from "../src/agent-session/acpmux/conversation/Markdown";
import { tableMarkdown, type Table } from "../src/agent-session/acpmux/conversation/tableFormats";

test("a four-backtick fence holds an inner three-backtick fence as its text", () => {
  const blocks = parseMarkdown("````md\n```js\nx\n```\n````");
  expect(blocks).toHaveLength(1);
  expect(blocks[0]).toMatchObject({ type: "code", lang: "md", code: "```js\nx\n```" });
});

test("a fence closes on a line of at least as many backticks, and a shorter one does not close it", () => {
  const long = parseMarkdown("```js\na\n`````\nafter");
  expect(long[0]).toMatchObject({ type: "code", code: "a" });
  expect(long[1]).toMatchObject({ type: "paragraph" });
  const short = parseMarkdown("````\na\n```\nb\n````\nafter");
  expect(short[0]).toMatchObject({ type: "code", code: "a\n```\nb" });
});

test("an unclosed fence still streams as an open code block", () => {
  expect(parseMarkdown("```ts\nconst x")[0]).toMatchObject({ type: "code", lang: "ts", code: "const x", open: true });
  expect(parseMarkdown("````ts\nconst x")[0]).toMatchObject({ type: "code", lang: "ts", open: true });
});

test("an escaped pipe is a literal pipe in its cell, not a column break", () => {
  const [block] = parseMarkdown("| cmd | note |\n| --- | --- |\n| `a \\| b` | x |\n| plain \\| pipe | y \\|\n");
  const table = block as Table & { type: "table" };
  expect(table.header).toEqual(["cmd", "note"]);
  expect(table.rows).toEqual([
    ["`a | b`", "x"],
    ["plain | pipe", "y |"],
  ]);
});

test("copying such a table as Markdown escapes the pipes again, so it round-trips", () => {
  const [block] = parseMarkdown("| cmd | note |\n| --- | --- |\n| `a \\| b` | x |");
  const markdown = tableMarkdown(block as Table & { type: "table" });
  expect(markdown).toContain("| `a \\| b` | x |");
  const [again] = parseMarkdown(markdown);
  expect((again as Table & { type: "table" }).rows).toEqual([["`a | b`", "x"]]);
});

test("a display-math bracket inside a quoted fence stays the code's own text", () => {
  // The inner three-backtick pair must not read as the quoted fence closing: `\[x\]` is code there,
  // not an equation to rewrite into dollars.
  const blocks = parseMarkdown("````md\n```js\n\\[x\\]\n```\n````\n\n\\[y\\]");
  expect(blocks[0]).toMatchObject({ type: "code", code: "```js\n\\[x\\]\n```" });
  expect(blocks[1]).toMatchObject({ type: "math", tex: "y" });
});

test("a line with backticks in its info string does not break the paragraph around it", () => {
  const blocks = parseMarkdown("intro line\n```x``` still prose\nmore prose");
  expect(blocks).toHaveLength(1);
  expect(blocks[0]).toMatchObject({ type: "paragraph" });
});
