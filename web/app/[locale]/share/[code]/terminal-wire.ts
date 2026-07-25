import {
  MAX_BINARY_MESSAGE_BYTES,
  MAX_TERMINAL_INPUT_BYTES,
  wireId,
} from "./share-protocol";
import type {
  TerminalBaselineFrame,
  TerminalOutputFrame,
} from "./terminal-stream";

export const TERMINAL_TRANSPORT_VERSION = 1;
export const TERMINAL_HEADER_BYTES = 56;
export const TERMINAL_KIND_BASELINE = 0x01;
export const TERMINAL_KIND_OUTPUT = 0x02;
export const TERMINAL_KIND_INPUT = 0x03;
export const TERMINAL_KIND_FORWARDED_INPUT = 0x04;

const MAGIC = new Uint8Array([0x43, 0x4d, 0x58, 0x53]);
const ZERO_EPOCH = new Uint8Array(16);
const utf8Encoder = new TextEncoder();
const utf8Decoder = new TextDecoder("utf-8", { fatal: true });

export type DecodedTerminalFrame = {
  readonly kind:
    | typeof TERMINAL_KIND_BASELINE
    | typeof TERMINAL_KIND_OUTPUT
    | typeof TERMINAL_KIND_INPUT
    | typeof TERMINAL_KIND_FORWARDED_INPUT;
  readonly terminalVersion: number;
  readonly flags: number;
  readonly streamEpoch: string | null;
  readonly sequenceStart: bigint;
  readonly sequenceEnd: bigint;
  readonly rows: number;
  readonly columns: number;
  readonly ws: string;
  readonly pane: string;
  readonly user: string;
  readonly payload: Uint8Array;
};

function epochIsZero(epoch: Uint8Array): boolean {
  return epoch.every((byte) => byte === 0);
}

function epochString(epoch: Uint8Array): string {
  const hex = [...epoch]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
  return [
    hex.slice(0, 8),
    hex.slice(8, 12),
    hex.slice(12, 16),
    hex.slice(16, 20),
    hex.slice(20),
  ].join("-");
}

function hasMagic(bytes: Uint8Array): boolean {
  return MAGIC.every((byte, index) => bytes[index] === byte);
}

function supportedKind(kind: number): kind is DecodedTerminalFrame["kind"] {
  return (
    kind === TERMINAL_KIND_BASELINE ||
    kind === TERMINAL_KIND_OUTPUT ||
    kind === TERMINAL_KIND_INPUT ||
    kind === TERMINAL_KIND_FORWARDED_INPUT
  );
}

function validGeometry(rows: number, columns: number): boolean {
  return rows > 0 && columns > 0;
}

function validSemantics(frame: DecodedTerminalFrame): boolean {
  const hasEpoch = frame.streamEpoch !== null;
  const hasGeometry = validGeometry(frame.rows, frame.columns);
  switch (frame.kind) {
    case TERMINAL_KIND_BASELINE:
      return (
        hasEpoch &&
        hasGeometry &&
        frame.sequenceStart === frame.sequenceEnd &&
        frame.user.length === 0
      );
    case TERMINAL_KIND_OUTPUT:
      return (
        hasEpoch &&
        (hasGeometry || (frame.rows === 0 && frame.columns === 0)) &&
        frame.sequenceEnd >= frame.sequenceStart &&
        frame.sequenceEnd - frame.sequenceStart ===
          BigInt(frame.payload.byteLength) &&
        frame.user.length === 0
      );
    case TERMINAL_KIND_INPUT:
      return (
        !hasEpoch &&
        frame.sequenceStart === BigInt(0) &&
        frame.sequenceEnd === BigInt(0) &&
        frame.rows === 0 &&
        frame.columns === 0 &&
        frame.user.length === 0 &&
        frame.payload.byteLength > 0 &&
        frame.payload.byteLength <= MAX_TERMINAL_INPUT_BYTES
      );
    case TERMINAL_KIND_FORWARDED_INPUT:
      return (
        !hasEpoch &&
        frame.sequenceStart === BigInt(0) &&
        frame.sequenceEnd === BigInt(0) &&
        frame.rows === 0 &&
        frame.columns === 0 &&
        wireId(frame.user) &&
        frame.payload.byteLength > 0 &&
        frame.payload.byteLength <= MAX_TERMINAL_INPUT_BYTES
      );
  }
}

