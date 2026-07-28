// SPDX-License-Identifier: GPL-3.0-or-later

import {
  BINARY_KIND_BASELINE,
  BINARY_KIND_INPUT,
  encodeTerminalFrame,
  TERMINAL_FRAME_HEADER_BYTES,
} from "../src/protocol";

const encoder = new TextEncoder();
const TEST_EPOCH = "12345678-1234-4567-89ab-123456789abc";
const ZERO_EPOCH = "00000000-0000-0000-0000-000000000000";

export function baselineFrame(
  ws: string,
  pane: string,
  payload: Uint8Array = new Uint8Array(),
): Uint8Array {
  return encodeTerminalFrame({
    kind: BINARY_KIND_BASELINE,
    epoch: TEST_EPOCH,
    sequenceStart: 0n,
    sequenceEnd: 0n,
    rows: 24,
    columns: 80,
    ws,
    pane,
    user: "",
    payload,
  });
}

export function exactBaselineFrame(
  ws: string,
  pane: string,
  targetByteCount: number,
): Uint8Array {
  const overhead =
    TERMINAL_FRAME_HEADER_BYTES +
    encoder.encode(ws).byteLength +
    encoder.encode(pane).byteLength;
  if (targetByteCount < overhead) {
    throw new Error("target is smaller than the terminal frame header");
  }
  return baselineFrame(
    ws,
    pane,
    new Uint8Array(targetByteCount - overhead),
  );
}

export function inputFrame(
  ws: string,
  pane: string,
  payload: Uint8Array = new Uint8Array([0x61]),
): Uint8Array {
  return encodeTerminalFrame({
    kind: BINARY_KIND_INPUT,
    epoch: ZERO_EPOCH,
    sequenceStart: 0n,
    sequenceEnd: 0n,
    rows: 0,
    columns: 0,
    ws,
    pane,
    user: "",
    payload,
  });
}
