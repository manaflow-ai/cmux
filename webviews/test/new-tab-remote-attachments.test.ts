import { expect, test } from "bun:test";
import type { ComposerAttachment } from "../src/agent-session/acpmux/attachments";
import { holdNewTabAttachments } from "../src/agent-session/acpmux/newtab/remoteAttachmentDraft";

const image: ComposerAttachment = {
  id: "remote-image",
  kind: "image",
  name: "Screenshot.png",
  mimeType: "image/png",
  size: 4,
  data: "iVBO",
};

test("a remote image-only New Tab prompt is restored into the first composer", () => {
  expect(holdNewTabAttachments(undefined, [image])).toEqual([{ text: "", attachments: [image] }]);
});

test("a remote New Tab with no image leaves held prompts unchanged", () => {
  const held = [{ text: "already waiting", attachments: [] }];
  expect(holdNewTabAttachments(held, [])).toEqual(held);
});
