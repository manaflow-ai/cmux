// The composer writes its prompt's markdown block by block, each block's markdown kept by node, so a
// key into a long draft writes one paragraph instead of the whole prompt (Leo, 2026-11-04: interaction
// cost stays constant as sessions grow). The joined blocks must be exactly what Milkdown's serializer
// writes for the whole document, for every kind of draft, or a draft would change as it is typed.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import type { Editor } from "@milkdown/kit/core";
import type { Node as ProseNode } from "@milkdown/kit/prose/model";
import { proseMirrorGlobals } from "../src/agent-session/acpmux/promptFieldTesting";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "Node", "Element", "getSelection", "MutationObserver"];
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let editor: Editor;
let parse: (markdown: string) => ProseNode;
let serialize: (doc: ProseNode) => string;

beforeAll(async () => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const { window } = dom;
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Element: window.Element,
    ...proseMirrorGlobals(window as unknown as Window & typeof globalThis),
  });
  const core = await import("@milkdown/kit/core");
  const { commonmark } = await import("@milkdown/kit/preset/commonmark");
  const { gfm } = await import("@milkdown/kit/preset/gfm");
  // The serializer the field configures (MarkdownField.tsx: bullet "-", emphasis "*").
  editor = await core.Editor.make()
    .config((ctx) => {
      ctx.set(core.rootCtx, window.document.getElementById("root")!);
      ctx.update(core.remarkStringifyOptionsCtx, (options) => ({
        ...options,
        bullet: "-" as const,
        emphasis: "*" as const,
      }));
    })
    .use(commonmark)
    .use(gfm)
    .create();
  parse = editor.action((ctx) => ctx.get(core.parserCtx)) as (markdown: string) => ProseNode;
  serialize = editor.action((ctx) => ctx.get(core.serializerCtx));
});

afterAll(async () => {
  await editor?.destroy();
  await teardownDom(saved, { window: dom.window, scope });
});

const DRAFTS = [
  "one paragraph",
  "first\n\nsecond\n\nthird",
  "a *b* **c** `d` [e](https://f.test) ~~g~~ <span>h</span>\n\nnext",
  "1\\. not a list\n\n\\# not a heading\n\n\\- not a bullet\n\n\\> not a quote",
  "line one  \nline two\\\nline three\n\nafter the breaks",
  "# Heading\n\ntext\n\n## Second\n\n```ts\nconst a = 1;\n\n\nconst b = 2;\n```\n\ntail",
  "para\n\n<br />\n\nafter an empty paragraph",
  "snake_case and 2*3*4 and a_b_c and <tag> & &amp; entities",
  "===\n\n---text\n\n***\n\nwords",
  "- a list\n- of items\n\n- another list\n\nafter",
  "1. one\n2. two\n\ntext",
  "> a quote\n\ntext",
  "| a | b |\n| - | - |\n| 1 | 2 |\n\ntext",
  "text with a ￼ mark and ⁠￼ joiner\n\nsecond ￼id￼",
  "trailing spaces   \n\nend   ",
];

test("the blocks joined are the whole document's markdown, for every kind of draft", async () => {
  const { blockwiseMarkdown } = await import("../src/agent-session/acpmux/MarkdownField");
  const { withTextMarksEscaped } = await import("../src/agent-session/acpmux/composer/inlineNode");
  for (const draft of DRAFTS) {
    const doc = parse(draft);
    expect(blockwiseMarkdown(doc, serialize, false)).toBe(serialize(doc));
    expect(blockwiseMarkdown(doc, serialize, true)).toBe(serialize(withTextMarksEscaped(doc)));
  }
});

test("empty paragraphs (blank lines typed or pasted) join as the whole document writes them", async () => {
  const { blockwiseMarkdown } = await import("../src/agent-session/acpmux/MarkdownField");
  const blocks = parse("first\n\nsecond\n\n# third\n\n```\ncode\n```").content;
  const empty = () => blocks.child(0).type.create();
  const shapes = [
    [empty(), blocks.child(0), blocks.child(1)],
    [blocks.child(0), empty(), blocks.child(1)],
    [blocks.child(0), empty(), empty(), empty(), blocks.child(1)],
    [blocks.child(0), blocks.child(1), empty()],
    [empty(), blocks.child(2), empty(), blocks.child(3), empty()],
    [empty(), empty()],
    [blocks.child(0), blocks.child(2).type.create(blocks.child(2).attrs), blocks.child(1)],
    [blocks.child(0), blocks.child(3).type.create(blocks.child(3).attrs), blocks.child(1)],
  ];
  for (const shape of shapes) {
    const doc = parse("x").type.create(null, shape);
    expect(blockwiseMarkdown(doc, serialize, false)).toBe(serialize(doc));
  }
});

