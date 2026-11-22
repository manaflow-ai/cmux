// Leo (dogfood 2026-10-08, 22-composer-image-chip.png): an attached image drew as an empty dark
// square. The chip draws a small thumbnail decoded from the image, cropped to fill its square,
// instead of handing the whole image (up to 5 MB, as a data: URL) to a 56px <img>.
import { afterEach, describe, expect, test } from "bun:test";
import * as attachments from "./attachments";

const globals = globalThis as Record<string, unknown>;
const saved = { createImageBitmap: globals.createImageBitmap, OffscreenCanvas: globals.OffscreenCanvas };
afterEach(() => Object.assign(globals, saved));

type Thumbnail = (image: { mimeType: string; data: string }, size?: number) => Promise<string | undefined>;
const thumbnail = (attachments as unknown as { thumbnail?: Thumbnail }).thumbnail;

describe("attachment thumbnail", () => {
  test("crops the image's center square and scales it to the thumbnail", async () => {
    const drawn: number[][] = [];
    let canvasSize: number[] = [];
    let decoded: Blob | undefined;
    globals.createImageBitmap = async (blob: Blob) => {
      decoded = blob;
      return { width: 400, height: 200, close() {} };
    };
    globals.OffscreenCanvas = class {
      constructor(width: number, height: number) {
        canvasSize = [width, height];
      }
      getContext() {
        return { drawImage: (_image: unknown, ...box: number[]) => drawn.push(box) };
      }
      async convertToBlob() {
        return new Blob([new Uint8Array([1, 2, 3])], { type: "image/png" });
      }
    };
    expect(typeof thumbnail).toBe("function");
    const url = await thumbnail!({ mimeType: "image/png", data: btoa("png") }, 112);
    expect(decoded?.type).toBe("image/png");
    expect(await decoded?.text()).toBe("png");
    expect(canvasSize).toEqual([112, 112]);
    expect(drawn).toEqual([[100, 0, 200, 200, 0, 0, 112, 112]]);
    expect(url).toBe(`data:image/png;base64,${btoa("\u0001\u0002\u0003")}`);
  });

  test("an image the engine cannot decode has no thumbnail", async () => {
    globals.createImageBitmap = async () => {
      throw new Error("decode failed");
    };
    globals.OffscreenCanvas = class {};
    expect(typeof thumbnail).toBe("function");
    expect(await thumbnail!({ mimeType: "image/png", data: btoa("nope") })).toBeUndefined();
  });
});
