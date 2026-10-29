import { expect, test } from "bun:test";
import {
  attachmentBlocks,
  attachmentSource,
  sourceOfFile,
  withSource,
  type ComposerAttachment,
} from "../attachments";
import { normalizePromptContentPart } from "../inlinePrompt";
import { attachSources } from "./attachmentSources";

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
  const answer = await attachSources("paste", files, async (method, params) => {
    asked.push([method, params]);
    return { sources: [chrome, null] };
  });
  expect(asked).toEqual([["chat.attach.source", { kind: "paste", names: ["a.png", "notes.txt"] }]]);
  expect(answer).toEqual([chrome, undefined]);
  // An older host refuses the method; a malformed answer is none.
  expect(await attachSources("drop", files, () => Promise.reject(new Error("unsupported")))).toEqual([
    undefined,
    undefined,
  ]);
  expect(await attachSources("drop", files, async () => ({ sources: [chrome] }))).toEqual([undefined, undefined]);
  expect(await attachSources("drop", [], async () => ({ sources: [] }))).toEqual([]);
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
  expect(attachmentBlocks(image)).toEqual([
    { type: "image", mimeType: "image/png", data: "AQ==", name: "a.png", _meta: { cmux: { source: chrome } } },
  ]);
  const plain: ComposerAttachment = { id: "2", kind: "image", name: "b.png", mimeType: "image/png", size: 1, data: "AQ==" };
  expect(attachmentBlocks(plain)[0]).not.toHaveProperty("_meta");
  expect(normalizePromptContentPart({ kind: "image", id: "x", mimeType: "image/png", source: chrome })).toMatchObject({
    source: chrome,
  });
  expect(normalizePromptContentPart({ kind: "file", name: "a", source: { name: "" } })).not.toHaveProperty("source");
});