test("a key at the end of a 2,000-paragraph draft writes only its paragraph", async () => {
  const { blockwiseMarkdown } = await import("../src/agent-session/acpmux/MarkdownField");
  const doc = parse(Array.from({ length: 2000 }, (_, at) => `paragraph ${at} with *some* words`).join("\n\n"));
  let writes = 0;
  const counted = (node: ProseNode) => {
    writes += 1;
    return serialize(node);
  };
  blockwiseMarkdown(doc, counted, false);
  writes = 0;
  // The key: one character typed into the last paragraph, the other 1,999 blocks shared.
  const typed = doc.replace(doc.content.size - 1, doc.content.size - 1, doc.slice(1, 2));
  expect(typed.childCount).toBe(2000);
  expect(blockwiseMarkdown(typed, counted, false)).toBe(serialize(typed));
  // One write for the changed paragraph (the check above writes the whole once more, uncounted).
  expect(writes).toBe(1);
});

test("a paragraph of hard-break lines joins as the whole paragraph writes, for every kind of line", async () => {
  const { blockwiseMarkdown } = await import("../src/agent-session/acpmux/MarkdownField");
  const { withTextMarksEscaped } = await import("../src/agent-session/acpmux/composer/inlineNode");
  const sample = parse("a\\\nb *c* **d** `e`").child(0);
  const hardbreak = sample.child(1);
  const schema = sample.type.schema;
  const marked = (text: string, at: number) =>
    sample.child(at).marks.length ? schema.text(text, sample.child(at).marks) : schema.text(text);
  const LINES = [
    "plain words",
    "# not a heading",
    "- not a bullet",
    "+ plus",
    "1. not a list",
    "> not a quote",
    "  leading spaces",
    "trailing spaces  ",
    " ",
    "*",
    "_under_",
    "a*b*c",
    "`tick",
    "tick`",
    "<span>",
    "&amp; &",
    "===",
    "---",
    "***",
    "\\back",
    "1)",
    "~~",
    "[link](x)",
    "| a | b |",
    "\t tab",
    "￼",
    "x￼id￼y",
  ];
  let seed = 7;
  const random = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
  for (let draft = 0; draft < 300; draft++) {
    const nodes: ProseNode[] = [];
    const length = 1 + Math.floor(random() * 8);
    if (random() < 0.3) nodes.push(hardbreak);
    for (let line = 0; line < length; line++) {
      if (line) nodes.push(hardbreak);
      if (random() < 0.15) continue; // an empty line: two breaks in a row
      nodes.push(schema.text(LINES[Math.floor(random() * LINES.length)]!));
      if (random() < 0.3) nodes.push(marked(" marked", 3 + 2 * Math.floor(random() * 2)));
    }
    if (random() < 0.2) nodes.push(hardbreak);
    const paragraph = sample.type.create(null, nodes);
    for (const doc of [
      sample.type.schema.topNodeType.create(null, [paragraph]),
      parse("first\n\n# head").type.create(null, [parse("first").child(0), paragraph, parse("last").child(0)]),
    ]) {
      expect([draft, blockwiseMarkdown(doc, serialize, false)]).toEqual([draft, serialize(doc)]);
      expect([draft, blockwiseMarkdown(doc, serialize, true)]).toEqual([draft, serialize(withTextMarksEscaped(doc))]);
    }
  }
  // A mark across a break is written around both lines: such a paragraph is written whole.
  const across = parse("*one\\\ntwo*");
  expect(blockwiseMarkdown(across, serialize, false)).toBe(serialize(across));
});

test("a key at the end of a 2,000-line pasted paragraph writes only its line", async () => {
  const { blockwiseMarkdown } = await import("../src/agent-session/acpmux/MarkdownField");
  const sample = parse("a\\\nb").child(0);
  const nodes: ProseNode[] = [];
  for (let line = 0; line < 2000; line++)
    nodes.push(sample.child(1), sample.type.schema.text(`line ${line} with words`));
  const doc = sample.type.schema.topNodeType.create(null, [sample.type.create(null, nodes)]);
  let writes = 0;
  const counted = (node: ProseNode) => {
    writes += 1;
    return serialize(node);
  };
  expect(blockwiseMarkdown(doc, counted, false)).toBe(serialize(doc));
  writes = 0;
  const typed = doc.replace(doc.content.size - 1, doc.content.size - 1, parse("x").slice(1, 2));
  expect(blockwiseMarkdown(typed, counted, false)).toBe(serialize(typed));
  expect(writes).toBe(1);
});
