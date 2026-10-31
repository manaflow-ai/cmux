import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { createElement, Fragment } from "react";
import { type MdBlock, parseMarkdown, renderInline } from "../src/agent-session/acpmux/conversation/Markdown";
import { IncrementalMarkdown } from "../src/agent-session/acpmux/conversation/incrementalMarkdown";

// A streaming reply draws every prefix of its text (RevealedMarkdown reveals it a few characters a
// frame; Markdown parses the revealed text with IncrementalMarkdown.update(visible, { streaming }),
// whose tail goes through safeTail). Nothing that has drawn may flip once more text arrives: a
// block keeps its kind, its index and its text grows only at its end. This replays each reply one
// character at a time through the same parser instance the row keeps, plus the stage Markdown's
// `draw` gives a code block (open fence: plain lines; closed: CodeHandoff), and records every flip.

/// What a block draws, as far as layout goes.
type Shape = { kind: string; detail: string; text: string; lines?: number; stage?: string };

/// The text an inline run draws. Where bold, italic or inline code starts is marked (`⟪`, `⟨`, `⟦`),
/// so a run styled while streaming that is plain once the reply ends counts as text that changed.
const textOf = (source: string) =>
  renderToStaticMarkup(createElement(Fragment, null, ...renderInline(source)))
    .replace(/<strong>/g, "⟪")
    .replace(/<em>/g, "⟨")
    .replace(/<code[^>]*>/g, "⟦")
    .replace(/<[^>]*>/g, "")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#x27;/g, "'");

function blockText(block: MdBlock): string {
  switch (block.type) {
    case "heading":
    case "paragraph":
    case "footnote":
      return textOf(block.text);
    case "hr":
      return "";
    case "math":
      return block.tex;
    case "code":
      return block.code;
    case "blockquote":
      return block.children.map(blockText).join("\n");
    case "table":
      return [block.header, ...block.rows].map((row) => row.map(textOf).join("|")).join("\n");
    case "list":
      return block.items
        .map((item, index) => {
          const marker = block.ordered ? `${block.start + index}.` : "";
          return `${marker}${textOf(item.text)}\n${item.children.map(blockText).join("\n")}`;
        })
        .join("\n");
  }
}

/// A nested block's structure, so a list item that grows a sublist late shows up too.
function structure(block: MdBlock): string {
  switch (block.type) {
    case "list":
      return `${block.ordered ? "ol" : "ul"}@${block.start}[${block.items
        .map((item) => item.children.map(structure).join(","))
        .join(";")}]`;
    case "blockquote":
      return `quote[${block.children.map(structure).join(",")}]`;
    case "heading":
      return `h${block.level}`;
    case "table":
      return `table${block.align.length}x${block.header.length}`;
    case "code":
      return `code:${block.lang}`;
    default:
      return block.type;
  }
}

/// The lines an open or handed-over fence draws (StreamingCode.tsx PlainCode).
function codeLines(code: string, open: boolean): number {
  const lines = code.split("\n");
  if (open && lines.length > 1 && lines.at(-1) === "") lines.pop();
  return lines.length;
}

/// The frame Markdown draws for `blocks` (its `draw`: the last block is an open fence while it is
/// parsed open; a fence that closed while streaming hands over).
function frame(blocks: { block: MdBlock }[], streaming: boolean): Shape[] {
  return blocks.map(({ block }, index) => {
    const shape: Shape = { kind: block.type, detail: structure(block), text: blockText(block) };
    if (block.type === "code") {
      const open = streaming && index === blocks.length - 1 && block.open === true;
      shape.stage = open ? "open" : "handoff";
      shape.lines = codeLines(block.code, open);
    }
    return shape;
  });
}

const squash = (value: string) => value.replace(/\s+/g, "");
const tailOf = (value: string) => JSON.stringify(value.slice(-40));

type Flip = { at: number; prefix: string; block: number; change: string };

/// Every flip between consecutive frames of `reply` revealed one character at a time, then the
/// frame where streaming ends.
function flipsOf(reply: string): Flip[] {
  const parser = new IncrementalMarkdown();
  const flips: Flip[] = [];
  let previous: Shape[] = [];
  const frames: [string, boolean][] = [];
  for (let end = 1; end <= reply.length; end += 1) frames.push([reply.slice(0, end), true]);
  frames.push([reply, false]);
  for (const [prefix, streaming] of frames) {
    const shapes = frame(parser.update(prefix, { streaming }), streaming);
    const at = streaming ? prefix.length : -1;
    const note = (block: number, change: string) => flips.push({ at, prefix: tailOf(prefix), block, change });
    previous.forEach((before, index) => {
      const after = shapes[index];
      if (!after) return note(index, `${before.kind} vanished`);
      if (before.detail !== after.detail && !(before.kind === after.kind && grows(before.detail, after.detail)))
        note(index, `${before.detail} -> ${after.detail}`);
      if (!squash(after.text).startsWith(squash(before.text)))
        note(index, `text ${JSON.stringify(before.text.slice(-24))} -> ${JSON.stringify(after.text.slice(-24))}`);
      if (before.stage === "handoff" && after.stage === "open") note(index, "code handoff -> open (remounts)");
      if (before.lines !== undefined && after.lines !== undefined && after.lines < before.lines)
        note(index, `code ${before.lines} lines -> ${after.lines} lines`);
    });
    previous = shapes;
  }
  return flips;
}

