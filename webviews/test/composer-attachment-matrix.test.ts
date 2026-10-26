// The attachment matrix (file types × how the prompt carries them): one row per type a person drops,
// pastes or chooses, checked from the files to the ACP prompt blocks the agent receives.
// - Images (png, jpg, gif, webp) go as image blocks; HEIC, TIFF, BMP and AVIF are converted to PNG
//   or JPEG when the engine decodes them.
// - Every non-image file goes as a session path with short name/type/size metadata.
// - Anything else (zip, video, audio, an unknown binary, a file past a block's size, an image for an
//   agent that takes none) goes to the chat's host, which saves it; its chip sends the saved path as
//   a resource_link plus a short name/type/size note, never its bytes.
// - A folder's bytes cannot be read: it is not sent, and the rest of the batch still is.
// - In a chat whose folder is on this Mac, a dropped or pasted folder, or a file no block takes,
//   goes as a resource_link to where it is (the host's `chat.attach.dropped` answers its real
//   path): nothing is copied or uploaded. Images retain a normalized preview plus the original path.
import { beforeEach, afterEach, describe, expect, test } from "bun:test";
import {
  linkItems,
  promptBlocks,
  type ComposerAttachment,
  type LinkItem,
} from "../src/agent-session/acpmux/attachments";
import { type UploadResult } from "../src/agent-session/acpmux/cloudUploads";
import { intakeFiles } from "../src/agent-session/acpmux/composer/intakeFiles";

// A PNG's signature and IHDR (640x480): the composer reads a picture's size from its header before
// it decodes it (composer/imageWork.ts imageSize), and refuses to decode one it cannot size.
const PNG = new Uint8Array([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, 0, 0, 2, 0x80, 0, 0, 1, 0xe0, 8,
  6,
]);

function file(name: string, type: string, bytes: Uint8Array | string = new Uint8Array([0, 1, 2, 0xff])): File {
  return new File([bytes as BlobPart], name, { type });
}

function sized(name: string, type: string, size: number): File {
  return new File([new Uint8Array(size)], name, { type });
}

/// A dropped folder: WebKit hands a File whose bytes cannot be read.
function folder(name: string): File {
  const entry = new File([], name, { type: "" });
  Object.defineProperty(entry, "arrayBuffer", {
    value: () => Promise.reject(new Error("not a file")),
  });
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
  options: {
    allowImages?: boolean;
    upload?: boolean | ((f: File[]) => Promise<UploadResult>);
    localPaths?: (f: File[]) => Promise<LinkItem[] | undefined>;
  } = {},
) {
  const saving = host();
  const upload =
    typeof options.upload === "function" ? options.upload : options.upload === false ? undefined : saving.upload;
  const taken = await intakeFiles(files, {
    allowImages: options.allowImages ?? true,
    ...(upload ? { upload } : {}),
    ...(options.localPaths ? { localPaths: options.localPaths } : {}),
  });
  const blocks = promptBlocks("Look at these", taken.attachments);
  return {
    ...taken,
    blocks,
    sent: saving.sent,
    text: blocks.find((block) => block.type === "text")?.text ?? "",
  };
}

function only<T>(items: readonly T[]): T {
  expect(items.length).toBe(1);
  return items[0]!;
}

