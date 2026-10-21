// The attachment matrix (file types × how the prompt carries them): one row per type a person drops,
// pastes or chooses, checked from the files to the ACP prompt blocks the agent receives.
// - Images (png, jpg, gif, webp) go as image blocks; HEIC, TIFF, BMP and AVIF are converted to PNG
//   or JPEG when the engine decodes them.
// - PDFs go as document blocks; text, code, CSV, JSON and SVG go in the prompt's text, fenced.
// - Anything else (zip, video, audio, an unknown binary, a file past a block's size, an image for an
//   agent that takes none) goes to the chat's host, which saves it; its chip sends the saved path as
//   a resource_link, and the prompt's text never names it or carries its bytes.
// - A folder's bytes cannot be read: it is not sent, and the rest of the batch still is.
import { afterEach, describe, expect, test } from "bun:test";
import {
  MAX_ATTACHMENTS,
  MAX_TEXT_BYTES,
  promptBlocks,
  type ComposerAttachment,
} from "../src/agent-session/acpmux/attachments";
import { MAX_UPLOAD_FILE_BYTES, type UploadResult } from "../src/agent-session/acpmux/cloudUploads";
import { intakeFiles } from "../src/agent-session/acpmux/composer/intakeFiles";

const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3]);

function file(name: string, type: string, bytes: Uint8Array | string = new Uint8Array([0, 1, 2, 0xff])): File {
  return new File([bytes as BlobPart], name, { type });
}

function sized(name: string, type: string, size: number): File {
  return new File([new Uint8Array(size)], name, { type });
}

/// A dropped folder: WebKit hands a File whose bytes cannot be read.
function folder(name: string): File {
  const entry = new File([], name, { type: "" });
  Object.defineProperty(entry, "arrayBuffer", { value: () => Promise.reject(new Error("not a file")) });
  return entry;
}

/// A host that saves each file under /saved/<n>/<name> and records what it was sent.
function host() {
  const sent: File[][] = [];
  const upload = async (files: File[]): Promise<UploadResult> => {
    sent.push(files);
    return { paths: files.map((each, index) => `/saved/${sent.length}-${index}/${each.name}`) };
  };
  return { sent, upload };
}

async function take(
  files: File[],
  options: { allowImages?: boolean; upload?: boolean | ((f: File[]) => Promise<UploadResult>) } = {},
) {
  const saving = host();
  const upload =
    typeof options.upload === "function" ? options.upload : options.upload === false ? undefined : saving.upload;
  const taken = await intakeFiles(files, {
    held: 0,
    allowImages: options.allowImages ?? true,
    ...(upload ? { upload } : {}),
  });
  const blocks = promptBlocks("Look at these", taken.attachments);
  return { ...taken, blocks, sent: saving.sent, text: blocks.find((block) => block.type === "text")?.text ?? "" };
}

function only<T>(items: readonly T[]): T {
  expect(items.length).toBe(1);
  return items[0]!;
}

afterEach(() => {
  const g = globalThis as Record<string, unknown>;
  delete g.createImageBitmap;
  delete g.OffscreenCanvas;
});

/// A fake engine that decodes anything to `width`×`height` and encodes each canvas to a few bytes.
function installEngine(width = 1200, height = 900) {
  const g = globalThis as Record<string, unknown>;
  g.createImageBitmap = async () => ({ width, height, close() {} });
  g.OffscreenCanvas = class {
    constructor(
      public width: number,
      public height: number,
    ) {}
    getContext() {
      return { drawImage() {}, fillRect() {}, fillStyle: "" };
    }
    async convertToBlob({ type }: { type: string }) {
      return new Blob([new Uint8Array(64)], { type });
    }
  };
}

