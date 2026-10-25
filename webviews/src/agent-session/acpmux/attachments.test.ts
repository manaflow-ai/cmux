import { expect, test } from "bun:test";
import {
  INLINE_ATTACHMENT_MARK,
  bindMarks,
  inlineToken,
  inlineTokenIds,
  orderedByMarks,
  orderedDraftParts,
  placeInline,
  promptBlocks,
  promptText,
  withoutInlineTokens,
  type ComposerAttachment,
} from "./attachments";

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
  const parts = orderedDraftParts(`before${INLINE_ATTACHMENT_MARK}between${INLINE_ATTACHMENT_MARK}after`, [
    first,
    second,
  ]);
  expect(parts.map((part) => (part.type === "text" ? part.text : part.attachment.id))).toEqual([
    "before",
    "first",
    "between",
    "second",
    "after",
  ]);
});

test("ACP blocks preserve image, text, image, text order", () => {
  const blocks = promptBlocks(`caption${INLINE_ATTACHMENT_MARK}middle${INLINE_ATTACHMENT_MARK}tail`, [
    image("one"),
    image("two"),
  ]);
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
  expect(promptBlocks(typed, [image("one")]).map((block) => (block.type === "text" ? block.text : block.type))).toEqual(
    [typed, "image"],
  );
});

test("strip attachments go after the text, inline ones at their marks", () => {
  const parts = orderedDraftParts(`a${INLINE_ATTACHMENT_MARK}b`, [
    { ...image("strip"), inline: false },
    image("placed"),
  ]);
  expect(parts.map((part) => (part.type === "text" ? part.text : part.attachment.id))).toEqual([
    "a",
    "placed",
    "b",
    "strip",
  ]);
});

const MARK = INLINE_ATTACHMENT_MARK;
const strip = (attachment: ComposerAttachment): ComposerAttachment => {
  const { inline: _, ...rest } = attachment;
  return rest;
};

// A prompt that comes back to the composer (Edit, a failed send, a queued prompt taken back to edit)
// has the sent shape: bare marks, its placed attachments `inline` in the text's order. The composer
// ties each mark to its attachment by id again (composer/inlineNode.ts), so a strip reorder or a
// removal afterwards never moves a mark onto another attachment.
test("bare marks come back as each placed attachment's own token, in order", () => {
  const back = bindMarks(`look${MARK}then${MARK}ok`, [image("a"), strip(image("s")), image("b")]);
  expect(back.text).toBe(`look${inlineToken("a")}then${inlineToken("b")}ok`);
  expect(inlineTokenIds(back.text)).toEqual(["a", "b"]);
  // The composer's own copies carry no `inline`: placeInline sets it again when the prompt goes.
  expect(back.attachments.map((attachment) => [attachment.id, attachment.inline])).toEqual([
    ["a", undefined],
    ["s", undefined],
    ["b", undefined],
  ]);
});

test("a prompt bound again and sent goes in the order it came back in", () => {
  const back = bindMarks(`one${MARK}two${MARK}three`, [image("x"), image("y")]);
  const placed = placeInline(back.text, back.attachments);
  expect(placed.text).toBe(`one${MARK}two${MARK}three`);
  expect(placed.attachments.map((attachment) => [attachment.id, attachment.inline])).toEqual([
    ["x", true],
    ["y", true],
  ]);
});

test("marks that do not match the placed attachments stay the person's text", () => {
  const text = `a${MARK}b${MARK}c`;
  expect(bindMarks(text, [image("only")]).text).toBe(text);
  expect(bindMarks(text, []).text).toBe(text);
  // No attachment says it was placed (an older host's record): none are bound.
  expect(bindMarks(`a${MARK}b`, [strip(image("plain"))]).text).toBe(`a${MARK}b`);
});

test("a draft already holding tokens keeps them", () => {
  const text = `a${inlineToken("k")}b`;
  expect(bindMarks(text, [strip(image("k"))]).text).toBe(text);
});

test("a sent draft places its attachments in the text's order, by id, the strip's after", () => {
  const sent = placeInline(`a${inlineToken("b")}m${inlineToken("gone")}n${inlineToken("a")}${inlineToken("b")}z`, [
    strip(image("a")),
    strip(image("s")),
    strip(image("b")),
  ]);
  // A token whose attachment is gone goes as nothing; a second token of one id goes as nothing.
  expect(sent.text).toBe(`a${MARK}mn${MARK}z`);
  expect(sent.attachments.map((attachment) => [attachment.id, attachment.inline])).toEqual([
    ["b", true],
    ["a", true],
    ["s", undefined],
  ]);
  expect(
    promptBlocks(sent.text, sent.attachments).map((block) => (block.type === "text" ? block.text : block.type)),
  ).toEqual(["a", "image", "mn", "image", "z", "image"]);
});

test("the strip shows placed attachments in the text's order, in the slots they held", () => {
  const [a, s, b] = [strip(image("a")), strip(image("s")), strip(image("b"))];
  const list = [a, s, b];
  expect(orderedByMarks(list, ["b", "a"]).map((attachment) => attachment.id)).toEqual(["b", "s", "a"]);
  // Already in order, or one placed: the same array.
  expect(orderedByMarks(list, ["a", "b"])).toBe(list);
  expect(orderedByMarks(list, ["b"])).toBe(list);
});

test("a host that keeps only the text drops the attachments' places, not the person's marks", () => {
  expect(withoutInlineTokens(`a${inlineToken("x")}b${MARK}c`)).toBe(`ab${MARK}c`);
  expect(withoutInlineTokens("plain")).toBe("plain");
});

test("placed recordings and pasted text keep their blocks' shapes at their marks", () => {
  const audio: ComposerAttachment = {
    id: "v",
    kind: "audio",
    name: "Voice",
    mimeType: "audio/wav",
    size: 4,
    data: "UklG",
    inline: true,
  };
  const pasted: ComposerAttachment = {
    id: "p",
    kind: "pasted",
    name: "Pasted",
    mimeType: "text/plain",
    size: 5,
    text: "lines",
    inline: true,
  };
  expect(promptBlocks(`say${MARK}then${MARK}`, [audio, pasted])).toEqual([
    { type: "text", text: "say" },
    { type: "audio", mimeType: "audio/wav", data: "UklG" },
    { type: "text", text: "then" },
    { type: "text", text: "lines", _meta: { cmux: { pasted: true } } },
  ]);
});
