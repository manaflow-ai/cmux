// A message and its images are one prompt, queued behind a running turn or not. The send builds one
// block list holding the words and every image (direct/queue.ts `sentPromptShape`), so nothing in
// the queue splits the image from its text (Leo, 2026-11-25: "wait that message got split up and
// queued"; his screenshots did not reach the agent).
import { expect, test } from "bun:test";
import type { ComposerAttachment } from "./attachments";
import { sentPromptShape } from "./direct/queue";
import { editHeld, heldQueueRows, whereHeldGoes, type TrustHeldPrompt } from "./trustHeld";

const image = (id: string): ComposerAttachment => ({
  id,
  kind: "image",
  name: `${id}.png`,
  mimeType: "image/png",
  size: 3,
  data: "AQID",
  inline: true,
});

test("a message with an image is one prompt that holds its words and its image block", () => {
  const shape = sentPromptShape("why is this font odd", [image("shot")], {});
  expect(shape.blocks.map((block) => block.type)).toContain("image");
  expect(shape.blocks.some((block) => block.type === "text" && block.text.includes("why is this font odd"))).toBe(true);
});

test("two images and words go as one prompt, not one prompt per piece", () => {
  const shape = sentPromptShape("both of these", [image("a"), image("b")], {});
  expect(shape.blocks.filter((block) => block.type === "image")).toHaveLength(2);
  expect(
    shape.blocks
      .filter((block) => block.type === "text")
      .map((block) => (block as { text: string }).text)
      .join("\n"),
  ).toContain("both of these");
});

test("an image alone is still a prompt with its image block", () => {
  const shape = sentPromptShape("", [image("only")], {});
  expect(shape.blocks.filter((block) => block.type === "image")).toHaveLength(1);
});

const held = (id: string, text: string, ...attachments: ComposerAttachment[]): TrustHeldPrompt => ({
  id,
  chat: "chat-1",
  cwd: "/repo",
  text,
  attachments,
  ticket: Promise.resolve(undefined),
});

test("a held message with an image is one queue row that shows its image", () => {
  const rows = heldQueueRows([held("p1", "move this back\uFFFCshot", image("shot"))], "chat-1", "/repo");
  expect(rows).toHaveLength(1);
  expect(rows[0]!.images?.map((shown) => shown.id)).toEqual(["shot"]);
});

test("editing a held message's words keeps its image on the same prompt", () => {
  const edited = editHeld([held("p1", "old", image("shot"))], "p1", { op: "update", text: "new" });
  expect(edited).toHaveLength(1);
  expect(edited[0]!.text).toBe("new");
  expect(edited[0]!.attachments.map((chip) => chip.id)).toEqual(["shot"]);
});

test("held prompts given back keep each one's words and images together, in order", () => {
  const first = held("p1", "first", image("a"));
  const second = held("p2", "second", image("b"));
  const where = whereHeldGoes([first, second], "chat-1", true);
  expect(where.composer.map((entry) => [entry.text, entry.attachments.map((chip) => chip.id)])).toEqual([
    ["first", ["a"]],
    ["second", ["b"]],
  ]);
});
