import { afterEach, expect, test } from "bun:test";
import { promptBlocks, readAttachment } from "../src/agent-session/acpmux/attachments";
import { intakeFiles } from "../src/agent-session/acpmux/composer/intakeFiles";

const globals = globalThis as Record<string, unknown>;
afterEach(() => {
  delete globals.createImageBitmap;
  delete globals.OffscreenCanvas;
});

function imageEngine(width: number, height: number) {
  const encoded: { width: number; height: number }[] = [];
  globals.createImageBitmap = async () => ({ width, height, close() {} });
  globals.OffscreenCanvas = class {
    constructor(
      public width: number,
      public height: number,
    ) {}
    getContext() {
      return { drawImage() {}, fillRect() {}, fillStyle: "" };
    }
    async convertToBlob({ type }: { type: string }) {
      // The chip's thumbnail (160 px tall) is drawn from the same decode; only the preview counts.
      if (this.height !== 160) encoded.push({ width: this.width, height: this.height });
      return new Blob(["clean pixels"], { type });
    }
  };
  return encoded;
}

for (const [name, type] of [
  ["notes.txt", "text/plain"],
  ["spec.pdf", "application/pdf"],
  ["data.zip", "application/zip"],
])
  test(`${name}: the session gets a path and short metadata, never the file contents`, async () => {
    const file = new File(["private body"], name, { type });
    const taken = await intakeFiles([file], {
      allowImages: true,
      upload: async (files) => ({ paths: files.map((entry) => `/session/uploads/${entry.name}`) }),
    });
    expect(taken.error).toBeUndefined();
    expect(taken.attachments).toHaveLength(1);
    expect(taken.attachments[0]).toMatchObject({
      kind: "link",
      name,
      size: file.size,
    });
    expect(taken.attachments[0]?.mimeType).toMatch(new RegExp(`^${type}(?:;|$)`));
    const blocks = promptBlocks("inspect", taken.attachments);
    expect(blocks).toContainEqual({
      type: "resource_link",
      uri: `file:///session/uploads/${name}`,
      name,
    });
    const text = blocks
      .filter((block) => block.type === "text")
      .map((block) => block.text)
      .join("\n");
    expect(text).toContain(name!);
    expect(text).toContain(type!);
    expect(text).toContain(`${file.size} bytes`);
    expect(text).not.toContain("private body");
    expect(blocks.some((block) => block.type === "document")).toBe(false);
  });

test("a local file above 64 MiB links to its original without reading it", async () => {
  const file = new File([], "archive.zip", { type: "application/zip" });
  Object.defineProperty(file, "size", { value: 80 * 1024 * 1024 });
  Object.defineProperty(file, "arrayBuffer", {
    value: () => {
      throw new Error("must not read local bytes");
    },
  });
  const taken = await intakeFiles([file], {
    allowImages: true,
    localPaths: async () => [{ path: "/project/archive.zip", folder: false }],
  });
  expect(taken.error).toBeUndefined();
  expect(taken.attachments[0]).toMatchObject({ path: "/project/archive.zip", size: file.size });
});

test("session upload receives files above 64 MiB without a composer size refusal", async () => {
  const file = new File([], "archive.zip", { type: "application/zip" });
  Object.defineProperty(file, "size", { value: 80 * 1024 * 1024 });
  let sent: File[] = [];
  const taken = await intakeFiles([file], {
    allowImages: true,
    upload: async (files) => {
      sent = files;
      return { paths: ["/remote/session/archive.zip"] };
    },
  });
  expect(sent).toEqual([file]);
  expect(taken.error).toBeUndefined();
  expect(taken.attachments[0]?.path).toBe("/remote/session/archive.zip");
});

test("images use a 1568 px preview and retain the session path of the original", async () => {
  const drawn = imageEngine(3136, 1568);
  const file = new File(["EXIF GPS original"], "photo.jpg", { type: "image/jpeg" });
  const taken = await intakeFiles([file], {
    allowImages: true,
    upload: async (files) => ({ paths: files.map(() => "/session/original/photo.jpg") }),
  });
  expect(drawn).toEqual([{ width: 1568, height: 784 }]);
  expect(taken.attachments[0]).toMatchObject({
    kind: "image",
    originalPath: "/session/original/photo.jpg",
  });
  const blocks = promptBlocks("inspect", taken.attachments);
  expect(blocks).toContainEqual({
    type: "resource_link",
    uri: "file:///session/original/photo.jpg",
    name: "photo.jpg",
  });
  expect(taken.attachments[0]?.data).toBe(btoa("clean pixels"));
});

test("a small image is reencoded too, so metadata is never passed through", async () => {
  const drawn = imageEngine(320, 240);
  const result = await readAttachment(new File(["EXIF GPS"], "small.jpg", { type: "image/jpeg" }), true);
  expect(drawn).toEqual([{ width: 320, height: 240 }]);
  expect(result).toMatchObject({ kind: "image", data: btoa("clean pixels") });
});
