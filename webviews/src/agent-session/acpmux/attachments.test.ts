import { describe, expect, test } from "bun:test";
import {
  MAX_ATTACHMENTS,
  MAX_IMAGE_BYTES,
  decodeText,
  promptBlocks,
  promptText,
  readAttachment,
  readAttachments,
  type ComposerAttachment,
} from "./attachments";

const png = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const textFile = (name: string, text: string): ComposerAttachment => ({
  id: name,
  kind: "text",
  name,
  mimeType: "text/plain",
  size: text.length,
  text,
});

describe("composer attachments", () => {
  test("an image becomes base64 bytes, a text file its contents, and a binary file is refused", async () => {
    expect(await readAttachment(new File([png], "shot.png", { type: "image/png" }), true)).toMatchObject({
      kind: "image",
      name: "shot.png",
      mimeType: "image/png",
      data: "iVBORw0KGgo=",
    });
    expect(await readAttachment(new File(["let x = 1\n"], "main.ts"), true)).toMatchObject({
      kind: "text",
      name: "main.ts",
      text: "let x = 1\n",
    });
    expect(await readAttachment(new File([new Uint8Array([0, 1, 2])], "blob.bin"), true)).toEqual({
      name: "blob.bin",
      reason: "unsupported",
    });
    expect(await readAttachment(new File([new Uint8Array([0xff, 0xfe, 0xfd])], "latin1.txt"), true)).toEqual({
      name: "latin1.txt",
      reason: "unsupported",
    });
  });

  test("limits: image support, size and count", async () => {
    expect(await readAttachment(new File([png], "shot.png", { type: "image/png" }), false)).toEqual({
      name: "shot.png",
      reason: "imagesUnsupported",
    });
    expect(
      await readAttachment(new File([new Uint8Array(MAX_IMAGE_BYTES + 1)], "huge.png", { type: "image/png" }), true),
    ).toEqual({ name: "huge.png", reason: "tooLarge" });
    const files = [new File(["a"], "a.txt"), new File(["b"], "b.txt")];
    const read = await readAttachments(files, MAX_ATTACHMENTS - 1, true);
    expect(read.attachments.map((attachment) => attachment.name)).toEqual(["a.txt"]);
    expect(read.errors).toEqual([{ name: "b.txt", reason: "tooMany" }]);
  });

  test("a file whose bytes cannot be read, such as a dropped folder, is refused instead of failing the drop", async () => {
    const folder = new File([], "src");
    folder.arrayBuffer = () => Promise.reject(new Error("NotFoundError"));
    expect(await readAttachments([folder], 0, true)).toEqual({
      attachments: [],
      errors: [{ name: "src", reason: "unsupported" }],
    });
  });

  test("text files follow the prompt as fenced blocks that outlast backticks inside them", () => {
    expect(
      promptText("Look at these", [textFile("a.ts", "const a = 1;"), textFile("notes", "has ```fences```\n")]),
    ).toBe("Look at these\n\na.ts\n```ts\nconst a = 1;\n```\n\nnotes\n````\nhas ```fences```\n````");
    expect(promptText("", [textFile("a.md", "x")])).toBe("a.md\n```md\nx\n```");
  });

  test("prompt blocks put the text first and each image after it", () => {
    const image: ComposerAttachment = {
      id: "i",
      kind: "image",
      name: "shot.png",
      mimeType: "image/png",
      size: 8,
      data: "iVBORw0KGgo=",
    };
    expect(promptBlocks("What is this?", [image, textFile("a.txt", "x")])).toEqual([
      { type: "text", text: "What is this?\n\na.txt\n```txt\nx\n```" },
      { type: "image", mimeType: "image/png", data: "iVBORw0KGgo=" },
    ]);
    expect(promptBlocks("", [image])).toEqual([{ type: "image", mimeType: "image/png", data: "iVBORw0KGgo=" }]);
  });

  test("decodeText refuses NUL bytes", () => expect(decodeText(new TextEncoder().encode("a\u0000b"))).toBeUndefined());
});
