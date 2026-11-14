// An echoed prompt's images take the pane's own bytes by identity, never by position or by name
// alone (inlinePrompt.ts recordedPromptParts, conversation/imageEntries.ts withSentShapes). The
// echo adds a video's frames note, label and frame images, so its images do not line up with the
// pane's row, and two screenshots are often both `image.png`: a wrong pairing drew one screenshot's
// bytes for the other. An image with no sure match keeps no `src`, so the bubble reads it by its
// id, which is always its own bytes.
import { beforeEach, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import type { ComposerAttachment } from "../src/agent-session/acpmux/attachments";
import type { PromptContentPart } from "../src/agent-session/acpmux/model";

const images = await import("../src/agent-session/acpmux/conversation/imageEntries");
const { recordedPromptParts } = await import("../src/agent-session/acpmux/inlinePrompt");

/// A PNG header `width`×`height`, its bytes told apart by `salt`.
function pngData(width: number, height: number, salt: number): string {
  const bytes = new Uint8Array(40);
  bytes.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]);
  const view = new DataView(bytes.buffer);
  view.setUint32(16, width);
  view.setUint32(20, height);
  view.setUint32(36, salt);
  return Buffer.from(bytes).toString("base64");
}
/// acpmux's id for an image: the SHA-256 of its bytes (hub/prompt_images.rs).
const acpmuxId = (data: string) => createHash("sha256").update(Buffer.from(data, "base64")).digest("hex");

type Shot = { attachment: ComposerAttachment; src: string; id: string };
function shot(key: string, width: number, height: number, salt: number, name = "image.png"): Shot {
  const data = pngData(width, height, salt);
  return {
    attachment: { id: `composer-${key}`, kind: "image", name, mimeType: "image/png", size: data.length, data },
    src: `data:image/png;base64,${data}`,
    id: acpmuxId(data),
  };
}
/// The pane's own row part for `image` (inlinePrompt.ts inlinePrompt), and acpmux's echo of it.
const sentPart = (image: Shot, blockIndex: number): PromptContentPart => ({
  kind: "image",
  id: image.attachment.id,
  attachmentId: image.attachment.id,
  mimeType: "image/png",
  name: image.attachment.name,
  src: image.src,
  blockIndex,
  placed: true,
});
const echoPart = (image: Shot) => ({
  kind: "image",
  id: image.id,
  mimeType: "image/png",
  name: image.attachment.name,
  placed: true,
});
const original = (image: Shot, companionOf: number) => ({
  kind: "file" as const,
  name: image.attachment.name!,
  uri: `file:///tmp/${image.attachment.id}.png`,
  companionOf,
  placed: true as const,
});
const video = (name: string) => ({ kind: "file" as const, name, uri: `file:///tmp/${name}`, placed: true as const });
/// What the echo adds for a video: its frames note, the frames' label, and each frame's image.
const videoExpansion = (name: string, frames: number) => [
  { kind: "text", text: `Frames from the video ${name} (0:14, 1920×1080), in order, at: 0:00.0.` },
  { kind: "text", text: `${name} frames` },
  ...Array.from({ length: frames }, (_, at) => ({
    kind: "image",
    id: acpmuxId(pngData(1920, 1080, 1000 + at)),
    mimeType: "image/jpeg",
    name: `${name} frame at 0:0${at}.0`,
  })),
];
const srcs = (parts: PromptContentPart[] | undefined) =>
  (parts ?? []).flatMap((part) => (part.kind === "image" ? [{ id: part.id, src: part.src }] : []));

beforeEach(() => images.clearImageEntries());

// The finding: `text, video(one frame), image A, original A, text, image B, original B`.
function findingCase() {
  const a = shot("a", 1200, 800, 1);
  const b = shot("b", 600, 1400, 2);
  const known: PromptContentPart[] = [
    { kind: "text", text: "look" },
    video("Tab bar jump.mov"),
    sentPart(a, 2),
    original(a, 2),
    { kind: "text", text: "and" },
    sentPart(b, 5),
    original(b, 5),
  ];
  const msg = {
    inlineParts: [
      { kind: "text", text: "look" },
      video("Tab bar jump.mov"),
      ...videoExpansion("Tab bar jump.mov", 1),
      echoPart(a),
      original(a, 5),
      { kind: "text", text: "and" },
      echoPart(b),
      original(b, 8),
    ],
  };
  return { a, b, known, msg };
}

