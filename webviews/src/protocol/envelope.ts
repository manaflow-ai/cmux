// Wire envelope of the pane protocol (spec: "Wire"). Every text message is one JSON object
// with a `t` tag. Binary frames carry byte-stream data: [u32 stream id BE][u32 credit BE][payload].
//
// Additions beyond spec draft v0 (flagged for the IR/spec owners):
// - `open` carries `id` and optional `params`; the peer answers with the normal `ok`/`err`
//   for that id, so an unknown stream op fails like an unknown call.
// - `end` closes one direction of a byte stream; `code`/`message` mark an abort.
// - Stream ids are allocated by parity: the dialing side ("client") uses odd ids and the
//   accepting side ("server") even ids, so both peers can open streams without collisions.

export const MAX_MESSAGE_BYTES = 16 * 1024 * 1024;
export const MAX_U32 = 0xffff_ffff;
export const BINARY_HEADER_BYTES = 8;

export type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue };

export interface CallMessage {
  t: "call";
  id: number;
  op: string;
  params: unknown;
  cap?: string;
}
export interface OkMessage {
  t: "ok";
  id: number;
  value: unknown;
}
export interface ErrMessage {
  t: "err";
  id: number;
  code: string;
  message: string;
  retryable: boolean;
  details?: Record<string, unknown>;
}
export interface SubMessage {
  t: "sub";
  id: number;
  stream: string;
  filter?: Record<string, unknown>;
  cap?: string;
}
export interface EvMessage {
  t: "ev";
  sub: number;
  seq: number;
  data: unknown;
}
export interface UnsubMessage {
  t: "unsub";
  sub: number;
}
export interface CancelMessage {
  t: "cancel";
  id: number;
}
export interface ReleaseMessage {
  t: "release";
  handle: string;
}
export interface OpenMessage {
  t: "open";
  id: number;
  stream: number;
  op: string;
  params?: unknown;
  cap?: string;
}
export interface CreditMessage {
  t: "credit";
  stream: number;
  bytes: number;
}
export interface EndMessage {
  t: "end";
  stream: number;
  code?: string;
  message?: string;
}

export type Envelope =
  | CallMessage
  | OkMessage
  | ErrMessage
  | SubMessage
  | EvMessage
  | UnsubMessage
  | CancelMessage
  | ReleaseMessage
  | OpenMessage
  | CreditMessage
  | EndMessage;