/// A list or quote that only appended items or children (`ul@1[;]` -> `ul@1[;;]`).
function grows(before: string, after: string): boolean {
  const open = before.replace(/\]+$/, "");
  return after.startsWith(open);
}

/// One line per flip, a run of the same flip on consecutive frames once, for the failure message.
function summary(flips: Flip[]): string[] {
  const key = (flip: Flip) => `${flip.block}:${flip.change.replace(/".*"/, "")}`;
  const last = new Map<string, number>();
  const out: string[] = [];
  for (const flip of flips) {
    const run = last.get(key(flip));
    last.set(key(flip), flip.at);
    if (run !== undefined && run === flip.at - 1) continue;
    out.push(`@${flip.at < 0 ? "end" : flip.at} block ${flip.block}: ${flip.change}  after ${flip.prefix}`);
  }
  return out;
}

// Realistic replies. Cases marked `base:` flipped on 2bd5130b594, before safeTail held block
// markers and Markdown read an open fence from the parsed tail.
const replies: Record<string, string> = {
  // base: `#`/`##` draw as a paragraph, then become a heading.
  "paragraph and headings":
    "## Summary\n\nThe build failed because the cache was stale.\n\n### Next steps\n\nRun it again with `--clean`.",
  // base: each new `-` draws as a paragraph under the list, then joins it; `**` flashes a `*`.
  "dash bullet list":
    "Changes:\n\n- Added a **retry** to the fetch\n- Fixed the `timeout` path\n- Removed dead code\n\nDone.",
  // base: `*` draws, then `**`... and `* ` turns the paragraph into a list.
  "star bullet list": "* First point\n* Second point with [a link](https://example.com)\n* Third",
  // base: `2`, `2.` draw as a paragraph before `2. ` makes them an item; nested `-` likewise.
  "numbered list, nested items, paragraph between":
    "1. Install deps:\n   - run `bun install`\n   - check the lockfile\n2. Build it\n\n   This takes a minute.\n\n3. Run tests\n\nThat's all.",
  // base: `-` after a paragraph line joins it, then `- ` splits a list off.
  "list right under a paragraph": "Steps:\n- one\n- two\n\nDo:\n1. this\n2. that",
  // The parser has no setext headings: these stay paragraphs.
  "setext-looking lines": "Here is the plan\n---\nand more text\n-\nend",
  // base: `-`, `--` draw as text, then `---` is a rule; `***` draws `*` throughout.
  "horizontal rules": "Part one.\n\n---\n\nPart two.\n\n***\n\nPart three.",
  // base: the closing ``` hands the fence over a line too tall, which then shrinks.
  "fenced code with language": "Run this:\n\n```ts\nconst a = 1;\nconsole.log(a);\n```\n\nThen check the output.",
  // base: the second opener turns the closed first fence back into an open one.
  "two fences in a row": "```sh\nnpm i\n```\n\n```sh\nnpm test\n```\n\nBoth pass.",
  "table with alignment row": "| Name | Size |\n|:-----|-----:|\n| a.ts | 12 |\n| b.ts | 40 |\n\nTotal: 52.",
  // base: the header draws as a paragraph until `---` makes it a table.
  blockquote: "> Note: this is **important**\n> and spans lines\n\nAfter.",
  // base: `*maybe*` draws its stars until it closes; `**` flashes a `*`.
  "inline code, bold, links, italic":
    "Use `git status` to check, see **the docs** at [GitHub](https://github.com/x/y) and *maybe* more.",
  "list item that wraps": "- This item is long and\n  continues on the next line\n- Short",
  "numbers at the start of a line": "2024 was a good year.\n\n42 tests passed and 3 failed.\n\n100% done.",
  // base: `#` under a paragraph line joins it, then splits off as a heading.
  "heading right under a paragraph": "Intro line\n# Title\nbody text",
  // Markers inside words never open emphasis, so nothing is closed for them while streaming.
  "markers inside words":
    "Compute 2*3 and 4*5 here, rename snake_case to file_name, match src/*.ts and /_next paths, keep __init__.py.",
  "underscore emphasis": "This is _really_ it, and (_quoted_) too.",
  "fence nested in a list item": "1. Install:\n\n   ```sh\n   bun install\n   ```\n\n2. Run it",
};

/// Not held yet: a table without edge pipes reads as a prose line until its separator row (holding
/// every line with a `|` would hide prose that has one). base: paragraph -> table at `--`.
const pipelessTable = "Name | Size\n--- | ---\na.ts | 12\n\nTotal: 12.";

describe("a streaming reply never flips a block it has drawn", () => {
  for (const [name, reply] of Object.entries(replies))
    test(name, () => {
      expect(summary(flipsOf(reply))).toEqual([]);
    });
});

test.failing("a table without edge pipes never flips (not held yet)", () => {
  expect(summary(flipsOf(pipelessTable))).toEqual([]);
});

describe("a finished stream draws what the whole text draws", () => {
  for (const [name, reply] of Object.entries({ ...replies, "table without edge pipes": pipelessTable }))
    test(name, () => {
      const parser = new IncrementalMarkdown();
      for (let end = 1; end <= reply.length; end += 1) parser.update(reply.slice(0, end), { streaming: true });
      const settled = parser.update(reply, { streaming: false }).map((entry) => entry.block);
      expect(settled).toEqual(parseMarkdown(reply));
      const drawn = (blocks: MdBlock[]) =>
        frame(
          blocks.map((block) => ({ block })),
          false,
        );
      expect(drawn(settled)).toEqual(drawn(parseMarkdown(reply)));
    });
});