test("a video's echo before two image.png screenshots never gives one the other's bytes", () => {
  const { a, b, known, msg } = findingCase();
  const shown = srcs(recordedPromptParts(msg, known));
  const echoedA = shown.find((part) => part.id === a.id)!;
  const echoedB = shown.find((part) => part.id === b.id)!;
  // Before the pane's priming knows their ids, two alike screenshots are not paired at all: each
  // is read by its id.
  expect(echoedA.src === undefined || echoedA.src === a.src).toBe(true);
  expect(echoedB.src === undefined || echoedB.src === b.src).toBe(true);
  expect(shown.every((part) => part.src !== b.src || part.id === b.id)).toBe(true);
  // The video's frame keeps no screenshot's bytes.
  expect(shown.filter((part) => part.id !== a.id && part.id !== b.id).every((part) => !part.src)).toBe(true);
});

test("once the pane has hashed its screenshots, each echo shows its own bytes", async () => {
  const { a, b, known, msg } = findingCase();
  await images.primeSentImages([a.attachment, b.attachment]);
  const shown = srcs(recordedPromptParts(msg, known));
  expect(shown.find((part) => part.id === a.id)?.src).toBe(a.src);
  expect(shown.find((part) => part.id === b.id)?.src).toBe(b.src);
  // The echo's own `images` list, as direct.ts pairs it with the pane's row.
  const rowImages = [a, b].map((image) => ({
    id: image.attachment.id,
    mimeType: "image/png",
    name: "image.png",
    src: image.src,
  }));
  const echoImages: { id: string; mimeType: string; name: string; src?: string }[] = [
    { id: acpmuxId(pngData(1920, 1080, 1000)), mimeType: "image/jpeg", name: "Tab bar jump.mov frame at 0:00.0" },
    { id: a.id, mimeType: "image/png", name: "image.png" },
    { id: b.id, mimeType: "image/png", name: "image.png" },
  ];
  expect(images.withSentShapes(echoImages, rowImages).map((image) => image.src)).toEqual([undefined, a.src, b.src]);
});

test("several videos with several frames each, then screenshots: each gets its own bytes or none", async () => {
  const a = shot("a", 1200, 800, 1);
  const b = shot("b", 600, 1400, 2);
  const c = shot("c", 900, 900, 3, "Screenshot 2026-11-07 at 10.12.04.png");
  const known: PromptContentPart[] = [
    { kind: "text", text: "three clips" },
    video("one.mov"),
    video("two.mp4"),
    { kind: "text", text: "then" },
    sentPart(a, 4),
    sentPart(b, 5),
    sentPart(c, 6),
  ];
  const msg = {
    inlineParts: [
      { kind: "text", text: "three clips" },
      video("one.mov"),
      ...videoExpansion("one.mov", 3),
      video("two.mp4"),
      ...videoExpansion("two.mp4", 4),
      { kind: "text", text: "then" },
      echoPart(a),
      echoPart(b),
      echoPart(c),
    ],
  };
  // Unprimed: the uniquely named screenshot still lands with its bytes; the two image.png ones
  // never take each other's.
  let shown = srcs(recordedPromptParts(msg, known));
  expect(shown.find((part) => part.id === c.id)?.src).toBe(c.src);
  expect(shown.find((part) => part.id === a.id)?.src ?? a.src).toBe(a.src);
  expect(shown.find((part) => part.id === b.id)?.src ?? b.src).toBe(b.src);
  expect(shown.filter((part) => ![a.id, b.id, c.id].includes(part.id)).every((part) => !part.src)).toBe(true);
  await images.primeSentImages([a.attachment, b.attachment, c.attachment]);
  shown = srcs(recordedPromptParts(msg, known));
  expect(shown.find((part) => part.id === a.id)?.src).toBe(a.src);
  expect(shown.find((part) => part.id === b.id)?.src).toBe(b.src);
  expect(shown.find((part) => part.id === c.id)?.src).toBe(c.src);
  expect(shown.filter((part) => ![a.id, b.id, c.id].includes(part.id)).every((part) => !part.src)).toBe(true);
});