/** Decode one canonical, fixed-header CMXS terminal frame. */
export function decodeTerminalFrame(
  bytes: Uint8Array,
): DecodedTerminalFrame | null {
  if (
    bytes.byteLength < TERMINAL_HEADER_BYTES ||
    bytes.byteLength >= MAX_BINARY_MESSAGE_BYTES ||
    !hasMagic(bytes)
  ) {
    return null;
  }
  try {
    const view = new DataView(
      bytes.buffer,
      bytes.byteOffset,
      bytes.byteLength,
    );
    const terminalVersion = view.getUint8(4);
    const kind = view.getUint8(5);
    const flags = view.getUint16(6, false);
    const epochBytes = bytes.subarray(8, 24);
    const sequenceStart = view.getBigUint64(24, false);
    const sequenceEnd = view.getBigUint64(32, false);
    const rows = view.getUint16(40, false);
    const columns = view.getUint16(42, false);
    const wsLength = view.getUint16(44, false);
    const paneLength = view.getUint16(46, false);
    const userLength = view.getUint16(48, false);
    const reserved = view.getUint16(50, false);
    const payloadLength = view.getUint32(52, false);
    if (
      terminalVersion !== TERMINAL_TRANSPORT_VERSION ||
      !supportedKind(kind) ||
      flags !== 0 ||
      reserved !== 0
    ) {
      return null;
    }

    const wsStart = TERMINAL_HEADER_BYTES;
    const paneStart = wsStart + wsLength;
    const userStart = paneStart + paneLength;
    const payloadStart = userStart + userLength;
    const payloadEnd = payloadStart + payloadLength;
    if (
      paneStart < wsStart ||
      userStart < paneStart ||
      payloadStart < userStart ||
      payloadEnd !== bytes.byteLength
    ) {
      return null;
    }

    const ws = utf8Decoder.decode(bytes.subarray(wsStart, paneStart));
    const pane = utf8Decoder.decode(bytes.subarray(paneStart, userStart));
    const user = utf8Decoder.decode(bytes.subarray(userStart, payloadStart));
    if (!wireId(ws) || !wireId(pane)) return null;
    const frame: DecodedTerminalFrame = {
      kind,
      terminalVersion,
      flags,
      streamEpoch: epochIsZero(epochBytes)
        ? null
        : epochString(epochBytes),
      sequenceStart,
      sequenceEnd,
      rows,
      columns,
      ws,
      pane,
      user,
      payload: bytes.slice(payloadStart, payloadEnd),
    };
    return validSemantics(frame) ? frame : null;
  } catch {
    return null;
  }
}

export function terminalStreamFrame(
  frame: DecodedTerminalFrame,
  protocolVersion: number,
): TerminalBaselineFrame | TerminalOutputFrame | null {
  if (frame.streamEpoch === null) return null;
  if (frame.kind === TERMINAL_KIND_BASELINE) {
    return {
      kind: "baseline",
      protocolVersion,
      terminalVersion: frame.terminalVersion,
      streamEpoch: frame.streamEpoch,
      sequenceEnd: frame.sequenceEnd,
      rows: frame.rows,
      columns: frame.columns,
      data: frame.payload,
    };
  }
  if (frame.kind === TERMINAL_KIND_OUTPUT) {
    return {
      kind: "output",
      streamEpoch: frame.streamEpoch,
      sequenceStart: frame.sequenceStart,
      sequenceEnd: frame.sequenceEnd,
      data: frame.payload,
    };
  }
  return null;
}

/** Encode byte-exact xterm input. The relay injects the authenticated user. */
export function encodeTerminalInputFrame(
  ws: string,
  pane: string,
  payload: Uint8Array,
): Uint8Array | null {
  if (
    !wireId(ws) ||
    !wireId(pane) ||
    payload.byteLength === 0 ||
    payload.byteLength > MAX_TERMINAL_INPUT_BYTES
  ) {
    return null;
  }
  const wsBytes = utf8Encoder.encode(ws);
  const paneBytes = utf8Encoder.encode(pane);
  if (wsBytes.byteLength > 0xffff || paneBytes.byteLength > 0xffff) return null;
  const total =
    TERMINAL_HEADER_BYTES +
    wsBytes.byteLength +
    paneBytes.byteLength +
    payload.byteLength;
  if (total >= MAX_BINARY_MESSAGE_BYTES) return null;
  const bytes = new Uint8Array(total);
  const view = new DataView(bytes.buffer);
  bytes.set(MAGIC, 0);
  view.setUint8(4, TERMINAL_TRANSPORT_VERSION);
  view.setUint8(5, TERMINAL_KIND_INPUT);
  view.setUint16(6, 0, false);
  bytes.set(ZERO_EPOCH, 8);
  view.setBigUint64(24, BigInt(0), false);
  view.setBigUint64(32, BigInt(0), false);
  view.setUint16(40, 0, false);
  view.setUint16(42, 0, false);
  view.setUint16(44, wsBytes.byteLength, false);
  view.setUint16(46, paneBytes.byteLength, false);
  view.setUint16(48, 0, false);
  view.setUint16(50, 0, false);
  view.setUint32(52, payload.byteLength, false);
  let offset = TERMINAL_HEADER_BYTES;
  bytes.set(wsBytes, offset);
  offset += wsBytes.byteLength;
  bytes.set(paneBytes, offset);
  offset += paneBytes.byteLength;
  bytes.set(payload, offset);
  return bytes;
}
