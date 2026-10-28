import { expect, test } from "bun:test";
import { restoredDraftAttachments, wakeDraftAttachments } from "./draftRestore";
import type { ComposerAttachment } from "../attachments";

test("absent reconnect seed preserves chips, explicit empty seed clears them", () => {
  const chip: ComposerAttachment = { id: "shot", kind: "image", name: "shot.png", mimeType: "image/png", size: 4 };
  expect(restoredDraftAttachments([chip], undefined)).toEqual([chip]);
  expect(restoredDraftAttachments([chip], [])).toEqual([]);
});

test("a present wake attachment list wins over an older unsent seed", () => {
  const oldChip: ComposerAttachment = { id: "old", kind: "image", name: "old.png", mimeType: "image/png", size: 1 };
  const reordered: ComposerAttachment[] = [
    { id: "new", kind: "image", name: "new.png", mimeType: "image/png", size: 2 },
    oldChip,
  ];
  expect(wakeDraftAttachments(reordered, true, [oldChip])).toEqual(reordered);
  expect(wakeDraftAttachments([], true, [oldChip])).toEqual([]);
  expect(wakeDraftAttachments(undefined, false, [oldChip])).toEqual([oldChip]);
});
