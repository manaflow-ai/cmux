// l10n-allow-file: Markdown parser regression fixtures.
// A GFM table may interrupt a paragraph (Leo 2026-11-08: "whoa table broke rendering here?"): a
// table written on the line right under a bold line drew as raw pipe lines.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { Markdown } from "./Markdown";
import { IncrementalMarkdown } from "./incrementalMarkdown";
import { type MdBlock, parseMarkdown } from "./markdownModel";
import { markdownBlocks } from "../model";
import { TABLE_AFTER_BOLD, TABLE_AFTER_BOLD_TABLE } from "./tableAfterParagraph.fixture";

const kinds = (blocks: MdBlock[]) => blocks.map((block) => block.type);
const table = (blocks: MdBlock[]) => blocks.find((block) => block.type === "table");
const html = (source: string) => renderToStaticMarkup(<Markdown plainCode>{source}</Markdown>).replaceAll("<wbr/>", "");
const count = (text: string, pattern: RegExp) => text.match(pattern)?.length ?? 0;
const pipeParagraph = (blocks: MdBlock[]) =>
  blocks.some((block) => block.type === "paragraph" && /\|\s*(?:Gap|---)/.test(block.text));

test("a table on the line right under a bold line is a table (Leo's reply)", () => {
  const blocks = parseMarkdown(TABLE_AFTER_BOLD);
  expect(kinds(blocks)).toEqual(["paragraph", "table", "list", "paragraph"]);
  // The bold line stays its own paragraph.
  expect(blocks[0]).toEqual({ type: "paragraph", text: "**What doesn't**" });
  const found = table(blocks);
  expect(found?.type === "table" && found.header).toEqual(["Gap", "Now", "Target", "Owner lane"]);
  expect(found?.type === "table" && found.rows.length).toBe(8);
  expect(found?.type === "table" && found.rows.every((row) => row.length === 4)).toBe(true);
  expect(pipeParagraph(blocks)).toBe(false);
});

test("Leo's reply draws a <table> of 4 columns and 8 body rows, with no raw pipe lines", () => {
  const rendered = html(TABLE_AFTER_BOLD);
  expect(count(rendered, /<table\b/g)).toBe(1);
  const thead = rendered.match(/<thead>([\s\S]*?)<\/thead>/)?.[1] ?? "";
  expect(count(thead, /<th\b/g)).toBe(4);
  const tbody = rendered.match(/<tbody>([\s\S]*?)<\/tbody>/)?.[1] ?? "";
  expect(count(tbody, /<tr\b/g)).toBe(8);
  expect(count(tbody, /<td\b/g)).toBe(32);
  expect(rendered).not.toContain("|---");
  expect(rendered).not.toContain("| Gap");
  expect(rendered).toContain("<strong>What doesn&#x27;t</strong>");
});

test("the renderer's blocks match the height estimate's GFM lexer for Leo's reply", () => {
  expect(markdownBlocks(TABLE_AFTER_BOLD).map((token) => token.type)).toEqual(kinds(parseMarkdown(TABLE_AFTER_BOLD)));
});

test("streaming: the table never draws as raw pipes, and is a table once its delimiter row arrives", () => {
  const stream = new IncrementalMarkdown();
  const delimiterEnd = TABLE_AFTER_BOLD.indexOf("|---|---|---|---|\n") + "|---|---|---|---|\n".length;
  for (let end = 1; end <= TABLE_AFTER_BOLD.length; end++) {
    const blocks = stream.update(TABLE_AFTER_BOLD.slice(0, end), { streaming: true }).map((entry) => entry.block);
    if (pipeParagraph(blocks)) throw new Error(`raw pipes at ${end}: ${JSON.stringify(blocks)}`);
    if (end >= delimiterEnd) {
      if (!table(blocks)) throw new Error(`no table at ${end}`);
      // The bold line stays its own paragraph in every frame.
      expect(blocks[0]).toEqual({ type: "paragraph", text: "**What doesn't**" });
    }
  }
  const done = stream.update(TABLE_AFTER_BOLD, { streaming: false }).map((entry) => entry.block);
  expect(kinds(done)).toEqual(kinds(parseMarkdown(TABLE_AFTER_BOLD)));
});

test("a table right after a heading, a list item, and at the end of a message", () => {
  expect(kinds(parseMarkdown(`## What doesn't\n${TABLE_AFTER_BOLD_TABLE}`))).toEqual(["heading", "table"]);
  expect(kinds(parseMarkdown(`- one gap\n${TABLE_AFTER_BOLD_TABLE}`))).toEqual(["list", "table"]);
  const end = parseMarkdown(`Where we are:\n${TABLE_AFTER_BOLD_TABLE}`);
  expect(kinds(end)).toEqual(["paragraph", "table"]);
  expect(end[0]).toEqual({ type: "paragraph", text: "Where we are:" });
  const last = table(end);
  expect(last?.type === "table" && last.rows.length).toBe(8);
});

test("a header whose cell count differs from its delimiter row's is text, as GFM reads it", () => {
  expect(kinds(parseMarkdown("para\n| a | b |\n|---|\n| 1 | 2 |"))).toEqual(["paragraph"]);
  expect(kinds(parseMarkdown("| a | b |\n|---|\n| 1 | 2 |"))).toEqual(["paragraph"]);
});

test("a line with pipes and no delimiter row under it stays paragraph text", () => {
  expect(parseMarkdown("**Plan**\nrun a | b | c\nthen read the log")).toEqual([
    { type: "paragraph", text: "**Plan**\nrun a | b | c\nthen read the log" },
  ]);
  // A lone `---` under a pipe line is no delimiter row for a paragraph to break at.
  expect(kinds(parseMarkdown("text\na | b\n---"))).toEqual(["paragraph"]);
});
