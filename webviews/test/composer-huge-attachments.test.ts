// Leo, 2026-10-25: "are the fixes for all the composer attachment/image big size things fixed? like
// arbitarrily large file sizes the composer should never ever freeze and prevent new things from
// happening/from cancelling the thing". The pieces that keep a huge file cheap:
// - a picture past the pixel budget is never decoded: its header gives its size (imageSize);
// - an upload the person cancels stops at its next chunk and the host drops what it staged;
// - a paste past what a prompt carries goes as a file (pastedText.ts).
import { afterEach, expect, test } from "bun:test";
import { uploadToMachine } from "../src/agent-session/acpmux/cloudUploads";
import { imageSize, MAX_DECODE_PIXELS, prepareImage } from "../src/agent-session/acpmux/composer/imageWork";
import { PASTE_FILE_CHARS, pastedTextFile } from "../src/agent-session/acpmux/pastedText";

const g = globalThis as Record<string, unknown>;
afterEach(() => {
  delete g.createImageBitmap;
  delete g.OffscreenCanvas;
});

function png(width: number, height: number): Blob {
  const bytes = new Uint8Array(33);
  bytes.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]);
  const view = new DataView(bytes.buffer);
  view.setUint32(16, width);
  view.setUint32(20, height);
  return new Blob([bytes], { type: "image/png" });
}

function jpeg(width: number, height: number): Blob {
  // SOI, an APP0 segment, then SOF0 with the size.
  const app0 = [0xff, 0xe0, 0x00, 0x10, ...Array.from({ length: 14 }, () => 0)];
  const sof = [0xff, 0xc0, 0x00, 0x11, 0x08, height >> 8, height & 0xff, width >> 8, width & 0xff, 3];
  return new Blob([new Uint8Array([0xff, 0xd8, ...app0, ...sof, ...Array.from({ length: 12 }, () => 0)])], {
    type: "image/jpeg",
  });
}

test("a picture's size comes from its header, without decoding it", async () => {
  expect(await imageSize(png(14142, 14142))).toEqual({ known: true, width: 14142, height: 14142 });
  expect(await imageSize(jpeg(6000, 4000))).toEqual({ known: true, width: 6000, height: 4000 });
  expect(await imageSize(new Blob(["not a picture"]))).toBeUndefined();
});

// Review (Codex): an iPhone JPEG's metadata can pass 64 KiB before its frame header.
test("a JPEG's size is found past metadata segments of any size", async () => {
  // Two 40 KiB APP segments (a segment's length is 16 bits), so the frame header is past 80 KiB.
  const body = new Uint8Array(40 * 1024);
  const app = [0xff, 0xe1, ((body.length + 2) >> 8) & 0xff, (body.length + 2) & 0xff];
  const sof = [0xff, 0xc0, 0x00, 0x11, 0x08, 9000 >> 8, 9000 & 0xff, 12000 >> 8, 12000 & 0xff, 3];
  const file = new Blob(
    [new Uint8Array([0xff, 0xd8]), new Uint8Array(app), body, new Uint8Array(app), body, new Uint8Array(sof)],
    { type: "image/jpeg" },
  );
  expect(await imageSize(file)).toEqual({ known: true, width: 12000, height: 9000 });
});

test("a picture whose size cannot be read is known as one and never decoded", async () => {
  // A WebP VP8X header cut short, and a PNG with no IHDR.
  const webp = new Uint8Array(29);
  webp.set([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x58]);
  expect(await imageSize(new Blob([webp]))).toEqual({ known: true });
  let decoded = 0;
  g.createImageBitmap = async () => {
    decoded += 1;
    throw new Error("decoded");
  };
  g.OffscreenCanvas = class {};
  expect(
    await prepareImage(new Blob([new Uint8Array([0x89, 0x50, 0x4e, 0x47])], { type: "image/png" })),
  ).toBeUndefined();
  expect(decoded).toBe(0);
});

test("a 200-megapixel picture is never decoded: it goes as a file", async () => {
  let decoded = 0;
  g.createImageBitmap = async () => {
    decoded += 1;
    throw new Error("decoded");
  };
  g.OffscreenCanvas = class {};
  expect(14142 * 14142).toBeGreaterThan(MAX_DECODE_PIXELS);
  expect(await prepareImage(png(14142, 14142))).toBeUndefined();
  expect(decoded).toBe(0);
});

