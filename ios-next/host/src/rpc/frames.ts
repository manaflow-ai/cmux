// PROTOCOL.md §3 binary stream frames: [u8 kind][u32 BE streamId][payload].

import { FrameKind } from "../protocol.ts";
import type { Lane } from "../transport/link.ts";

export function encodeFrame(kind: number, streamId: number, payload: Uint8Array): Uint8Array {
  const out = new Uint8Array(5 + payload.byteLength);
  const view = new DataView(out.buffer);
  view.setUint8(0, kind);
  view.setUint32(1, streamId >>> 0, false);
  out.set(payload, 5);
  return out;
}

export function decodeFrame(data: Uint8Array): { kind: number; streamId: number; payload: Uint8Array } | null {
  if (data.byteLength < 5) return null;
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  return { kind: view.getUint8(0), streamId: view.getUint32(1, false), payload: data.subarray(5) };
}

export function laneForKind(kind: number): Lane {
  return kind === FrameKind.browserFrame || kind === FrameKind.fileChunk ? "blk" : "int";
}

export interface BrowserFrameHeader {
  seq: number;
  cssW: number;
  cssH: number;
  pxW: number;
  pxH: number;
  format: 0 | 1;
}

export const BROWSER_FRAME_HEADER = 13;

export function encodeBrowserFramePayload(h: BrowserFrameHeader, image: Uint8Array): Uint8Array {
  const out = new Uint8Array(BROWSER_FRAME_HEADER + image.byteLength);
  const v = new DataView(out.buffer);
  v.setUint32(0, h.seq >>> 0, false);
  v.setUint16(4, clamp16(h.cssW), false);
  v.setUint16(6, clamp16(h.cssH), false);
  v.setUint16(8, clamp16(h.pxW), false);
  v.setUint16(10, clamp16(h.pxH), false);
  v.setUint8(12, h.format);
  out.set(image, BROWSER_FRAME_HEADER);
  return out;
}

export function decodeBrowserFramePayload(p: Uint8Array): { header: BrowserFrameHeader; image: Uint8Array } {
  const v = new DataView(p.buffer, p.byteOffset, p.byteLength);
  return {
    header: {
      seq: v.getUint32(0, false),
      cssW: v.getUint16(4, false),
      cssH: v.getUint16(6, false),
      pxW: v.getUint16(8, false),
      pxH: v.getUint16(10, false),
      format: v.getUint8(12) as 0 | 1,
    },
    image: p.subarray(BROWSER_FRAME_HEADER),
  };
}

function clamp16(n: number): number {
  return Math.max(0, Math.min(0xffff, Math.round(n)));
}
