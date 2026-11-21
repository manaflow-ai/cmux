import { expect, test } from "bun:test";
import {
  attachmentBlocks,
  attachmentSource,
  inlineToken,
  sourceOfFile,
  withSource,
  type ComposerAttachment,
} from "../attachments";
import { inlinePrompt, normalizePromptContentPart, restoreInline, stripFileDisplay } from "../inlinePrompt";
import { queuedAttachments } from "../conversation/queuedMessages";
import { mergeQueue } from "../direct";
import { attachSources, SOURCES_DEADLINE_MS } from "./attachmentSources";

const chrome = { name: "Google Chrome", bundleId: "com.google.Chrome", site: "github.com" };

test("a source is only one the host could have made", () => {
  expect(attachmentSource(chrome)).toEqual(chrome);
  expect(attachmentSource({ name: " cmux " })).toEqual({ name: "cmux" });
  for (const bad of [
    undefined,
    null,
    "cmux",
    { name: "" },
    { name: "x".repeat(65) },
    { name: "A", bundleId: "no dots" },
    { name: "A", bundleId: 7 },
    { name: "A", site: "GitHub.com" },
    { name: "A", site: "a.com/path" },
  ])
    expect(attachmentSource(bad)).toBeUndefined();
});

test("each file gets the host's answer, and none from a host that does not know", async () => {
  const files = [new File(["a"], "a.png"), new File(["b"], "notes.txt")];
  const asked: unknown[] = [];
  const answer = await attachSources(
    "paste",
    files,
    async (method, params) => {
      asked.push([method, params]);
      return { sources: [chrome, null] };
    },
    1_793_000_000_000,
  );
  expect(asked).toEqual([
    ["chat.attach.source", { kind: "paste", names: ["a.png", "notes.txt"], gestureAt: 1_793_000_000_000 }],
  ]);
  expect(answer).toEqual([chrome, undefined]);
  // An older host refuses the method; a malformed answer is none.
  expect(await attachSources("drop", files, () => Promise.reject(new Error("unsupported")))).toEqual([
    undefined,
    undefined,
  ]);
  expect(await attachSources("drop", files, async () => ({ sources: [chrome] }))).toEqual([undefined, undefined]);
  expect(await attachSources("drop", [], async () => ({ sources: [] }))).toEqual([]);
});

test("a late answer, for a gesture the page already gave up on, is dropped", async () => {
  const files = [new File(["a"], "shot.png")];
  let answer!: (value: unknown) => void;
  const asked = attachSources("paste", files, () => new Promise((resolve) => (answer = resolve)), 1);
  // The host answers after the deadline: the chip already went without a source, and the answer
  // (which a newer gesture's record could have made) is not used.
  setTimeout(() => answer({ sources: [chrome] }), SOURCES_DEADLINE_MS + 50);
  expect(await asked).toEqual([undefined]);
});

test("a file the page made keeps the source it was given", () => {
  const file = withSource(new File(["x"], "Screenshot.png"), { name: "cmux" });
  expect(sourceOfFile(file)).toEqual({ name: "cmux" });
  expect(sourceOfFile(new File(["x"], "other.png"))).toBeUndefined();
});

test("a chip's source goes with its prompt block, and comes back from acpmux's part", () => {
  const image: ComposerAttachment = {
    id: "1",
    kind: "image",
    name: "a.png",
    mimeType: "image/png",
    size: 1,
    data: "AQ==",
    source: chrome,
  };
  const plain: ComposerAttachment = {
    id: "2",
    kind: "image",
    name: "b.png",
    mimeType: "image/png",
    size: 1,
    data: "Ag==",
  };
  const file: ComposerAttachment = {
    id: "3",
    kind: "link",
    name: "notes.txt",
    mimeType: "text/plain",
    size: 4,
    path: "/tmp/notes.txt",
    source: { name: "Finder", bundleId: "com.apple.finder" },
  };
  // The source goes in the prompt's display metadata, never in a block's own _meta (which the
  // relay strips before acpmux).
  const blocks = [image, plain, file].flatMap(attachmentBlocks);
  for (const block of blocks) expect(block).not.toHaveProperty("_meta");
  expect(stripFileDisplay(blocks, [image, plain, file])).toEqual([
    { kind: "image", blockIndex: 0, source: chrome },
    { kind: "file", blockIndex: 2, name: "notes.txt", mimeType: "text/plain", size: 4, source: file.source },
  ]);
  expect(inlinePrompt(`see ${inlineToken(image.id)}`, [image])?.display).toEqual([
    { kind: "image", blockIndex: 1, name: "a.png", mimeType: "image/png", size: 1, placed: true, source: chrome },
  ]);
  expect(normalizePromptContentPart({ kind: "image", id: "x", mimeType: "image/png", source: chrome })).toMatchObject({
    source: chrome,
  });
  expect(normalizePromptContentPart({ kind: "file", name: "a", source: { name: "" } })).not.toHaveProperty("source");
});

