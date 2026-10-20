import { afterEach, describe, expect, test } from "bun:test";
import { MAX_IMAGE_BYTES, MAX_IMAGE_SIDE, readAttachment } from "../src/agent-session/acpmux/attachments";

/// A fake engine: createImageBitmap reports `width`×`height`; each canvas encodes to `encoded(type)`
/// bytes and records its size, so a test sees what was drawn and which encodings were tried.
function installEngine(width: number, height: number, encoded: (type: string) => number) {
  const drawn: { width: number; height: number; type: string }[] = [];
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
      drawn.push({ width: this.width, height: this.height, type });
      return new Blob([new Uint8Array(encoded(type))], { type });
    }
  };
  return drawn;
}

afterEach(() => {
  const g = globalThis as Record<string, unknown>;
  delete g.createImageBitmap;
  delete g.OffscreenCanvas;
});

const big = (name: string, type = "image/png") => new File([new Uint8Array(MAX_IMAGE_BYTES + 1)], name, { type });

describe("an image over the per-image limit", () => {
  test("attaches scaled to the longest side as PNG when that fits", async () => {
    const drawn = installEngine(5120, 2880, () => 1024);
    const result = await readAttachment(big("image.png"), true);
    expect("reason" in result).toBe(false);
    if ("reason" in result) return;
    expect(result).toMatchObject({ kind: "image", name: "image.png", mimeType: "image/png", size: 1024 });
    expect(drawn).toEqual([{ width: MAX_IMAGE_SIDE, height: 1440, type: "image/png" }]);
  });

  test("falls back to JPEG, renamed, when the scaled PNG is still too large", async () => {
    installEngine(4000, 4000, (type) => (type === "image/png" ? MAX_IMAGE_BYTES + 1 : 2048));
    const result = await readAttachment(big("Screen Shot.png"), true);
    if ("reason" in result) throw new Error(`refused: ${result.reason}`);
    expect(result).toMatchObject({ name: "Screen Shot.jpg", mimeType: "image/jpeg", size: 2048 });
  });

  test("is refused as too large only when no encoding fits", async () => {
    installEngine(4000, 4000, () => MAX_IMAGE_BYTES + 1);
    expect(await readAttachment(big("huge.png"), true)).toEqual({ name: "huge.png", reason: "tooLarge" });
  });

  test("is refused as too large where the engine cannot scale images", async () => {
    expect(await readAttachment(big("image.png"), true)).toEqual({ name: "image.png", reason: "tooLarge" });
  });
});
