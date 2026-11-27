import { expect, test } from "bun:test";
import {
  INLINE_ATTACHMENT_MARK,
  bindMarks,
  decodeInlineId,
  inlineCopyId,
  inlineCopyParent,
  inlineToken,
  inlineTokenIds,
  inlineTokenSpans,
  orderedByMarks,
  orderedDraftParts,
  placeInline,
  promptBlocks,
  promptText,
  linkAttachment,
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
  expect(placed.text).toBe(`one${inlineToken("x")}two${inlineToken("y")}three`);
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
  expect(sent.text).toBe(`a${inlineToken("b")}mn${inlineToken("a")}z`);
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

const blockShape = (blocks: ReturnType<typeof promptBlocks>) =>
  blocks.map((block) => (block.type === "text" ? block.text : block.type === "resource_link" ? block.uri : block.type));

// Review (Codex): a link chip's id is `link:` and its path, which may hold `/`, spaces, `%` and `~`.
test("a file link placed in the text goes at its place and comes back to it", () => {
  const link = linkAttachment("/tmp/my file~1 100%.pdf", false);
  const draft = `read ${inlineToken(link.id)} now`;
  // The token holds nothing markdown reads as syntax, and gives the whole id back.
  expect(draft.slice(6, -5)).toMatch(/^[A-Za-z0-9.%-]+$/);
  expect(inlineTokenIds(draft)).toEqual([link.id]);
  const sent = placeInline(draft, [link]);
  expect(sent.attachments.map((attachment) => [attachment.id, attachment.inline])).toEqual([[link.id, true]]);
  expect(blockShape(promptBlocks(sent.text, sent.attachments))).toEqual([
    "read ",
    "file:///tmp/my%20file~1%20100%25.pdf",
    " now",
  ]);
  // Back to edit, and sent again: the same draft each time.
  const back = bindMarks(sent.text, sent.attachments);
  expect(back.text).toBe(draft);
  expect(bindMarks(back.text, sent.attachments).text).toBe(draft);
  expect(placeInline(back.text, back.attachments).text).toBe(sent.text);
});

test("drafts written before ids were encoded still read", () => {
  const uuid = "0b6c1f3e-6f0a-4c55-9a43-3f2d1c0e9b7a";
  expect(inlineToken(uuid)).toBe(`${MARK}${uuid}${MARK}`);
  expect(inlineTokenIds(`a${MARK}${uuid}~abcd1234${MARK}b`)).toEqual([`${uuid}~abcd1234`]);
  expect(decodeInlineId("100%zz")).toBe("100%zz");
});

// Review (Codex): the person's own U+FFFC beside a placed attachment is their text, and never moves
// the attachment or takes its place.
test("the person's U+FFFC stays text beside a placed attachment", () => {
  const one = strip(image("one"));
  const draft = `a${MARK}b ${MARK}word${inlineToken("one")} c${inlineToken("gone")}`;
  const sent = placeInline(draft, [one]);
  expect(sent.text).toBe(`a${MARK}b ${MARK}word${inlineToken("one")} c`);
  expect(sent.attachments.map((attachment) => [attachment.id, attachment.inline])).toEqual([["one", true]]);
  expect(blockShape(promptBlocks(sent.text, sent.attachments))).toEqual([`a${MARK}b ${MARK}word`, "image", " c"]);
  expect(promptText(sent.text, sent.attachments)).toBe(`a${MARK}b ${MARK}word c`);
  expect(bindMarks(sent.text, sent.attachments).text).toBe(sent.text);
});

test("a copy's id keeps the whole id it was copied from", () => {
  const path = "link:/tmp/a~b.pdf";
  const copy = inlineCopyId(path);
  expect(copy).toMatch(/^link:\/tmp\/a~b\.pdf~copy-[0-9a-f]{8}$/);
  expect(inlineCopyParent(copy)).toBe(path);
  expect(inlineCopyParent(inlineCopyId(copy))).toBe(copy);
  const uuid = "0b6c1f3e-6f0a-4c55-9a43-3f2d1c0e9b7a";
  expect(inlineCopyParent(`${uuid}~abcd1234`)).toBe(uuid);
  expect(inlineCopyParent(path)).toBeUndefined();
  expect(inlineCopyParent("link:/tmp/x~deadbeef")).toBeUndefined();
});

test("tokens read against the ids leave the person's U+FFFC on either side as text", () => {
  const text = `x ${MARK}before${inlineToken("one")}after${MARK} y ${inlineToken("gone")}`;
  const spans = inlineTokenSpans(text, (id) => id === "one");
  expect(spans.map((span) => [text.slice(span.from, span.to), span.id, span.place])).toEqual([
    [inlineToken("one"), "one", true],
    [inlineToken("gone"), "gone", false],
  ]);
  // Read against no ids, the first token-shaped run is taken: only the ids can tell.
  expect(inlineTokenSpans(text, () => true)[0]!.id).toBe("before");
});

// Review (Astra, e082): the person's U+FFFC and word after an attachment and before a second token
// of its id were read as the second token's: the words were lost and the id went twice.
test("a second token of a placed id never takes the person's U+FFFC before it", () => {
  const one = strip(image("one"));
  const sent = placeInline(`${inlineToken("one")} ${MARK}word${inlineToken("one")}`, [one]);
  expect(sent.text).toBe(`${inlineToken("one")} ${MARK}word`);
  expect(sent.attachments.map((attachment) => attachment.id)).toEqual(["one"]);
  expect(blockShape(promptBlocks(sent.text, sent.attachments))).toEqual(["image", ` ${MARK}word`]);
  // The second token is told from text by its id alone, though it is no second place.
  const spans = inlineTokenSpans(
    `${inlineToken("one")} ${MARK}word${inlineToken("one")}`,
    (id, placed) => id === "one" && !placed.has(id),
  );
  expect(spans.map((span) => [span.id, span.known, span.place])).toEqual([
    ["one", true, true],
    ["one", true, false],
  ]);
});

test("a path id's token keeps the person's U+FFFC before it as text", () => {
  const link = linkAttachment("/tmp/my file~1 100%.pdf", false);
  const draft = `${MARK}see${inlineToken(link.id)} ${MARK}word${inlineToken(link.id)}`;
  const sent = placeInline(draft, [link]);
  expect(sent.text).toBe(`${MARK}see${inlineToken(link.id)} ${MARK}word`);
  expect(blockShape(promptBlocks(sent.text, sent.attachments))).toEqual([
    `${MARK}see`,
    "file:///tmp/my%20file~1%20100%25.pdf",
    ` ${MARK}word`,
  ]);
});

// Review (Astra, e082): read without the attachments, `word` was taken for the token and `one`
// was left as text; read against them, every reader agrees with placement.
test("ids and cleanup read against the attachments agree with placement", () => {
  const draft = `${MARK}word${inlineToken("one")} tail`;
  const known = (id: string) => id === "one";
  expect(inlineTokenIds(draft, known)).toEqual(["one"]);
  expect(withoutInlineTokens(draft, known)).toBe(`${MARK}word tail`);
  expect(placeInline(draft, [strip(image("one"))]).text).toBe(draft);
  // A second token of one id is no second place.
  expect(inlineTokenIds(`${inlineToken("a")}${inlineToken("b")}${inlineToken("a")}`, () => true)).toEqual(["a", "b"]);
  // A stale token beside a placed one goes; the person's lone U+FFFC stays.
  expect(withoutInlineTokens(`${MARK} a${inlineToken("gone")}${inlineToken("one")}`, known)).toBe(`${MARK} a`);
  // Text with no token of a known id is the person's, as written.
  expect(withoutInlineTokens(`a${MARK}b${MARK}c`, known)).toBe(`a${MARK}b${MARK}c`);
});

// Review (Astra, e082): a recording the model cannot hear is taken out before the prompt goes; its
// token was then sent to the agent as text.
test("a token of an attachment taken out of the prompt goes as nothing", () => {
  const dropped = (id: string) => id === "v";
  expect(promptBlocks(`say ${inlineToken("v")}`, [], { dropped })).toEqual([{ type: "text", text: "say " }]);
  expect(promptText(`say ${inlineToken("v")}${MARK}`, [], { dropped })).toBe(`say ${MARK}`);
  // Beside an attachment still placed, a stale token is the composer's and goes with no hint.
  expect(blockShape(promptBlocks(`say ${inlineToken("v")} then${inlineToken("one")}`, [image("one")]))).toEqual([
    "say  then",
    "image",
  ]);
  // The person's U+FFFC and an older composer's bare marks are text and places as before.
  expect(promptBlocks(`a${MARK}b`, [], { dropped })).toEqual([{ type: "text", text: `a${MARK}b` }]);
  expect(blockShape(promptBlocks(`a${MARK}b${MARK}c`, [image("x"), image("y")], { dropped }))).toEqual([
    "a",
    "image",
    "b",
    "image",
    "c",
  ]);
  const sent = placeInline(`say ${inlineToken("v")}${inlineToken("one")}`, [strip(image("one"))], { dropped });
  expect(sent.text).toBe(`say ${inlineToken("one")}`);
});

test("a removed final attachment never borrows the person's preceding object character", () => {
  const dropped = (id: string) => id === "v";
  const draft = `${MARK}word${inlineToken("v")} then ${MARK}literal${MARK}`;
  const expected = `${MARK}word then ${MARK}literal${MARK}`;
  expect(promptBlocks(draft, [], { dropped })).toEqual([{ type: "text", text: expected }]);
  expect(promptText(draft, [], { dropped })).toBe(expected);
  expect(orderedDraftParts(draft, [], { dropped })).toEqual([{ type: "text", text: expected }]);
  expect(placeInline(draft, [], { dropped })).toEqual({ text: expected, attachments: [] });
});

// Review (Astra, e082): the strip ranked an id by its last place, the prompt by its first.
test("the strip orders by each id's first place, as the prompt does", () => {
  const [a, b] = [strip(image("a")), strip(image("b"))];
  expect(orderedByMarks([a, b], ["b", "a", "b"]).map((attachment) => attachment.id)).toEqual(["b", "a"]);
  const draft = `${inlineToken("b")}${inlineToken("a")}${inlineToken("b")}`;
  expect(placeInline(draft, [a, b]).attachments.map((attachment) => attachment.id)).toEqual(["b", "a"]);
  expect(
    orderedByMarks(
      [a, b],
      inlineTokenIds(draft, () => true),
    ).map((attachment) => attachment.id),
  ).toEqual(["b", "a"]);
});
