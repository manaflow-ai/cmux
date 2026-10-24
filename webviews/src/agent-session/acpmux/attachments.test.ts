import { expect, test } from "bun:test";
import { INLINE_ATTACHMENT_MARK, orderedDraftParts, promptBlocks, type ComposerAttachment } from "./attachments";

const image = (id: string): ComposerAttachment => ({
  id,
  kind: "image",
  name: `${id}.png`,
  mimeType: "image/png",
  size: 3,
  data: "AQID",
});

test("ordered draft parts keep text and images at their editor marks", () => {
  const first = image("first");
  const second = image("second");
  const parts = orderedDraftParts(`before${INLINE_ATTACHMENT_MARK}between${INLINE_ATTACHMENT_MARK}after`, [first, second]);
  expect(parts.map((part) => (part.type === "text" ? part.text : part.attachment.id))).toEqual([
    "before",
    "first",
    "between",
    "second",
    "after",
  ]);
});

test("ACP blocks preserve image, text, image, text order", () => {
  const blocks = promptBlocks(`caption${INLINE_ATTACHMENT_MARK}middle${INLINE_ATTACHMENT_MARK}tail`, [image("one"), image("two")]);
  expect(blocks.map((block) => block.type)).toEqual(["text", "image", "text", "image", "text"]);
  expect(blocks.map((block) => (block.type === "text" ? block.text : block.type))).toEqual([
    "caption",
    "image",
    "middle",
    "image",
    "tail",
  ]);
});