test("a cancelled upload stops at its next chunk and the host drops what it staged", async () => {
  const calls: string[] = [];
  const chunks: Record<string, number> = {};
  let cancelNow = false;
  const host = async (method: string, params: Record<string, unknown>) => {
    calls.push(method);
    if (method === "chat.upload.begin") return { token: params.name, size: params.size, chunkSize: 512 * 1024 };
    if (method === "chat.upload.chunk") {
      const token = params.token as string;
      chunks[token] = (chunks[token] ?? 0) + 1;
      if (chunks["capture.bin"] === 3) cancelNow = true;
      return { offset: (params.offset as number) + atob(params.data as string).length };
    }
    if (method === "chat.upload.finish") return { path: "/tmp/kept.bin" };
    return null;
  };
  // A 64 MB file and a small one: the big one is cancelled after three chunks, the small one goes.
  const big = new File([new Uint8Array(64 * 1024 * 1024)], "capture.bin");
  const small = new File(["notes"], "notes.txt");
  const sent = await uploadToMachine([big, small], host, (index) => index === 0 && cancelNow);
  // Three of the big file's 128 chunks, then none; the small file whole.
  expect(chunks).toEqual({ "capture.bin": 3, "notes.txt": 1 });
  expect(calls).toContain("chat.upload.cancel");
  expect(sent).toEqual({ paths: ["", "/tmp/kept.bin"] });
});

test("a paste past what a prompt carries is a file of its text, made a slice per task", async () => {
  // Past one slice, with a character of two halves (an emoji) right on a slice's end.
  const head = "x".repeat(4 * 1024 * 1024 - 1);
  const text = `${head}😀${"y".repeat(PASTE_FILE_CHARS)}`;
  const file = await pastedTextFile(text);
  expect(file.name).toBe("Pasted text.txt");
  expect(await file.text()).toBe(text);
});

// Review (Codex): a batch's host takes its files in the manifest's order; a file cancelled before its
// upload begins is begun and cancelled at once, so the files after it still go.
test("a file cancelled before its upload begins keeps the batch's order for the rest", async () => {
  const begun: string[] = [];
  const cancels: string[] = [];
  const host = async (method: string, params: Record<string, unknown>) => {
    if (method === "chat.upload.begin") {
      begun.push(params.name as string);
      return { token: params.name, size: params.size, chunkSize: 512 * 1024, batchToken: "b" };
    }
    if (method === "chat.upload.chunk")
      return { offset: (params.offset as number) + atob(params.data as string).length };
    if (method === "chat.upload.finish") return { path: `/tmp/${String(params.token)}` };
    if (method === "chat.upload.cancel") cancels.push(params.token as string);
    return null;
  };
  const files = ["a.bin", "b.bin", "c.bin"].map((name) => new File(["bytes"], name));
  const sent = await uploadToMachine(files, host, (index) => index === 1);
  expect(begun).toEqual(["a.bin", "b.bin", "c.bin"]);
  expect(cancels).toEqual(["b.bin"]);
  expect(sent).toEqual({ paths: ["/tmp/a.bin", "", "/tmp/c.bin"] });
});

test("an older host still gets the one-frame upload when the first file is cancelled", async () => {
  const calls: string[] = [];
  const host = async (method: string, params: Record<string, unknown>) => {
    calls.push(method);
    if (method === "chat.upload.begin") throw Object.assign(new Error("unsupported"), { code: "unsupported" });
    if (method === "chat.upload")
      return { uploads: (params.files as { name: string }[]).map((file) => ({ path: `/tmp/${file.name}` })) };
    return null;
  };
  const files = ["a.txt", "b.txt"].map((name) => new File(["bytes"], name));
  const sent = await uploadToMachine(files, host, (index) => index === 0);
  expect(calls).toContain("chat.upload");
  expect(sent).toEqual({ paths: ["", "/tmp/b.txt"] });
});

// Review (Codex): a picture the engine converts has no header read here; past a phone photo's size
// it goes as a file, never decoded.
test("a huge picture of a converted type is never decoded", async () => {
  let decoded = 0;
  g.createImageBitmap = async () => {
    decoded += 1;
    throw new Error("decoded");
  };
  g.OffscreenCanvas = class {};
  const heic = new File([new Uint8Array(41 * 1024 * 1024)], "big.heic", { type: "image/heic" });
  expect(await prepareImage(heic)).toBeUndefined();
  expect(decoded).toBe(0);
});

test("an older host's limit counts only the files not cancelled", async () => {
  const host = async (method: string, params: Record<string, unknown>) => {
    if (method === "chat.upload.begin") throw Object.assign(new Error("unsupported"), { code: "unsupported" });
    if (method === "chat.upload")
      return { uploads: (params.files as { name: string }[]).map((file) => ({ path: `/tmp/${file.name}` })) };
    return null;
  };
  const files = [new File([new Uint8Array(25 * 1024 * 1024)], "big.bin"), new File(["small"], "small.txt")];
  expect(await uploadToMachine(files, host, (index) => index === 0)).toEqual({ paths: ["", "/tmp/small.txt"] });
});
