// A long markdown file opens in slices and a file appended to on disk parses again only from the
// block the change reaches (`reparseTail`, MarkdownEditor.loadInSlices). Whatever the slices, the
// blocks must be the ones a whole parse gives: same ranges, same content. Leo, 2026-11-17: "we
// should be stress testing everything that isn't already stress tested".
import { expect, setDefaultTimeout, test } from "bun:test";
import { Schema } from "@milkdown/kit/prose/model";
import remarkGfm from "remark-gfm";
import remarkParse from "remark-parse";
import { unified } from "unified";
import {
  parseSourceMap,
  reparseTail,
  type MdastNode,
  type MdastRoot,
  type RemarkLike,
  type SourceBlock,
} from "../src/pages/markdown/sourceMap";

const schema = new Schema({
  nodes: {
    doc: { content: "block+" },
    paragraph: { group: "block", content: "text*" },
    cmux_raw: { group: "block", content: "text*", attrs: { kind: { default: "source" } } },
    text: {},
  },
});
setDefaultTimeout(30_000);
const remark = unified().use(remarkParse).use(remarkGfm) as unknown as RemarkLike;

/** A block's mdast without positions, as one paragraph: what the block parsed to. */
const strip = (node: MdastNode): unknown => {
  const { position: _position, children, ...rest } = node;
  return children ? { ...rest, children: children.map(strip) } : rest;
};
const buildParagraphs = (root: MdastRoot) =>
  root.children.map((child) => schema.nodes.paragraph.create(null, schema.text(JSON.stringify(strip(child)))));
const raw = (kind: string, value: string) => schema.nodes.cmux_raw.create({ kind }, value ? schema.text(value) : null);

const shape = (blocks: readonly SourceBlock[]) =>
  blocks.map((block) => ({ start: block.start, end: block.end, nodes: block.nodes.map((node) => node.textContent) }));

const FIXTURES: Record<string, string> = {
  setext: "Para one\nstill para\n===\n\nNext para\n---\n\nText\n",
  listContinuation: "- a\n- b\n\n  joined to b\n\n- c\n\nafter\n",
  fence: "Intro\n\n```ts\nconst a = 1;\n\nconst b = 2;\n```\n\nAfter the fence\n\n~~~\nopen tilde\n",
  quoteLazy: "> quote\nlazy line\n\n> second\n\nplain\n",
  table: "| a | b |\n| - | - |\n| 1 | 2 |\n| 3 | 4 |\n\ntext\n",
  html: "<div>\n\n*md*\n\n</div>\n\n<!-- comment\nspanning -->\n\nend\n",
  indentedCode: "para\n\n    code line\n    more code\n\nback\n",
  frontMatter: "---\ntitle: x\n---\n\n# Head\n\nbody\n",
  deepList: `# top\n\n${Array.from({ length: 70 }, (_, i) => `${"  ".repeat(i)}- level ${i}`).join("\n")}\n\nafter\n`,
  crlf: "one\r\n\r\n- a\r\n- b\r\n\r\n```\r\ncode\r\n```\r\n\r\ntwo\r\n",
};

for (const [name, text] of Object.entries(FIXTURES)) {
  test(`slices at every cut parse to the whole parse's blocks: ${name}`, () => {
    const whole = shape(parseSourceMap(text, remark, buildParagraphs, raw).blocks);
    // Every cut for the short fixtures; a few dozen for the long one.
    for (const step of text.length > 500 ? [97, 401] : [1, 5, 17]) {
      for (let first = 1; first < text.length; first += Math.max(step, Math.ceil(text.length / 60))) {
        const blocks: SourceBlock[] = [...parseSourceMap(text.slice(0, first), remark, buildParagraphs, raw).blocks];
        let cut = first;
        while (cut < text.length) {
          const next = Math.min(text.length, cut + step);
          const { kept, tail } = reparseTail(blocks, text.slice(0, next), cut, remark, buildParagraphs, raw);
          blocks.length = kept;
          blocks.push(...tail);
          cut = next;
        }
        expect([name, step, first, shape(blocks)]).toEqual([name, step, first, whole]);
      }
    }
  });
}

test("an append parses again only from the last block before it", () => {
  const head = Array.from({ length: 2_000 }, (_, i) => `Paragraph ${i}.\n`).join("\n");
  const before = parseSourceMap(head, remark, buildParagraphs, raw);
  const appended = `${head}\nAppended paragraph.\n`;
  const { kept, tail } = reparseTail(before.blocks, appended, head.length, remark, buildParagraphs, raw);
  expect(kept).toBe(1_999);
  expect(tail.map((block) => appended.slice(block.start, block.end))).toEqual([
    "Paragraph 1999.",
    "Appended paragraph.",
  ]);
});

test("a 1,000-deep list shows as its source in bounded time", () => {
  const lines = Array.from({ length: 1_000 }, (_, i) => `${"  ".repeat(i)}- level ${i}`);
  const text = `# top\n\n${lines.join("\n")}\n\nbottom\n`;
  const started = performance.now();
  const map = parseSourceMap(text, remark, buildParagraphs, raw);
  expect(performance.now() - started).toBeLessThan(2_000);
  const kinds = map.blocks.map((block) => block.nodes[0]!.type.name);
  expect(kinds).toEqual(["paragraph", "cmux_raw", "paragraph"]);
  // Byte for byte: the raw block is the list's source.
  expect(text.slice(map.blocks[1]!.start, map.blocks[1]!.end)).toBe(lines.join("\n"));
});