export class EnvelopeError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "EnvelopeError";
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** u64 on the wire; JS can only represent the safe-integer range exactly, so larger ids are refused. */
function isU64(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

function isU32(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= 0 && value <= MAX_U32;
}

function requireField<T>(obj: Record<string, unknown>, key: string, check: (v: unknown) => v is T, what: string): T {
  const value = obj[key];
  if (!check(value)) throw new EnvelopeError(`${String(obj.t)}.${key} must be ${what}`);
  return value;
}

function optionalField<T>(
  obj: Record<string, unknown>,
  key: string,
  check: (v: unknown) => v is T,
  what: string,
): T | undefined {
  if (!(key in obj) || obj[key] === undefined) return undefined;
  return requireField(obj, key, check, what);
}

const isString = (v: unknown): v is string => typeof v === "string";
const isBoolean = (v: unknown): v is boolean => typeof v === "boolean";

/** Parses and shape-checks one text message. Throws EnvelopeError for anything malformed. */
export function decodeEnvelope(text: string): Envelope {
  if (text.length > MAX_MESSAGE_BYTES) throw new EnvelopeError("message exceeds 16 MiB");
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch {
    throw new EnvelopeError("message is not valid JSON");
  }
  return checkEnvelope(raw);
}

export function checkEnvelope(raw: unknown): Envelope {
  if (!isRecord(raw)) throw new EnvelopeError("message must be a JSON object");
  switch (raw.t) {
    case "call": {
      const msg: CallMessage = {
        t: "call",
        id: requireField(raw, "id", isU64, "a u64"),
        op: requireField(raw, "op", isString, "a string"),
        params: raw.params === undefined ? {} : raw.params,
      };
      const cap = optionalField(raw, "cap", isString, "a string");
      if (cap !== undefined) msg.cap = cap;
      return msg;
    }
    case "ok":
      return {
        t: "ok",
        id: requireField(raw, "id", isU64, "a u64"),
        value: raw.value === undefined ? null : raw.value,
      };
    case "err": {
      const msg: ErrMessage = {
        t: "err",
        id: requireField(raw, "id", isU64, "a u64"),
        code: requireField(raw, "code", isString, "a string"),
        message: requireField(raw, "message", isString, "a string"),
        retryable: requireField(raw, "retryable", isBoolean, "a boolean"),
      };
      const details = optionalField(raw, "details", isRecord, "an object");
      if (details !== undefined) msg.details = details;
      return msg;
    }
    case "sub": {
      const msg: SubMessage = {
        t: "sub",
        id: requireField(raw, "id", isU64, "a u64"),
        stream: requireField(raw, "stream", isString, "a string"),
      };
      const filter = optionalField(raw, "filter", isRecord, "an object");
      if (filter !== undefined) msg.filter = filter;
      const cap = optionalField(raw, "cap", isString, "a string");
      if (cap !== undefined) msg.cap = cap;
      return msg;
    }
    case "ev":
      return {
        t: "ev",
        sub: requireField(raw, "sub", isU64, "a u64"),
        seq: requireField(raw, "seq", isU64, "a u64"),
        data: raw.data === undefined ? null : raw.data,
      };
    case "unsub":
      return { t: "unsub", sub: requireField(raw, "sub", isU64, "a u64") };
    case "cancel":
      return { t: "cancel", id: requireField(raw, "id", isU64, "a u64") };
    case "release":
      return { t: "release", handle: requireField(raw, "handle", isString, "a string") };
    case "open": {
      const msg: OpenMessage = {
        t: "open",
        id: requireField(raw, "id", isU64, "a u64"),
        stream: requireField(raw, "stream", isU32, "a u32"),
        op: requireField(raw, "op", isString, "a string"),
      };
      if (raw.params !== undefined) msg.params = raw.params;
      const cap = optionalField(raw, "cap", isString, "a string");
      if (cap !== undefined) msg.cap = cap;
      return msg;
    }
    case "credit":
      return {
        t: "credit",
        stream: requireField(raw, "stream", isU32, "a u32"),
        bytes: requireField(raw, "bytes", isU32, "a u32"),
      };
    case "end": {
      const msg: EndMessage = { t: "end", stream: requireField(raw, "stream", isU32, "a u32") };
      const code = optionalField(raw, "code", isString, "a string");
      if (code !== undefined) msg.code = code;
      const message = optionalField(raw, "message", isString, "a string");
      if (message !== undefined) msg.message = message;
      return msg;
    }
    default:
      throw new EnvelopeError(`unknown message type ${JSON.stringify(raw.t)}`);
  }
}

export function encodeEnvelope(msg: Envelope): string {
  const text = JSON.stringify(msg);
  if (text.length > MAX_MESSAGE_BYTES) throw new EnvelopeError("message exceeds 16 MiB; use a byte stream");
  return text;
}

export interface BinaryFrame {
  stream: number;
  /** Credit granted to the receiver of this frame for the reverse direction; 0 means none. */
  credit: number;
  payload: Uint8Array;
}

export function encodeBinaryFrame(frame: BinaryFrame): Uint8Array {
  if (!isU32(frame.stream) || !isU32(frame.credit)) throw new EnvelopeError("stream id and credit must be u32");
  if (frame.payload.byteLength + BINARY_HEADER_BYTES > MAX_MESSAGE_BYTES) {
    throw new EnvelopeError("binary frame exceeds 16 MiB");
  }
  const out = new Uint8Array(BINARY_HEADER_BYTES + frame.payload.byteLength);
  const view = new DataView(out.buffer);
  view.setUint32(0, frame.stream, false);
  view.setUint32(4, frame.credit, false);
  out.set(frame.payload, BINARY_HEADER_BYTES);
  return out;
}

export function decodeBinaryFrame(bytes: Uint8Array): BinaryFrame {
  if (bytes.byteLength < BINARY_HEADER_BYTES) throw new EnvelopeError("binary frame shorter than its 8-byte header");
  if (bytes.byteLength > MAX_MESSAGE_BYTES) throw new EnvelopeError("binary frame exceeds 16 MiB");
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  return {
    stream: view.getUint32(0, false),
    credit: view.getUint32(4, false),
    payload: bytes.subarray(BINARY_HEADER_BYTES),
  };
}
