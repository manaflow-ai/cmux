import { expect, test } from "bun:test";
import type { ComposerAttachment } from "../attachments";
import { copiesAsImage, copyAttachmentImage, dragAttachmentImage, isCopyKey } from "./attachmentImageCopy";
import { TEAR_OFF_PX, tornOff } from "./stripReorder";

const pasted: ComposerAttachment = {
  id: "a",
  kind: "image",
  name: "Screenshot.png",
  mimeType: "image/png",
  size: 4,
  data: "iVBO",
};
const linked: ComposerAttachment = {
  id: "b",
  kind: "link",
  name: "shot.jpg",
  mimeType: "image/jpeg",
  size: 0,
  path: "/Users/me/shot.jpg",
};

function recorder() {
  const calls: [string, Record<string, unknown>][] = [];
  return { calls, post: async (method: string, params: Record<string, unknown>) => void calls.push([method, params]) };
}

test("a pasted image copies its own full bytes, never a thumbnail", async () => {
  const { calls, post } = recorder();
  expect(copiesAsImage(pasted)).toBe(true);
  expect(await copyAttachmentImage(pasted, "Screenshot", post, async () => "data:thumb")).toBe(true);
  expect(calls).toEqual([["image.copy", { src: "data:image/png;base64,iVBO", name: "Screenshot" }]]);
});

test("a linked image copies the file read from disk", async () => {
  const { calls, post } = recorder();
  const reads: string[] = [];
  const read = async (path: string) => (reads.push(path), "data:image/jpeg;base64,AAAA");
  expect(copiesAsImage(linked)).toBe(true);
  expect(await dragAttachmentImage(linked, "shot", post, read)).toBe(true);
  expect(reads).toEqual(["/Users/me/shot.jpg"]);
  expect(calls).toEqual([["image.drag", { src: "data:image/jpeg;base64,AAAA", name: "shot" }]]);
});

test("text, saved files and unreadable images post nothing", async () => {
  const { calls, post } = recorder();
  const text: ComposerAttachment = { id: "t", kind: "text", name: "a.txt", mimeType: "text/plain", size: 1, text: "x" };
  const saved: ComposerAttachment = { ...linked, saved: true };
  expect(copiesAsImage(text)).toBe(false);
  expect(copiesAsImage(saved)).toBe(false);
  expect(copiesAsImage({ ...pasted, data: undefined })).toBe(false);
  expect(await copyAttachmentImage(text, "a", post)).toBe(false);
  expect(await copyAttachmentImage(linked, "shot", post, async () => undefined)).toBe(false);
  expect(calls).toEqual([]);
});

test("only a bare Cmd-C is Copy", () => {
  const key = { key: "c", metaKey: true, ctrlKey: false, altKey: false, shiftKey: false };
  expect(isCopyKey(key)).toBe(true);
  expect(isCopyKey({ ...key, key: "C" })).toBe(true);
  expect(isCopyKey({ ...key, shiftKey: true })).toBe(false);
  expect(isCopyKey({ ...key, altKey: true })).toBe(false);
  expect(isCopyKey({ ...key, metaKey: false, ctrlKey: true })).toBe(false);
  expect(isCopyKey({ ...key, key: "v" })).toBe(false);
});

test("a chip tears off the strip only past its margin or out of the page", () => {
  const strip = { top: 100, bottom: 160 };
  expect(tornOff(50, 130, strip, 800, 600)).toBe(false);
  expect(tornOff(50, strip.top - TEAR_OFF_PX + 1, strip, 800, 600)).toBe(false);
  expect(tornOff(50, strip.top - TEAR_OFF_PX - 1, strip, 800, 600)).toBe(true);
  expect(tornOff(50, strip.bottom + TEAR_OFF_PX + 1, strip, 800, 600)).toBe(true);
  expect(tornOff(-1, 130, strip, 800, 600)).toBe(true);
  expect(tornOff(801, 130, strip, 800, 600)).toBe(true);
});
