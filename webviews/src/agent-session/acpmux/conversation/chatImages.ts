import type { AcpmuxRow } from "../model";
import { dataUrlsOverBudget, footnoteOrder, inlineImages, parseMarkdown, type MdBlock } from "./Markdown";

/// An image a reply drew inline (a data URL, as Markdown.tsx draws one), for the image viewer.
export type ChatImage = { src: string; alt: string };

/// Every inline image of the chat's replies, oldest first, each source once: exactly the images
/// Markdown.tsx draws, read with its own block parser and inline pattern, so code is never an image.
export function chatImages(rows: readonly AcpmuxRow[]): ChatImage[] {
  const images: ChatImage[] = [];
  const seen = new Set<string>();
  for (const row of rows) {
    if (row.kind !== "assistant" || !row.text || !/\]\(data:image\//i.test(row.text)) continue;
    // Notes draw under the reply, by their first reference (Markdown.tsx noteRank).
    const blocks = parseMarkdown(row.text);
    const order = footnoteOrder(row.text);
    const rank = (block: MdBlock) =>
      block.type === "footnote" && order.includes(block.id) ? order.indexOf(block.id) : Number.MAX_SAFE_INTEGER;
    const notes = blocks.filter((block) => block.type === "footnote").sort((a, b) => rank(a) - rank(b));
    // Images past the reply's data URL budget draw as their name (Markdown.tsx dataUrlsOverBudget).
    const overBudget = dataUrlsOverBudget(row.text);
    for (const text of blockTexts([...blocks.filter((block) => block.type !== "footnote"), ...notes]))
      for (const image of inlineImages(text, overBudget)) {
        if (seen.has(image.src)) continue;
        seen.add(image.src);
        images.push(image);
      }
  }
  return images;
}

/// The inline text of `blocks` in reading order, as Markdown.tsx draws it (code and math have none).
function* blockTexts(blocks: readonly MdBlock[]): Generator<string> {
  for (const block of blocks)
    switch (block.type) {
      case "heading":
      case "paragraph":
      case "footnote":
        yield block.text;
        break;
      case "blockquote":
        yield* blockTexts(block.children);
        break;
      case "list":
        for (const item of block.items) {
          yield item.text;
          yield* blockTexts(item.children);
        }
        break;
      case "table":
        yield* block.header;
        for (const row of block.rows) yield* row;
        break;
    }
}
