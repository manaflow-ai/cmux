// A save of a long markdown file stays proportional to its blocks (bench/markdown-viewer-stress.bench.ts
// found both). Before: `serializeWithSourceMap` looked every block up with an `indexOf` over the
// whole document (quadratic in the blocks), and an edit at both ends of the file made `alignNodes`
// build a blocks x blocks LCS table (40,000 blocks: 1.6 billion cells, 6.4 GB). Leo, 2026-11-17: "we
// should be stress testing everything that isn't already stress tested".
import { expect, test } from "bun:test";
import { Schema, type Node as ProseNode } from "@milkdown/kit/prose/model";
import { alignNodes, serializeWithSourceMap, type SourceBlock, type SourceMap } from "../src/pages/markdown/sourceMap";

const schema = new Schema({
  nodes: { doc: { content: "block+" }, paragraph: { group: "block", content: "text*" }, text: {} },
});
const paragraph = (text: string) => schema.nodes.paragraph.create(null, schema.text(text));

const BLOCKS = 40_000;

/** A baseline of BLOCKS paragraphs, `p<i>`, one per source line pair. */
function baseline(): SourceMap {
  let text = "";
  const blocks: SourceBlock[] = [];
  for (let i = 0; i < BLOCKS; i++) {
    const source = `p${i}`;
    const start = text.length;
    text += `${source}\n\n`;
    blocks.push({ start, end: start + source.length, nodes: [paragraph(source)] });
  }
  return { text, blocks };
}

const serialize = (nodes: readonly ProseNode[]) => nodes.map((node) => node.textContent).join("\n\n");

test("an edit at both ends of 40,000 blocks aligns in one pass and keeps every other block", () => {
  const map = baseline();
  const nodes = map.blocks.map((block) => block.nodes[0]!);
  const current = [paragraph("first edited"), ...nodes.slice(1, -1), paragraph("last edited")];
  const started = performance.now();
  const match = alignNodes(nodes, current);
  const took = performance.now() - started;
  expect(match[0]).toBe(-1);
  expect(match[BLOCKS - 1]).toBe(-1);
  for (let j = 1; j < BLOCKS - 1; j++) if (match[j] !== j) throw new Error(`block ${j} matched ${match[j]}`);
  expect(took).toBeLessThan(2_000);
});

test("a block moved from the end to the start keeps the rest of the file byte for byte", () => {
  const map = baseline();
  const nodes = map.blocks.map((block) => block.nodes[0]!);
  const moved = [nodes[BLOCKS - 1]!, ...nodes.slice(0, -1)];
  // An edit at the first block too, so the common prefix and suffix are empty and the middle is all.
  moved[1] = paragraph("p0 edited");
  const out = serializeWithSourceMap(map, moved, serialize);
  expect(out.text.split("\n\n").slice(2, 6)).toEqual(["p1", "p2", "p3", "p4"]);
  expect(out.text.endsWith(`p${BLOCKS - 2}\n\n`)).toBe(true);
  expect(out.text).toContain("p0 edited");
});

test("an unedited save of 40,000 blocks writes the text back in linear time", () => {
  const map = baseline();
  const nodes = map.blocks.map((block) => block.nodes[0]!);
  const started = performance.now();
  const out = serializeWithSourceMap(map, nodes, serialize);
  const took = performance.now() - started;
  expect(out.text).toBe(map.text);
  expect(took).toBeLessThan(2_000);
});