beforeEach(() => installEngine());

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
      expect(image).toMatchObject({
        type: "image",
        mimeType: type === "image/jpeg" ? type : "image/png",
        name: name.replace(/\.(gif|webp)$/, ".png"),
      });
      expect(result.sent.map((batch) => batch.map((each) => each.name))).toEqual([[name]]);
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
      expect(result.sent.map((batch) => batch.map((each) => each.name))).toEqual([[name]]);
    });

  test("a HEIC the engine cannot decode goes as its saved path", async () => {
    delete (globalThis as Record<string, unknown>).createImageBitmap;
    const result = await take([file("IMG_0002.HEIC", "image/heic")]);
    expect(result.blocks.filter((block) => block.type === "image")).toEqual([]);
    expect(only(result.blocks.filter((block) => block.type === "resource_link"))).toEqual({
      type: "resource_link",
      uri: "file:///saved/1-0/IMG_0002.HEIC",
      name: "IMG_0002.HEIC",
    });
  });

  test("a PDF too large for one message goes as its saved path, not a document block", async () => {
    // 12 MiB of PDF is 16 MiB of base64: past acpmux's one-message bound (#23247) and the
    // WebSocket's 16 MiB frame, which reset the chat's connection with no error.
    const result = await take([sized("scan.pdf", "application/pdf", 12 * 1024 * 1024)]);
    expect(result.blocks.filter((block) => block.type === "document")).toEqual([]);
    expect(only(result.blocks.filter((block) => block.type === "resource_link"))).toEqual({
      type: "resource_link",
      uri: "file:///saved/1-0/scan.pdf",
      name: "scan.pdf",
    });
    expect(result.error).toBeUndefined();
  });

  test("a PDF goes as a session file path", async () => {
    const result = await take([file("spec.pdf", "application/pdf", "%PDF-1.4\n")]);
    expect(result.blocks.some((block) => block.type === "document")).toBe(false);
    expect(only(result.blocks.filter((block) => block.type === "resource_link"))).toMatchObject({
      name: "spec.pdf",
    });
  });

  for (const [name, type] of [
    ["notes.txt", "text/plain", "txt"],
    ["README.md", "text/markdown", "md"],
    ["main.rs", "", "rs"],
    ["table.csv", "text/csv", "csv"],
    ["config.json", "application/json", "json"],
    ["logo.svg", "image/svg+xml", "svg"],
  ] as const)
    test(`${name} goes as a file path without the file body`, async () => {
      const result = await take([file(name, type, "hello, world\n")]);
      expect(result.blocks.map((block) => block.type)).toEqual(["text", "resource_link"]);
      expect(result.text).toContain(name);
      expect(result.text).not.toContain("hello, world");
    });

  for (const [name, type, size] of [
    ["archive.zip", "application/zip", 64],
    ["clip.mov", "video/quicktime", 64],
    ["voice.mp3", "audio/mpeg", 64],
    ["blob.bin", "", 64],
    ["huge.log", "text/plain", 256 * 1024 + 1],
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
      expect(result.text).not.toContain("/saved/");
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

  test("large files are passed to session storage without a composer cap", async () => {
    const result = await take([sized("disk.img", "", 80 * 1024 * 1024), file("small.zip", "application/zip")]);
    expect(result.sent.map((batch) => batch.map((each) => each.name))).toEqual([["disk.img", "small.zip"]]);
    expect(result.error).toBeUndefined();
  });

  test("where the host saves nothing, a file no block takes leaves a note and no chip", async () => {
    const result = await take([file("archive.zip", "application/zip")], { upload: false });
    expect(result.attachments).toEqual([]);
    expect(result.error).toEqual({ name: "archive.zip", reason: "unsupported" });
  });

  test("a host that does not take uploads leaves the composer's own note", async () => {
    const result = await take([file("archive.zip", "application/zip")], {
      upload: async () => undefined,
    });
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

  test("many files at once: every attachment is accepted", async () => {
    const files = Array.from({ length: 12 }, (_, index) =>
      index % 2 ? file(`shot-${index}.png`, "image/png", PNG) : file(`part-${index}.zip`, "application/zip"),
    );
    const result = await take(files);
    expect(result.attachments.length).toBe(files.length);
    expect(result.error).toBeUndefined();
  });

  test("no row puts a data: URI or a saved path in the prompt's text", async () => {
    installEngine();
    const result = await take([
      file("shot.png", "image/png", PNG),
      file("IMG.HEIC", "image/heic"),
      file("spec.pdf", "application/pdf", "%PDF-1.4\n"),
      file("archive.zip", "application/zip"),
    ]);
    expect(result.text).not.toContain("data:");
    expect(result.text).not.toContain("/saved/");
    const kinds = result.attachments.map((chip: ComposerAttachment) => chip.kind);
    expect(kinds).toEqual(["image", "image", "link", "link"]);
  });
});

/// A host on this Mac that knows where each file of the batch is: `/Users/dev/<name>`, a folder's
/// marked; records the batches it was asked about.
function paths(folders: string[] = []) {
  const asked: string[][] = [];
  const localPaths = async (batch: File[]): Promise<LinkItem[]> => {
    asked.push(batch.map((each) => each.name));
    return batch.map((each) => ({
      path: `/Users/dev/${each.name}`,
      folder: folders.includes(each.name),
    }));
  };
  return { asked, localPaths };
}

describe("attachment matrix: a chat on this Mac links what no block takes where it is", () => {
  test("a folder, a zip and a png dropped together: an image block, and links to the folder and the zip; nothing uploaded", async () => {
    const local = paths(["src"]);
    const result = await take(
      [folder("src"), file("build.zip", "application/zip"), file("shot.png", "image/png", PNG)],
      { localPaths: local.localPaths },
    );
    // The host is asked about the whole batch, in its order (it matches the drop by name).
    expect(local.asked).toEqual([["src", "build.zip", "shot.png"]]);
    expect(result.sent).toEqual([]);
    expect(result.error).toBeUndefined();
    expect(result.attachments.map((chip) => [chip.kind, chip.name, chip.path, chip.saved])).toEqual([
      ["image", "shot.png", undefined, undefined],
      ["link", "src/", "/Users/dev/src", undefined],
      ["link", "build.zip", "/Users/dev/build.zip", undefined],
    ]);
    expect(result.blocks.map((block) => block.type)).toEqual([
      "text",
      "image",
      "resource_link",
      "resource_link",
      "resource_link",
    ]);
    expect(result.blocks.filter((block) => block.type === "resource_link")).toEqual([
      { type: "resource_link", uri: "file:///Users/dev/shot.png", name: "shot.png" },
      { type: "resource_link", uri: "file:///Users/dev/src", name: "src/" },
      { type: "resource_link", uri: "file:///Users/dev/build.zip", name: "build.zip" },
    ]);
    expect(result.text).not.toContain("data:");
  });

  for (const [name, type, size] of [
    ["clip.mov", "video/quicktime", 64],
    ["huge.log", "text/plain", 256 * 1024 + 1],
    ["disk.img", "", 80 * 1024 * 1024],
  ] as const)
    test(`${name} goes as a link to where it is, however large`, async () => {
      const local = paths();
      const result = await take([sized(name, type, size)], { localPaths: local.localPaths });
      expect(result.sent).toEqual([]);
      expect(only(result.attachments)).toMatchObject({
        kind: "link",
        name,
        path: `/Users/dev/${name}`,
      });
      expect(result.error).toBeUndefined();
    });

  test("an image for an agent that takes none links to the picture itself", async () => {
    const local = paths();
    const result = await take([file("shot.png", "image/png", PNG)], {
      allowImages: false,
      localPaths: local.localPaths,
    });
    expect(result.sent).toEqual([]);
    expect(only(result.attachments)).toMatchObject({ kind: "link", path: "/Users/dev/shot.png" });
  });

  test("an image retains its preview and text files become links", async () => {
    const local = paths();
    const result = await take([file("shot.png", "image/png", PNG), file("notes.txt", "text/plain", "hi\n")], {
      localPaths: local.localPaths,
    });
    expect(result.attachments.map((chip) => chip.kind)).toEqual(["image", "link"]);
  });

  test("the host is asked before any file is read: its record of the drop lasts only seconds", async () => {
    const order: string[] = [];
    const photo = file("shot.png", "image/png", PNG);
    const read = photo.arrayBuffer.bind(photo);
    Object.defineProperty(photo, "arrayBuffer", {
      value: () => {
        order.push("read");
        return read();
      },
    });
    const local = paths();
    await take([folder("src"), photo], {
      localPaths: (batch) => {
        order.push("asked");
        return local.localPaths(batch);
      },
    });
    expect(order[0]).toBe("asked");
  });

  test("a folder as WebKit hands it (`<name>.zip`, application/zip, unreadable) links to the folder", async () => {
    const assets = folder("assets.zip");
    Object.defineProperty(assets, "type", { value: "application/zip" });
    const result = await take([assets], {
      localPaths: async () => [{ path: "/Users/dev/assets", folder: true }],
    });
    expect(result.sent).toEqual([]);
    expect(result.error).toBeUndefined();
    expect(only(result.attachments)).toMatchObject({
      kind: "link",
      name: "assets/",
      path: "/Users/dev/assets",
    });
  });

  test("a host that knows no paths for the batch: the upload, as before", async () => {
    for (const answer of [[], undefined, [{ path: "/Users/dev/other.zip", folder: false }]]) {
      const result = await take([folder("src"), file("build.zip", "application/zip")], {
        localPaths: async () => answer,
      });
      expect(result.sent.map((batch) => batch.map((each) => each.name))).toEqual([["build.zip"]]);
      expect(only(result.attachments)).toMatchObject({
        kind: "link",
        saved: true,
        path: "/saved/1-0/build.zip",
      });
      expect(result.error).toEqual({ name: "src", reason: "unsupported" });
    }
  });

  test("a host that fails to answer: the upload, as before", async () => {
    const result = await take([file("build.zip", "application/zip")], {
      localPaths: () => Promise.reject(new Error("unsupported")),
    });
    expect(only(result.attachments)).toMatchObject({ kind: "link", saved: true });
  });

  test("more than ten links are accepted", async () => {
    const local = paths();
    const files = Array.from({ length: 11 }, (_, index) => file(`part-${index}.zip`, "application/zip"));
    const result = await take(files, { localPaths: local.localPaths });
    expect(result.attachments.length).toBe(files.length);
    expect(result.sent).toEqual([]);
    expect(result.error).toBeUndefined();
  });
});

describe("linkItems: the host's answer of files and folders on this Mac", () => {
  test("keeps absolute paths, a folder only when it says so", () => {
    expect(
      linkItems({
        items: [
          { path: "/Users/dev/src", folder: true },
          { path: "relative/notes.md" },
          { path: 5 },
          { folder: true },
          { path: "/Users/dev/build.zip", folder: "yes" },
        ],
      }),
    ).toEqual([
      { path: "/Users/dev/src", folder: true },
      { path: "/Users/dev/build.zip", folder: false },
    ]);
  });

  test("anything else is no items", () => {
    for (const value of [null, undefined, "x", { items: "x" }, { items: [null] }, []])
      expect(linkItems(value)).toEqual([]);
  });
});