describe("attachment matrix: what the agent receives per file type", () => {
  for (const [name, type] of [
    ["shot.png", "image/png"],
    ["photo.jpg", "image/jpeg"],
    ["loop.gif", "image/gif"],
    ["pic.webp", "image/webp"],
  ] as const)
    test(`${name} goes as an image block`, async () => {
      const result = await take([file(name, type, PNG)]);
      const image = only(result.blocks.filter((block) => block.type === "image"));
      expect(image).toMatchObject({ type: "image", mimeType: type, name });
      expect(result.sent).toEqual([]);
      expect(result.error).toBeUndefined();
    });

  for (const [name, type] of [
    ["IMG_0001.HEIC", "image/heic"],
    ["scan.tiff", "image/tiff"],
    ["old.bmp", "image/bmp"],
    ["new.avif", "image/avif"],
    ["typeless.heic", ""],
  ] as const)
    test(`${name} is converted to an image block when the engine decodes it`, async () => {
      installEngine();
      const result = await take([file(name, type)]);
      const image = only(result.blocks.filter((block) => block.type === "image"));
      expect(image.type === "image" && ["image/png", "image/jpeg"].includes(image.mimeType)).toBe(true);
      expect(image.type === "image" && /\.(png|jpg)$/.test(image.name ?? "")).toBe(true);
      expect(result.sent).toEqual([]);
    });

  test("a HEIC the engine cannot decode goes as its saved path", async () => {
    const result = await take([file("IMG_0002.HEIC", "image/heic")]);
    expect(result.blocks.filter((block) => block.type === "image")).toEqual([]);
    expect(only(result.blocks.filter((block) => block.type === "resource_link"))).toEqual({
      type: "resource_link",
      uri: "file:///saved/1-0/IMG_0002.HEIC",
      name: "IMG_0002.HEIC",
    });
  });

  test("a PDF goes as a document block", async () => {
    const result = await take([file("spec.pdf", "application/pdf", "%PDF-1.4\n")]);
    expect(only(result.blocks.filter((block) => block.type === "document"))).toMatchObject({
      type: "document",
      mimeType: "application/pdf",
      name: "spec.pdf",
    });
  });

  for (const [name, type, fence] of [
    ["notes.txt", "text/plain", "txt"],
    ["README.md", "text/markdown", "md"],
    ["main.rs", "", "rs"],
    ["table.csv", "text/csv", "csv"],
    ["config.json", "application/json", "json"],
    ["logo.svg", "image/svg+xml", "svg"],
  ] as const)
    test(`${name} goes in the prompt's text, fenced`, async () => {
      const result = await take([file(name, type, "hello, world\n")]);
      expect(result.blocks.map((block) => block.type)).toEqual(["text"]);
      expect(result.text).toContain(`${name}\n\`\`\`${fence}\nhello, world\n\`\`\``);
    });

  for (const [name, type, size] of [
    ["archive.zip", "application/zip", 64],
    ["clip.mov", "video/quicktime", 64],
    ["voice.mp3", "audio/mpeg", 64],
    ["blob.bin", "", 64],
    ["huge.log", "text/plain", MAX_TEXT_BYTES + 1],
    ["dataset.parquet", "", 12 * 1024 * 1024],
  ] as const)
    test(`${name} goes as a resource_link to the copy the host saved`, async () => {
      const result = await take([sized(name, type, size)]);
      expect(result.sent.map((batch) => batch.map((each) => each.name))).toEqual([[name]]);
      const chip = only(result.attachments);
      expect(chip).toMatchObject({ kind: "link", name, saved: true, path: `/saved/1-0/${name}` });
      expect(only(result.blocks.filter((block) => block.type === "resource_link"))).toMatchObject({
        uri: `file:///saved/1-0/${name}`,
        name,
      });
      // The path is not pasted into the prompt's text: the link carries it.
      expect(result.text).toBe("Look at these");
      expect(result.error).toBeUndefined();
    });

  test("an image for an agent that takes none goes as its saved path, not an image block", async () => {
    const result = await take([file("shot.png", "image/png", PNG)], { allowImages: false });
    expect(result.blocks.some((block) => block.type === "image")).toBe(false);
    expect(only(result.attachments)).toMatchObject({ kind: "link", name: "shot.png", saved: true });
  });

  test("a folder is not sent, and the rest of the batch still is", async () => {
    const result = await take([folder("src"), file("archive.zip", "application/zip")]);
    expect(result.sent.map((batch) => batch.map((each) => each.name))).toEqual([["archive.zip"]]);
    expect(only(result.attachments)).toMatchObject({ kind: "link", name: "archive.zip" });
    expect(result.error).toEqual({ name: "src", reason: "unsupported" });
  });

  test("two files with the same name each get their own saved path", async () => {
    const result = await take([file("notes.zip", "application/zip"), file("notes.zip", "application/zip")]);
    expect(result.attachments.map((chip) => chip.path)).toEqual(["/saved/1-0/notes.zip", "/saved/1-1/notes.zip"]);
  });

  test("a file past the upload's size is not sent; the files that fit still are", async () => {
    const result = await take([sized("disk.img", "", MAX_UPLOAD_FILE_BYTES + 1), file("small.zip", "application/zip")]);
    expect(result.sent.map((batch) => batch.map((each) => each.name))).toEqual([["small.zip"]]);
    expect(result.error).toEqual({ name: "disk.img", reason: "tooLarge" });
  });

  test("where the host saves nothing, a file no block takes leaves a note and no chip", async () => {
    const result = await take([file("archive.zip", "application/zip")], { upload: false });
    expect(result.attachments).toEqual([]);
    expect(result.error).toEqual({ name: "archive.zip", reason: "unsupported" });
  });

  test("a host that does not take uploads leaves the composer's own note", async () => {
    const result = await take([file("archive.zip", "application/zip")], { upload: async () => undefined });
    expect(result.attachments).toEqual([]);
    expect(result.error).toEqual({ name: "archive.zip", reason: "unsupported" });
  });

  test("the host's error is the note", async () => {
    const result = await take([file("archive.zip", "application/zip")], {
      upload: async () => ({ error: "Disk full" }),
    });
    expect(result.attachments).toEqual([]);
    expect(result.error).toEqual({ text: "Disk full" });
  });

  test("many files at once: up to the composer's limit, the rest refused", async () => {
    const files = Array.from({ length: MAX_ATTACHMENTS + 2 }, (_, index) =>
      index % 2 ? file(`shot-${index}.png`, "image/png", PNG) : file(`part-${index}.zip`, "application/zip"),
    );
    const result = await take(files);
    expect(result.attachments.length).toBe(MAX_ATTACHMENTS);
    expect(result.error).toEqual({ name: "part-8.zip", reason: "tooMany" });
  });

  test("no row puts a data: URI or a saved path in the prompt's text", async () => {
    installEngine();
    const result = await take([
      file("shot.png", "image/png", PNG),
      file("IMG.HEIC", "image/heic"),
      file("spec.pdf", "application/pdf", "%PDF-1.4\n"),
      file("archive.zip", "application/zip"),
    ]);
    expect(result.text).toBe("Look at these");
    expect(result.text).not.toContain("data:");
    expect(result.text).not.toContain("/saved/");
    const kinds = result.attachments.map((chip: ComposerAttachment) => chip.kind);
    expect(kinds).toEqual(["image", "image", "document", "link"]);
  });
});
