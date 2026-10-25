import { expect, test } from "bun:test";
import { INLINE_ATTACHMENT_MARK, orderedDraftParts, promptBlocks, promptText, type ComposerAttachment } from "./attachments";

const image = (id: string): ComposerAttachment => ({
  id,
  kind: "image",
  name: `${id}.png`,
  mimeType: "image/png",
  size: 3,
  data: "AQID",
  inline: true,
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

// Review (Codex): a U+FFFC the person typed or pasted is their text, never an attachment's place.
test("a literal object character with no inline attachment stays in the text", () => {
  const strip = { ...image("strip"), inline: false };
  const typed = `see ${INLINE_ATTACHMENT_MARK} here`;
  expect(promptText(typed, [strip])).toBe(typed);
  expect(promptBlocks(typed, [strip]).map((block) => (block.type === "text" ? block.text : block.type))).toEqual([
    typed,
    "image",
  ]);
});

test("marks that do not match the inline attachments are all kept as text", () => {
  const typed = `a${INLINE_ATTACHMENT_MARK}b${INLINE_ATTACHMENT_MARK}c`;
  expect(promptBlocks(typed, [image("one")]).map((block) => (block.type === "text" ? block.text : block.type))).toEqual([
    typed,
    "image",
  ]);
});

test("strip attachments go after the text, inline ones at their marks", () => {
  const parts = orderedDraftParts(`a${INLINE_ATTACHMENT_MARK}b`, [{ ...image("strip"), inline: false }, image("placed")]);
  expect(parts.map((part) => (part.type === "text" ? part.text : part.attachment.id))).toEqual(["a", "placed", "b", "strip"]);
});