test("byte-identical images keep their own sources, and a video carries its source", () => {
  const twin = { kind: "image", name: "image.png", mimeType: "image/png", size: 1, data: "AQ==" } as const;
  const unsourced: ComposerAttachment = { ...twin, id: "1" };
  const sourced: ComposerAttachment = { ...twin, id: "2", source: chrome };
  const video: ComposerAttachment = {
    id: "3",
    kind: "link",
    name: "clip.mov",
    mimeType: "video/quicktime",
    size: 9,
    path: "/tmp/clip.mov",
    source: { name: "Finder", bundleId: "com.apple.finder" },
  };
  const attachments = [unsourced, sourced, video];
  const blocks = attachments.flatMap(attachmentBlocks);
  expect(stripFileDisplay(blocks, attachments)).toEqual([
    { kind: "image", blockIndex: 1, source: chrome },
    { kind: "file", blockIndex: 2, source: video.source },
  ]);
});

test("Edit message on a queued prompt keeps each image's source", async () => {
  const [kept, plain] = await queuedAttachments([
    { id: "a", mimeType: "image/png", src: "data:image/png;base64,AQ==", source: chrome },
    { id: "b", mimeType: "image/png", src: "data:image/png;base64,Ag==" },
  ]);
  expect(kept?.source).toEqual(chrome);
  expect(plain).not.toHaveProperty("source");
});

test("a strip-mode document and audio file carry their sources", () => {
  const pdf: ComposerAttachment = {
    id: "1",
    kind: "document",
    name: "brief.pdf",
    mimeType: "application/pdf",
    size: 5,
    data: "JVBERi0=",
    source: chrome,
  };
  const voice: ComposerAttachment = {
    id: "2",
    kind: "audio",
    name: "memo.m4a",
    mimeType: "audio/mp4",
    size: 1,
    data: "AQ==",
  };
  const blocks = [pdf, voice].flatMap(attachmentBlocks);
  expect(stripFileDisplay(blocks, [pdf, voice])).toEqual([{ kind: "document", blockIndex: 0, source: chrome }]);
});

test("acpmux's queue list keeps each image's source from its queued record, by occurrence", () => {
  const finder = { name: "Finder", bundleId: "com.apple.finder" };
  const had = mergeQueue(
    [],
    [
      {
        promptId: "p",
        prompt: "see",
        images: [
          { id: "x", mimeType: "image/png" },
          { id: "x", mimeType: "image/png" },
        ],
      },
    ],
  );
  const known = had.map((entry) => ({
    ...entry,
    images: [
      { id: "x", mimeType: "image/png" },
      { id: "x", mimeType: "image/png", source: finder },
    ],
  }));
  const listed = mergeQueue(known, [
    {
      promptId: "p",
      prompt: "see",
      images: [
        { id: "x", mimeType: "image/png" },
        { id: "x", mimeType: "image/png" },
      ],
    },
  ]);
  expect(listed[0]?.images?.map((image) => image.source)).toEqual([undefined, finder]);
});

test("Edit and Retry put a sent attachment back with its source", async () => {
  const restored = await restoreInline(
    {
      id: "p",
      version: 1,
      at: 1,
      kind: "user",
      inlineParts: [
        { kind: "image", id: "img", mimeType: "image/png", name: "a.png", source: chrome },
        { kind: "file", name: "notes.txt", uri: "file:///tmp/notes.txt", source: { name: "Finder" } },
        { kind: "pasted", name: "Pasted text", text: "a long paste", source: { name: "Notes" } },
      ],
      text: "a long paste",
    },
    "a long paste",
    async () => ({ mimeType: "image/png", data: "AQ==" }),
  );
  expect(restored.attachments.map((chip) => chip.source)).toEqual([chrome, { name: "Finder" }, { name: "Notes" }]);
});
