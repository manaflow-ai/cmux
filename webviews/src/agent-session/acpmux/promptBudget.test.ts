import { expect, test } from "bun:test";
import { inlineToken, promptBlocks, type ComposerAttachment } from "./attachments";
import { PROMPT_INLINE_BUDGET, awaitsOriginals, fitPromptBudget, inlineBytes } from "./promptBudget";

const MIB = 1024 * 1024;
/// A preview of `bytes` bytes as the composer keeps it: its base64 (4/3 the bytes).
const preview = (bytes: number) => "A".repeat(Math.ceil(bytes / 3) * 4);

const screenshot = (index: number, bytes = 1.5 * MIB, original = true): ComposerAttachment => ({
  id: `shot-${index}`,
  kind: "image",
  name: `Screenshot ${index}.png`,
  mimeType: "image/png",
  size: bytes,
  data: preview(bytes),
  ...(original
    ? { originalPath: `/Users/me/.cmux/uploads/Screenshot ${index}.png`, originalName: `Screenshot ${index}.png` }
    : {}),
});

// Leo, 2026-10-31: "this is completely hardlocked bc of message size". A large screenshot batch
// must stay under the transport budget while retaining every attachment.
test("a large screenshot batch stays under the prompt budget: the largest previews go as their originals' links", () => {
  const shots = Array.from({ length: 20 }, (_, index) => screenshot(index, (1 + index / 20) * MIB));
  const input = "look at these";
  expect(inlineBytes(promptBlocks(input, shots))).toBeGreaterThan(PROMPT_INLINE_BUDGET);
  const fitted = fitPromptBudget(input, shots);
  const blocks = promptBlocks(input, fitted);
  expect(inlineBytes(blocks)).toBeLessThanOrEqual(PROMPT_INLINE_BUDGET);
  // Every screenshot still goes: as its preview, or as the link to its original.
  for (const shot of shots)
    expect(
      blocks.some((block) => block.type === "resource_link" && block.uri.endsWith(encodeURIComponent(shot.name))),
    ).toBe(true);
  // Largest first: the images that kept their previews are the smallest.
  const kept = fitted.filter((chip) => chip.kind === "image").map((chip) => chip.id);
  const gone = fitted.filter((chip) => chip.kind === "link").map((chip) => chip.id);
  expect(gone.length).toBeGreaterThan(0);
  expect(kept.length).toBeGreaterThan(0);
  const size = (id: string) => shots.find((shot) => shot.id === id)!.size;
  expect(Math.max(...kept.map(size))).toBeLessThanOrEqual(Math.min(...gone.map(size)));
  // A link keeps its chip's id (its place in the text) and the original's name.
  const link = fitted.find((chip) => chip.kind === "link")!;
  expect(link.saved).toBe(true);
  expect(link.name).toMatch(/^Screenshot \d+\.png$/);
});

test("a prompt under the budget is sent as it is", () => {
  const shots = [screenshot(1), screenshot(2)];
  expect(fitPromptBudget("hi", shots)).toBe(shots);
});

test("a placed screenshot that goes by reference keeps its place in the text", () => {
  const shots = Array.from({ length: 10 }, (_, index) => ({ ...screenshot(index), inline: true }));
  const input = `before ${shots.map((shot) => inlineToken(shot.id)).join(" mid ")} after`;
  const blocks = promptBlocks(input, fitPromptBudget(input, shots));
  expect(inlineBytes(blocks)).toBeLessThanOrEqual(PROMPT_INLINE_BUDGET);
  expect(blocks[0]).toEqual({ type: "text", text: "before " });
  expect(blocks.at(-1)).toEqual({ type: "text", text: " after" });
  expect(blocks.filter((block) => block.type === "text" && block.text === " mid ")).toHaveLength(9);
});

test("a send over the budget waits for the originals still uploading, not for the others", () => {
  const shots = Array.from({ length: 20 }, (_, index) => screenshot(index, 1.5 * MIB, false));
  const uploading = new Set(shots.map((shot) => shot.id));
  expect(awaitsOriginals("hi", shots, (id) => uploading.has(id))).toBe(true);
  // Nothing uploading: the send goes (acpmux names what it refuses).
  expect(awaitsOriginals("hi", shots, () => false)).toBe(false);
  // Under the budget: never waits.
  expect(awaitsOriginals("hi", shots.slice(0, 2), () => true)).toBe(false);
});

test("text is counted as the UTF-8 JSON it goes as", () => {
  expect(inlineBytes([{ type: "text", text: "é".repeat(1000) }])).toBeGreaterThanOrEqual(2000);
  expect(inlineBytes([{ type: "text", text: '"'.repeat(1000) }])).toBeGreaterThanOrEqual(2000);
});

test("copies of one image go together: a link never shares its original with a preview that stays", () => {
  // An inline image copied in the draft keeps its original (attachments.ts inlineCopyId); the sent
  // bubble draws a link whose path a kept preview names as that preview's original, so it would hide.
  const one = screenshot(1, 1.5 * MIB);
  const copies = Array.from({ length: 15 }, (_, index) => ({ ...one, id: `copy-${index}` }));
  const others = Array.from({ length: 2 }, (_, index) => screenshot(10 + index, 1.4 * MIB));
  const fitted = fitPromptBudget("hi", [...copies, ...others]);
  expect(inlineBytes(promptBlocks("hi", fitted))).toBeLessThanOrEqual(PROMPT_INLINE_BUDGET);
  const linked = new Set(fitted.flatMap((chip) => (chip.kind === "link" ? [chip.path] : [])));
  const kept = fitted.filter((chip) => chip.kind === "image" && linked.has(chip.originalPath));
  expect(kept).toHaveLength(0);
  // The smaller screenshots keep their previews.
  expect(fitted.filter((chip) => chip.kind === "image")).toHaveLength(2);
});
