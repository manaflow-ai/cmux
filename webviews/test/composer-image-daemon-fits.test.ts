// To an acpmux that fits images (it lists `fitsImages`), the composer never scales or re-encodes
// a pasted PNG or JPEG: it sends the person's own file, and acpmux removes its metadata and fits it
// to the model in linear light (Leo, "What every coder should know about gamma"; claude-sr2-coord,
// 2026-11-17: "for PNG and JPEG, send the file's own bytes with no canvas re-encode"). A canvas
// averages sRGB codes, so a 1 px checkerboard scaled in the page came out 127 grey where its light
// is 188. To any other acpmux (an older build, or a Cloud or SSH machine's) the page still fits
// the picture itself, as composer-image-fit.test.ts checks: that daemon would pass a full-size
// picture to a model that refuses one over 5 MiB.
import { afterEach, describe, expect, test } from "bun:test";
import { readAttachment } from "../src/agent-session/acpmux/attachments";
import * as direct from "../src/agent-session/acpmux/direct";

const { AcpmuxDirectClient } = direct;

type Drawn = { width: number; height: number; type: string; scaled: boolean };

/// A fake engine: createImageBitmap reports `width`×`height`; each canvas encodes to `encoded(type)`
/// bytes and records what was encoded and whether the picture was drawn scaled into it. The chip's
/// thumbnail (160 px tall), for the person's eyes alone, is left out.
function installEngine(width: number, height: number, encoded: (type: string) => number = () => 1024) {
  const drawn: Drawn[] & { closed?: number; decoded?: number } = [];
  drawn.closed = 0;
  drawn.decoded = 0;
  const g = globalThis as Record<string, unknown>;
  g.createImageBitmap = async () => {
    drawn.decoded! += 1;
    return {
      width,
      height,
      close() {
        drawn.closed! += 1;
      },
    };
  };
  g.OffscreenCanvas = class {
    scaled = false;
    constructor(
      public width: number,
      public height: number,
    ) {}
    getContext() {
      return {
        drawImage: (...args: unknown[]) => {
          this.scaled = args.length !== 3 || this.width !== width || this.height !== height;
        },
        fillRect() {},
        fillStyle: "",
      };
    }
    async convertToBlob({ type }: { type: string }) {
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

const PNG = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
/// SOI, an APP1 (EXIF) of 14 bytes, then a baseline frame header (SOF0) giving its size.
const JPEG = [
  0xff,
  0xd8,
  0xff,
  0xe1,
  0x00,
  0x10,
  ...Array.from({ length: 14 }, () => 0x45),
  0xff,
  0xc0,
  0x00,
  0x11,
  0x08,
];

/// A file of `size` bytes starting with `signature`, then its `side` where its header says it.
function picture(name: string, type: string, signature: number[], size = 64 * 1024, side = [5120, 2880]) {
  const bytes = new Uint8Array(size);
  bytes.set(signature);
  if (signature === PNG) {
    bytes.set([0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52], 8);
    new DataView(bytes.buffer).setUint32(16, side[0]!);
    new DataView(bytes.buffer).setUint32(20, side[1]!);
  } else {
    // SOF0's height then width, after its length and precision.
    new DataView(bytes.buffer).setUint16(signature.length, side[1]!);
    new DataView(bytes.buffer).setUint16(signature.length + 2, side[0]!);
  }
  for (let at = signature.length + 24; at < size; at += 1) bytes[at] = (at * 31) & 0xff;
  return { file: new File([bytes], name, { type }), bytes };
}

const asBase64 = (bytes: Uint8Array) => Buffer.from(bytes).toString("base64");
const fits = { daemonFits: true };

describe("to a daemon that fits images, a PNG or JPEG goes as the person's own file", () => {
  test("a 5K screenshot is neither scaled nor encoded again: its own bytes go", async () => {
    const drawn = installEngine(5120, 2880);
    const { file, bytes } = picture("Screenshot.png", "image/png", PNG, 15 * 1024 * 1024);
    const result = await readAttachment(file, true, undefined, fits);
    if ("reason" in result) throw new Error(`refused: ${result.reason}`);
    expect(result).toMatchObject({ kind: "image", name: "Screenshot.png", mimeType: "image/png", size: bytes.length });
    expect(result.data).toBe(asBase64(bytes));
    // Decoded once, for the chip's thumbnail alone; nothing encoded for the prompt.
    expect([...drawn]).toEqual([]);
    expect([drawn.decoded, drawn.closed]).toEqual([1, 1]);
  });

  test("a phone's JPEG goes as it is: acpmux removes its EXIF and GPS", async () => {
    const drawn = installEngine(6000, 4000);
    const { file, bytes } = picture("IMG_0001.JPG", "image/jpeg", JPEG);
    const result = await readAttachment(file, true, undefined, fits);
    if ("reason" in result) throw new Error(`refused: ${result.reason}`);
    expect(result).toMatchObject({ name: "IMG_0001.jpg", mimeType: "image/jpeg", data: asBase64(bytes) });
    expect([...drawn]).toEqual([]);
  });

  test("its type is its bytes', not its name's", async () => {
    installEngine(800, 600);
    const { file, bytes } = picture("really-a-jpeg.png", "image/png", JPEG);
    expect(await readAttachment(file, true, undefined, fits)).toMatchObject({
      name: "really-a-jpeg.jpg",
      mimeType: "image/jpeg",
      data: asBase64(bytes),
    });
  });

  test("a GIF is drawn again at its own size, as PNG, never scaled", async () => {
    const drawn = installEngine(1200, 800, () => 1);
    expect(
      await readAttachment(new File([new Uint8Array(1024)], "party.gif", { type: "image/gif" }), true, undefined, fits),
    ).toMatchObject({
      name: "party.png",
      mimeType: "image/png",
      size: 1,
    });
    expect([...drawn]).toEqual([{ width: 1200, height: 800, type: "image/png", scaled: false }]);
  });

  test("a picture the engine cannot decode goes as a file, never as its bytes", async () => {
    installEngine(10, 10);
    (globalThis as Record<string, unknown>).createImageBitmap = async () => {
      throw new Error("not a picture");
    };
    const { file } = picture("broken.png", "image/png", PNG);
    expect(await readAttachment(file, true, undefined, fits)).toEqual({ name: "broken.png", reason: "unsupported" });
  });
});

describe("to any other daemon, the page fits the picture as it always did", () => {
  test("the same 5K screenshot is scaled to 1568 px, as PNG", async () => {
    const drawn = installEngine(5120, 2880);
    const { file } = picture("Screenshot.png", "image/png", PNG, 15 * 1024 * 1024);
    for (const prepare of [undefined, { daemonFits: false }]) {
      drawn.length = 0;
      const result = await readAttachment(file, true, undefined, prepare);
      if ("reason" in result) throw new Error(`refused: ${result.reason}`);
      expect(result).toMatchObject({ mimeType: "image/png", size: 1024 });
      expect([...drawn]).toEqual([{ width: 1568, height: 882, type: "image/png", scaled: true }]);
    }
  });
});

/// The handshake the page already reads (`initialize`'s `_meta.acpmux.features`) says which.
async function connected(features: string[]) {
  let snapshot: { daemonFitsImages?: true } | undefined;
  let socket: any;
  const client = await AcpmuxDirectClient.connect(
    { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:1/", newSession: true },
    (value) => {
      snapshot = value;
    },
    undefined,
    () => {
      socket = {
        readyState: 1,
        send(raw: string) {
          const message = JSON.parse(raw);
          if (message.id === undefined) return;
          const result =
            message.method === "initialize"
              ? { protocolVersion: 1, _meta: { acpmux: { origin: "local", features, extensions: [], operations: [] } } }
              : message.method === "_acpmux/watch"
                ? { sessions: [] }
                : null;
          queueMicrotask(() =>
            socket.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: message.id, result }) }),
          );
        },
        close() {},
      };
      queueMicrotask(() => socket.onopen?.());
      return socket as WebSocket;
    },
  );
  const seen = snapshot;
  client.close();
  return seen;
}

test("the composer sends own bytes only to an acpmux that lists fitsImages", async () => {
  expect(direct.FITS_IMAGES_FEATURE).toBe("fitsImages");
  expect((await connected(["promptUploads", "fitsImages"]))?.daemonFitsImages).toBe(true);
  // An older acpmux, or a remote machine's on an older build.
  expect((await connected(["promptUploads"]))?.daemonFitsImages).toBeUndefined();
  expect((await connected([]))?.daemonFitsImages).toBeUndefined();
});
