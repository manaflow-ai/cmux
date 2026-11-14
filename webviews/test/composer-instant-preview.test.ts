// Leo, 2026-11-07: "can't we make this all "appear" a lot faster". A pasted image's loading tile
// shows the file's own picture (attachmentIntakeModel.ts instantPreview), but never one whose pixels
// pass the limit its preview is held to: a few hundred KB of PNG can decode to gigabytes. The file
// still attaches; its tile just waits for the preview.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { instantPreview } from "../src/agent-session/acpmux/composer/attachmentIntakeModel";

/// A minimal FileReader over Bun's Blob, for `readAsDataURL` only.
class TestFileReader {
  result: string | null = null;
  onload: (() => void) | null = null;
  onerror: (() => void) | null = null;
  readAsDataURL(blob: Blob) {
    void blob.arrayBuffer().then((bytes) => {
      this.result = `data:${blob.type};base64,${Buffer.from(bytes).toString("base64")}`;
      this.onload?.();
    });
  }
}
const scope = globalThis as Record<string, unknown>;
const had = "FileReader" in scope;
beforeAll(() => {
  if (!had) scope.FileReader = TestFileReader;
});
afterAll(() => {
  if (!had) delete scope.FileReader;
});

/// A PNG's signature and IHDR claiming `width` x `height`, padded to `bytes`.
function png(width: number, height: number, bytes = 1024): File {
  const data = new Uint8Array(bytes);
  data.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]);
  const view = new DataView(data.buffer);
  view.setUint32(16, width);
  view.setUint32(20, height);
  return new File([data], "Screenshot.png", { type: "image/png" });
}

test("a screenshot-sized image shows its own picture at once", async () => {
  expect(await instantPreview(png(2880, 1800))).toStartWith("data:image/png;base64,");
});

test("a small file that decodes to too many pixels shows no picture of itself", async () => {
  // 14142 x 14142 is about 800 MB decoded, from a file under a megabyte.
  expect(await instantPreview(png(14142, 14142, 800 * 1024))).toBeUndefined();
});

test("a file whose header gives no size, or that is not an image, shows none", async () => {
  expect(await instantPreview(new File([new Uint8Array(64)], "x.png", { type: "image/png" }))).toBeUndefined();
  expect(await instantPreview(new File(["hello"], "notes.txt", { type: "text/plain" }))).toBeUndefined();
});
