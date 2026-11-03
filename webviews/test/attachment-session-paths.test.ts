import { afterEach, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { promptBlocks, readAttachment } from "../src/agent-session/acpmux/attachments";
import { intakeFiles } from "../src/agent-session/acpmux/composer/intakeFiles";
import { uploadToMachine } from "../src/agent-session/acpmux/cloudUploads";

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

// PDFs, text, and unrecognized binary files share the session upload path. Only bounded slices
// may be read; an obsolete inline reader must never get a chance to load the whole file.
test("large PDFs, text and unknown binary files stream complete originals as prompt references", async () => {
  const specifications = [
    ["reference.pdf", "application/pdf", 16 * 1024 * 1024 + 7],
    ["notes.txt", "text/plain", 4 * 1024 * 1024 + 5],
    ["opaque.custom", "application/x-custom", 3 * 1024 * 1024 + 1],
  ] as const;
  const expected = new Map<string, string>();
  let largestRead = 0;
  const files = specifications.map(([name, type, size]) => {
    const bytes = new Uint8Array(size);
    for (let index = 0; index < size; index++) bytes[index] = index % 251;
    expected.set(name, createHash("sha256").update(bytes).digest("hex"));
    const file = new File([bytes], name, { type });
    const slice = file.slice.bind(file);
    Object.defineProperties(file, {
      arrayBuffer: {
        value: () => {
          throw new Error("whole-file read");
        },
      },
      text: {
        value: () => {
          throw new Error("whole-file text read");
        },
      },
      slice: {
        value: (start: number, end: number) => {
          largestRead = Math.max(largestRead, end - start);
          expect(end - start).toBeLessThanOrEqual(512 * 1024);
          return slice(start, end);
        },
      },
    });
    return file;
  });
  expect(await readAttachment(files[0]!, true)).toEqual({
    name: "reference.pdf",
    reason: "unsupported",
  });
  expect(await readAttachment(files[1]!, true)).toEqual({
    name: "notes.txt",
    reason: "unsupported",
  });
  expect(await readAttachment(files[2]!, true)).toEqual({
    name: "opaque.custom",
    reason: "unsupported",
  });
  const stages = new Map<string, { name: string; size: number; offset: number; hash: ReturnType<typeof createHash> }>();
  const completed = new Map<string, string>();
  let begins = 0;
  const native = async (method: string, params: Record<string, unknown>) => {
    if (method === "chat.upload.begin") {
      const token = `stage-${begins++}`;
      stages.set(token, {
        name: params.name as string,
        size: params.size as number,
        offset: 0,
        hash: createHash("sha256"),
      });
      return { token, size: params.size, chunkSize: 512 * 1024, batchToken: "batch" };
    }
    const stage = stages.get(params.token as string)!;
    expect(stage).toBeDefined();
    if (method === "chat.upload.chunk") {
      expect(params.offset).toBe(stage.offset);
      const chunk = Buffer.from(params.data as string, "base64");
      expect(chunk.length).toBeLessThanOrEqual(512 * 1024);
      stage.hash.update(chunk);
      stage.offset += chunk.length;
      return { offset: stage.offset };
    }
    expect(method).toBe("chat.upload.finish");
    expect(stage.offset).toBe(stage.size);
    completed.set(stage.name, stage.hash.digest("hex"));
    return { path: `/session/uploads/${stage.name}` };
  };
  const progress = new Map<number, number>();
  const result = await intakeFiles(
    files,
    {
      allowImages: true,
      upload: (batch, cancelled, report) => uploadToMachine(batch, native, cancelled, report),
    },
    { progress: (index, done) => progress.set(index, done) },
  );
  expect(result.error).toBeUndefined();
  expect(completed).toEqual(expected);
  expect(largestRead).toBe(512 * 1024);
  expect(begins).toBe(files.length);
  const blocks = promptBlocks("inspect all originals", result.attachments);
  for (const [index, [name, mimeType, size]] of specifications.entries()) {
    expect(progress.get(index)).toBe(1);
    expect(result.attachments[index]).toMatchObject({ kind: "link", name, mimeType, size });
    expect(blocks).toContainEqual({
      type: "resource_link",
      uri: `file:///session/uploads/${name}`,
      name,
    });
  }
  expect(blocks.some((block) => block.type === "document" || block.type === "audio")).toBe(false);
});
