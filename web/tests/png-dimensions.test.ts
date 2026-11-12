import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pngDimensions } from "../app/[locale]/(landing)/docs/changelog/png-dimensions";

const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

function ihdrPrefix(width: number, height: number, type = "IHDR"): Buffer {
  const chunk = Buffer.alloc(4 + 4 + 13);
  chunk.writeUInt32BE(13, 0);
  chunk.write(type, 4, "latin1");
  chunk.writeUInt32BE(width, 8);
  chunk.writeUInt32BE(height, 12);
  chunk[16] = 8; // bit depth
  chunk[17] = 6; // RGBA
  return Buffer.concat([PNG_SIGNATURE, chunk]);
}

describe("pngDimensions on shipped changelog art", () => {
  test("matches the known size of a real screenshot", () => {
    expect(pngDimensions("/changelog/0.61.0-command-palette.png")).toEqual({
      width: 1172,
      height: 1006,
    });
  });
});

describe("pngDimensions on synthetic files", () => {
  const originalCwd = process.cwd();
  let root = "";

  beforeAll(() => {
    root = mkdtempSync(join(tmpdir(), "png-dimensions-"));
    mkdirSync(join(root, "public", "img"), { recursive: true });
    const put = (name: string, bytes: Buffer) => writeFileSync(join(root, "public", "img", name), bytes);
    put("wide.png", Buffer.concat([ihdrPrefix(70_000, 3), Buffer.alloc(64)]));
    put("exact.png", ihdrPrefix(1, 2).subarray(0, 24));
    put("short.png", ihdrPrefix(10, 10).subarray(0, 20));
    put("jpeg.png", Buffer.from([0xff, 0xd8, 0xff, 0xe0, ...new Array(40).fill(0)]));
    put("no-ihdr.png", ihdrPrefix(10, 10, "tEXt"));
    put("empty.png", ihdrPrefix(0, 5));
    process.chdir(root);
  });

  afterAll(() => {
    process.chdir(originalCwd);
    rmSync(root, { recursive: true, force: true });
  });

  test("decodes big-endian sizes above 16 bits", () => {
    expect(pngDimensions("/img/wide.png")).toEqual({ width: 70_000, height: 3 });
  });

  test("needs only the bytes through the height field", () => {
    expect(pngDimensions("img/exact.png")).toEqual({ width: 1, height: 2 });
  });

  test("rejects a truncated header", () => {
    expect(() => pngDimensions("/img/short.png")).toThrow(/too short/);
  });

  test("rejects a file without the PNG signature", () => {
    expect(() => pngDimensions("/img/jpeg.png")).toThrow(/signature/);
  });

  test("rejects a first chunk that is not IHDR", () => {
    expect(() => pngDimensions("/img/no-ihdr.png")).toThrow(/IHDR/);
  });

  test("rejects a zero dimension", () => {
    expect(() => pngDimensions("/img/empty.png")).toThrow(/empty image/);
  });

  test("surfaces a missing file", () => {
    expect(() => pngDimensions("/img/missing.png")).toThrow();
  });
});
