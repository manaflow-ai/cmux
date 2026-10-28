import { afterEach, describe, expect, test } from "bun:test";
import {
  IMAGE_BUDGET_BYTES,
  MAX_IMAGE_BYTES,
  MAX_IMAGE_SIDE,
  readAttachment,
} from "../src/agent-session/acpmux/attachments";

/// A fake engine: createImageBitmap reports `width`×`height`; each canvas encodes to `encoded(type)`
/// bytes (given the canvas width) and records its size, so a test sees what was drawn and which
/// encodings were tried.
function installEngine(width: number, height: number, encoded: (type: string, width: number) => number) {
  const drawn: { width: number; height: number; type: string }[] & { closed?: number } = [];
  drawn.closed = 0;
  const g = globalThis as Record<string, unknown>;
  g.createImageBitmap = async () => ({
    width,
    height,
    close() {
      drawn.closed! += 1;
    },
  });
  g.OffscreenCanvas = class {
    constructor(
      public width: number,
      public height: number,
    ) {}
    getContext() {
      return { drawImage() {}, fillRect() {}, fillStyle: "" };
    }
    async convertToBlob({ type }: { type: string }) {
      // The chip's thumbnail (160 px tall) is drawn from the same decode; only the preview counts.
      if (this.height !== 160) drawn.push({ width: this.width, height: this.height, type });
      return new Blob([new Uint8Array(encoded(type, this.width))], { type });
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
    expect(result).toMatchObject({
      kind: "image",
      name: "image.png",
      mimeType: "image/png",
      size: 1024,
    });
    expect([...drawn]).toEqual([{ width: MAX_IMAGE_SIDE, height: 882, type: "image/png" }]);
    expect(drawn.closed).toBe(1);
  });

  test("keeps the scaled image's base64 under the limit, not only its bytes", async () => {
    const limit = Math.floor((MAX_IMAGE_BYTES * 3) / 4);
    installEngine(4000, 4000, (type) => (type === "image/png" ? limit + 1 : limit));
    const result = await readAttachment(big("image.png"), true);
    if ("reason" in result) throw new Error(`refused: ${result.reason}`);
    expect(result.mimeType).toBe("image/jpeg");
    expect(result.data!.length).toBeLessThanOrEqual(MAX_IMAGE_BYTES);
  });

  test("encodes a JPEG source straight to JPEG, and names a re-encoded GIF .png", async () => {
    const drawn = installEngine(6000, 4000, () => 1024);
    const photo = await readAttachment(big("photo.jpeg", "image/jpeg"), true);
    expect(photo).toMatchObject({ name: "photo.jpg", mimeType: "image/jpeg" });
    expect(drawn.map((d) => d.type)).toEqual(["image/jpeg"]);
    expect(await readAttachment(big("anim.gif", "image/gif"), true)).toMatchObject({
      name: "anim.png",
      mimeType: "image/png",
    });
  });

  test("falls back to JPEG, renamed, when the scaled PNG is still too large", async () => {
    installEngine(4000, 4000, (type) => (type === "image/png" ? MAX_IMAGE_BYTES + 1 : 2048));
    const result = await readAttachment(big("Screen Shot.png"), true);
    if ("reason" in result) throw new Error(`refused: ${result.reason}`);
    expect(result).toMatchObject({ name: "Screen Shot.jpg", mimeType: "image/jpeg", size: 2048 });
  });

  // Leo, 2026-10-24: "we shouldn't have this limit". Past every step the smallest try goes.
  test("is never refused for its size: past every step its smallest try goes", async () => {
    const drawn = installEngine(4000, 4000, () => MAX_IMAGE_BYTES + 1);
    expect(await readAttachment(big("huge.png"), true)).toMatchObject({ name: "huge.jpg", mimeType: "image/jpeg" });
    expect(drawn.at(-1)).toEqual({ width: 512, height: 512, type: "image/jpeg" });
  });

  test("goes as a file where the engine cannot draw images", async () => {
    expect(await readAttachment(big("image.png"), true)).toEqual({
      name: "image.png",
      reason: "unsupported",
    });
  });
});

// Never refuse a person's screenshots (Leo, 2026-10-20): every image goes at about the size the
// models use, so six Retina screenshots no longer make a prompt past acpmux's frame limit.
describe("any image", () => {
  const small = (name: string, type = "image/png") => new File([new Uint8Array(100 * 1024)], name, { type });

  test("wider than the longest side is scaled to it, however few its bytes", async () => {
    const drawn = installEngine(3024, 1964, () => 512 * 1024);
    const result = await readAttachment(small("Screenshot.png"), true);
    if ("reason" in result) throw new Error(`refused: ${result.reason}`);
    expect(result).toMatchObject({
      name: "Screenshot.png",
      mimeType: "image/png",
      size: 512 * 1024,
    });
    expect([...drawn]).toEqual([{ width: MAX_IMAGE_SIDE, height: 1018, type: "image/png" }]);
  });

  test("within the side and the budget is still reencoded to strip metadata", async () => {
    const drawn = installEngine(1200, 800, () => 1);
    const gif = await readAttachment(small("party.gif", "image/gif"), true);
    expect(gif).toMatchObject({ name: "party.png", mimeType: "image/png", size: 1 });
    expect([...drawn]).toEqual([{ width: 1200, height: 800, type: "image/png" }]);
    expect(drawn.closed).toBe(1);
  });

  test("over the budget steps down in size until it fits, rather than being refused", async () => {
    const heavy = new File([new Uint8Array(IMAGE_BUDGET_BYTES + 1)], "noise.png", {
      type: "image/png",
    });
    // Only a canvas at most 1200 wide encodes under the budget, and only as JPEG.
    const drawn = installEngine(4000, 3000, (type, width) =>
      type === "image/jpeg" && width <= 1200 ? IMAGE_BUDGET_BYTES : IMAGE_BUDGET_BYTES * 2,
    );
    const result = await readAttachment(heavy, true);
    if ("reason" in result) throw new Error(`refused: ${result.reason}`);
    expect(result).toMatchObject({
      name: "noise.jpg",
      mimeType: "image/jpeg",
      size: IMAGE_BUDGET_BYTES,
    });
    expect(drawn.at(-1)).toEqual({ width: 1200, height: 900, type: "image/jpeg" });
  });

  test("does not pass unsanitized bytes through when the image engine is unavailable", async () => {
    expect(await readAttachment(small("plain.png"), true)).toEqual({
      name: "plain.png",
      reason: "unsupported",
    });
  });
});
