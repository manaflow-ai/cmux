// A video's tile shape from its file's header (composer/videoShape.ts): read from the track header
// wherever `moov` is, turned by its matrix, without reading the media, and one answer per file.
import { describe, expect, test } from "bun:test";

import {
  VIDEO_RATIO,
  chipVideoRatio,
  videoHeaderSize,
  videoRatio,
  videoShapeOf,
} from "../src/agent-session/acpmux/composer/videoShape";

function box(type: string, ...parts: Uint8Array[]): Uint8Array<ArrayBuffer> {
  const size = 8 + parts.reduce((sum, part) => sum + part.length, 0);
  const out = new Uint8Array(size);
  new DataView(out.buffer).setUint32(0, size);
  for (let at = 0; at < 4; at += 1) out[4 + at] = type.charCodeAt(at);
  let at = 8;
  for (const part of parts) {
    out.set(part, at);
    at += part.length;
  }
  return out;
}

/// A track header of `version` for a `width` x `height` picture; `turned`: a quarter turn (a phone
/// held upright).
function tkhd(width: number, height: number, { version = 0, turned = false } = {}): Uint8Array<ArrayBuffer> {
  const matrix = version === 1 ? 52 : 40;
  const body = new Uint8Array(matrix + 44);
  const view = new DataView(body.buffer);
  view.setUint8(0, version);
  if (turned) {
    view.setInt32(matrix + 4, 0x00010000);
    view.setInt32(matrix + 12, -0x00010000);
  } else {
    view.setInt32(matrix, 0x00010000);
    view.setInt32(matrix + 16, 0x00010000);
  }
  view.setInt32(matrix + 32, 0x40000000);
  view.setUint32(matrix + 36, width * 65536);
  view.setUint32(matrix + 40, height * 65536);
  return box("tkhd", body);
}

/// A movie whose media (`media` bytes) comes before `moov`, as a screen recording writes it; `wide`:
/// the media box gives its size in 64 bits.
function movie(tracks: Uint8Array[], media = 4096, wide = false): Blob {
  const ftyp = box("ftyp", new TextEncoder().encode("qt  \0\0\0\0qt  "));
  const head = new Uint8Array(wide ? 16 : 8);
  const view = new DataView(head.buffer);
  if (wide) {
    view.setUint32(0, 1);
    view.setBigUint64(8, BigInt(media + 16));
  } else view.setUint32(0, media + 8);
  head.set([0x6d, 0x64, 0x61, 0x74], 4);
  const moov = box("moov", box("mvhd", new Uint8Array(100)), ...tracks);
  return new Blob([ftyp, head, new Uint8Array(media), moov]);
}

describe("video header size", () => {
  test("a screen recording's size comes from its track header after its media", async () => {
    expect(await videoHeaderSize(movie([box("trak", tkhd(2880, 1800), box("mdia"))]))).toEqual({
      width: 2880,
      height: 1800,
    });
  });

  test("a sound track first is skipped for the picture's", async () => {
    const sound = box("trak", tkhd(0, 0), box("mdia"));
    expect(await videoHeaderSize(movie([sound, box("trak", tkhd(1920, 1080))]))).toEqual({ width: 1920, height: 1080 });
  });

  test("an upright phone recording is tall", async () => {
    expect(await videoHeaderSize(movie([box("trak", tkhd(1920, 1080, { turned: true }))]))).toEqual({
      width: 1080,
      height: 1920,
    });
  });

  test("a version 1 track header and a 64-bit media size", async () => {
    expect(await videoHeaderSize(movie([box("trak", tkhd(1280, 720, { version: 1 }))], 8192, true))).toEqual({
      width: 1280,
      height: 720,
    });
  });

  test("a file that is not a movie, or a cut one, has no size", async () => {
    expect(await videoHeaderSize(new Blob([new Uint8Array(64)]))).toBeUndefined();
    expect(await videoHeaderSize(new Blob(["not a movie at all"]))).toBeUndefined();
    const whole = movie([box("trak", tkhd(1920, 1080))]);
    expect(await videoHeaderSize(whole.slice(0, whole.size - 40))).toBeUndefined();
  });
});

describe("video tile shape", () => {
  test("its own shape within the bounds; the square when unknown", () => {
    expect(videoRatio({ width: 2880, height: 1800 })).toBe(1.6);
    expect(videoRatio({ width: 1920, height: 1080 })).toBe(VIDEO_RATIO.max);
    expect(videoRatio({ width: 1080, height: 1920 })).toBe(VIDEO_RATIO.min);
    expect(videoRatio(undefined)).toBe(1);
  });

  test("a chip keeps the shape it was pasted with, over its video's", () => {
    const video = { width: 1080, height: 1920 };
    expect(chipVideoRatio({ videoShape: 1, video })).toBe(1);
    expect(chipVideoRatio({ video })).toBe(VIDEO_RATIO.min);
  });

  test("one read per file: the loading tile and its chip get the same answer", async () => {
    const file = movie([box("trak", tkhd(2880, 1800))]);
    const first = videoShapeOf(file);
    expect(videoShapeOf(file)).toBe(first);
    expect(await first).toBe(1.6);
  });
});
