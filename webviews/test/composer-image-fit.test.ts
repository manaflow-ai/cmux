// The composer never scales the picture it sends (Leo, "What every coder should know about gamma";
// claude-sr2-coord, 2026-11-17: "Composer image fit: do it in Rust, not JS"). A canvas averages
// sRGB codes, so a 1 px black and white checkerboard scaled in the page came out 127 grey where
// its light is 188. The page re-encodes the picture at its own size (to drop its metadata), and
// acpmux fits it to the model in linear light (cmux-tui acpmux `model_copies::fit_inline`).
import { afterEach, describe, expect, test } from "bun:test";
import { MAX_IMAGE_BYTES, readAttachment } from "../src/agent-session/acpmux/attachments";

type Drawn = { width: number; height: number; type: string; scaled: boolean };

/// A fake engine: createImageBitmap reports `width`×`height`; each canvas encodes to `encoded(type)`
/// bytes and records its size, its type and whether the picture was drawn scaled into it, so a test
/// sees what was drawn.
function installEngine(width: number, height: number, encoded: (type: string) => number = () => 1024) {
  const drawn: Drawn[] & { closed?: number } = [];
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
    scaled = false;
    constructor(
      public width: number,
      public height: number,
    ) {}
    getContext() {
      return {
        // drawImage(image, dx, dy) draws one pixel per pixel; any other form may scale.
        drawImage: (...args: unknown[]) => {
          this.scaled = args.length !== 3 || this.width !== width || this.height !== height;
        },
        fillRect() {},
        fillStyle: "",
      };
    }
    async convertToBlob({ type }: { type: string }) {
      // The chip's thumbnail (160 px tall) is drawn from the same decode, for the person's eyes
      // only: the browser may scale it. Only what is sent counts here.
      if (this.height !== 160) drawn.push({ width: this.width, height: this.height, type, scaled: this.scaled });
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

const file = (name: string, type = "image/png", size = 100 * 1024) => new File([new Uint8Array(size)], name, { type });

describe("a pasted picture goes at its own size, never scaled in the page", () => {
  test("a 5K screenshot is drawn one pixel per pixel, as PNG", async () => {
    const drawn = installEngine(5120, 2880);
    const result = await readAttachment(file("Screenshot.png"), true);
    if ("reason" in result) throw new Error(`refused: ${result.reason}`);
    expect(result).toMatchObject({ kind: "image", name: "Screenshot.png", mimeType: "image/png", size: 1024 });
    expect([...drawn]).toEqual([{ width: 5120, height: 2880, type: "image/png", scaled: false }]);
    expect(drawn.closed).toBe(1);
  });

  test("past the model's per-image bytes it still goes whole: acpmux fits it", async () => {
    const drawn = installEngine(6016, 3384, (type) => (type === "image/png" ? MAX_IMAGE_BYTES * 2 : 1));
    const result = await readAttachment(file("Retina.png", "image/png", MAX_IMAGE_BYTES + 1), true);
    if ("reason" in result) throw new Error(`refused: ${result.reason}`);
    expect(result).toMatchObject({ name: "Retina.png", mimeType: "image/png", size: MAX_IMAGE_BYTES * 2 });
    expect([...drawn]).toEqual([{ width: 6016, height: 3384, type: "image/png", scaled: false }]);
  });

  test("a JPEG photo goes as JPEG at its own size", async () => {
    const drawn = installEngine(6000, 4000);
    expect(await readAttachment(file("photo.jpeg", "image/jpeg"), true)).toMatchObject({
      name: "photo.jpg",
      mimeType: "image/jpeg",
    });
    expect([...drawn]).toEqual([{ width: 6000, height: 4000, type: "image/jpeg", scaled: false }]);
  });

  test("a small GIF is still re-encoded, to strip its metadata, at its own size", async () => {
    const drawn = installEngine(1200, 800, () => 1);
    expect(await readAttachment(file("party.gif", "image/gif"), true)).toMatchObject({
      name: "party.png",
      mimeType: "image/png",
      size: 1,
    });
    expect([...drawn]).toEqual([{ width: 1200, height: 800, type: "image/png", scaled: false }]);
  });

  test("does not pass unsanitized bytes through when the image engine is unavailable", async () => {
    expect(await readAttachment(file("plain.png"), true)).toEqual({ name: "plain.png", reason: "unsupported" });
  });
});
