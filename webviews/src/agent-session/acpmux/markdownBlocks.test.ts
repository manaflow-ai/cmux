import { expect, test } from "bun:test";
import { lexer } from "marked";
import { markdownBlocks, maySetextHeading } from "./model";

// The estimate's lexer skips marked's setext-heading rule only where it cannot match, so its tokens
// are marked's own (bench/markdown-estimate-lex.bench.ts says what the skip saves).
const marked = (source: string) => lexer(source, { gfm: true, breaks: true }).filter((token) => token.type !== "space");

test("maySetextHeading finds an underline before the first blank line only", () => {
  expect(maySetextHeading("Title\n===")).toBe(true);
  expect(maySetextHeading("Title\nmore\n   ---  \nafter")).toBe(true);
  expect(maySetextHeading("Title\n    ---")).toBe(false);
  expect(maySetextHeading("Title\n\n---")).toBe(false);
  expect(maySetextHeading("Title\n \t \n===")).toBe(false);
  expect(maySetextHeading("one long line with no newline at all")).toBe(false);
  expect(maySetextHeading("=== alone")).toBe(false);
  expect(maySetextHeading("a\n-- -")).toBe(false);
});

test("markdownBlocks lexes as marked does", () => {
  const cases = [
    "Title\n===\n\nbody",
    "Title\nmore\n---\n",
    "a paragraph\n- a list\n---",
    "a paragraph\n> quote\n===",
    "text\n```\ncode\n```\n---",
    "| a | b |\n|---|---|\n| 1 | 2 |\n---",
    "Title\n  ===  \n\n# atx\n\nplain **bold** `code`",
    "Title\r\n---\r\nafter",
    "- item\n  sub\n  ---\n- item two",
    "    indented\n---",
    "line\n\n\n---\n",
    "x".repeat(12_000) + "\n---",
  ];
  // Random mixes of the lines that start, interrupt and underline blocks.
  const pieces = [
    "text",
    "more words",
    "",
    " ",
    "---",
    "===",
    " - item",
    "1. one",
    "> q",
    "# h",
    "```",
    "    code",
    "| a |",
    "  --  ",
  ];
  let seed = 7;
  const next = () => (seed = (seed * 1_103_515_245 + 12_345) % 2_147_483_648) / 2_147_483_648;
  for (let round = 0; round < 400; round += 1) {
    const lines: string[] = [];
    const count = 1 + Math.floor(next() * 8);
    for (let index = 0; index < count; index += 1) lines.push(pieces[Math.floor(next() * pieces.length)]!);
    cases.push(lines.join("\n"));
  }
  for (const source of cases) expect(JSON.stringify(markdownBlocks(source))).toBe(JSON.stringify(marked(source)));
});