test("images only: the echo reuses the pane's bytes, so nothing flashes", async () => {
  const a = shot("a", 1200, 800, 1, "Screenshot 2026-11-07 at 10.12.04.png");
  const b = shot("b", 600, 1400, 2, "Screenshot 2026-11-07 at 10.12.31.png");
  const known: PromptContentPart[] = [{ kind: "text", text: "look" }, sentPart(a, 1), sentPart(b, 2)];
  const msg = { inlineParts: [{ kind: "text", text: "look" }, echoPart(a), echoPart(b)] };
  // Before any priming, by their distinct names.
  const parts = recordedPromptParts(msg, known)!;
  expect(srcs(parts).map((part) => part.src)).toEqual([a.src, b.src]);
  // Each keeps its own row part's ids and its size.
  expect(
    parts.flatMap((part) => (part.kind === "image" ? [[part.attachmentId, part.width, part.height]] : [])),
  ).toEqual([
    ["composer-a", 1200, 800],
    ["composer-b", 600, 1400],
  ]);
  const rowImages = [a, b].map((image) => ({
    id: image.attachment.id,
    mimeType: "image/png",
    name: image.attachment.name,
    src: image.src,
  }));
  const echoImages = [a, b].map((image): { id: string; mimeType: string; name?: string; src?: string } => ({
    id: image.id,
    mimeType: "image/png",
    name: image.attachment.name,
  }));
  expect(images.withSentShapes(echoImages, rowImages).map((image) => image.src)).toEqual([a.src, b.src]);
  // Two image.png screenshots, once primed (the pane primes at send, before acpmux echoes).
  const c = shot("c", 1200, 800, 3);
  const d = shot("d", 600, 1400, 4);
  await images.primeSentImages([c.attachment, d.attachment]);
  const same = recordedPromptParts({ inlineParts: [{ kind: "text", text: "look" }, echoPart(c), echoPart(d)] }, [
    { kind: "text", text: "look" },
    sentPart(c, 1),
    sentPart(d, 2),
  ]);
  expect(srcs(same).map((part) => part.src)).toEqual([c.src, d.src]);
});

// Review of 9d917495: two image.png screenshots whose echo came before the pane's hash of them
// were left unpaired, so both mounted as square slots and reshaped once priming or a read landed.
test("two image.png screenshots echoed before the pane hashed them land at their final size, with their own bytes", async () => {
  const { a, b, known, msg } = findingCase();
  const shapes = (parts: PromptContentPart[] | undefined) =>
    (parts ?? []).flatMap((part) =>
      part.kind === "image" && (part.id === a.id || part.id === b.id)
        ? [{ id: part.id, src: part.src, width: part.width, height: part.height }]
        : [],
    );
  const first = shapes(recordedPromptParts(msg, known));
  expect(first).toEqual([
    { id: a.id, src: a.src, width: 1200, height: 800 },
    { id: b.id, src: b.src, width: 600, height: 1400 },
  ]);
  // The echo's own `images` list, as direct.ts pairs it with the pane's row.
  const rowImages = [a, b].map((image) => ({
    id: image.attachment.id,
    mimeType: "image/png",
    name: "image.png",
    src: image.src,
  }));
  const echoImages = (order: Shot[]) =>
    order.map(
      (image): { id: string; mimeType: string; name: string; width?: number; height?: number; src?: string } => ({
        id: image.id,
        mimeType: "image/png",
        name: "image.png",
      }),
    );
  const pick = (list: { src?: string; width?: number; height?: number }[]) =>
    list.map(({ src, width, height }) => ({ src, width, height }));
  expect(pick(images.withSentShapes(echoImages([b, a]), rowImages))).toEqual([
    { src: b.src, width: 600, height: 1400 },
    { src: a.src, width: 1200, height: 800 },
  ]);
  // Priming lands after: nothing changes shape or bytes.
  await images.primeSentImages([a.attachment, b.attachment]);
  expect(shapes(recordedPromptParts(msg, known))).toEqual(first);
});
