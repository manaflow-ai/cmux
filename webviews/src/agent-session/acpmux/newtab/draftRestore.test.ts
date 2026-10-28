import { expect, test } from "bun:test";
import { restoredDraftAttachments } from "./draftRestore";
import type { ComposerAttachment } from "../attachments";

test("absent reconnect seed preserves chips, explicit empty seed clears them", () => {
  const chip: ComposerAttachment = { id: "shot", kind: "image", name: "shot.png", mimeType: "image/png", size: 4 };
  expect(restoredDraftAttachments([chip], undefined)).toEqual([chip]);
  expect(restoredDraftAttachments([chip], [])).toEqual([]);
});
