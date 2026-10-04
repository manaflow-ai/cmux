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

/**
 * The 16 MiB limit is in UTF-8 wire bytes; one UTF-16 unit can be up to 3 bytes, so `length`
 * alone undercounts. Strings that cannot exceed the limit even at 3 bytes per unit skip the scan.
 */
export function exceedsMessageLimit(text: string): boolean {
  if (text.length * 3 <= MAX_MESSAGE_BYTES) return false;
  if (text.length > MAX_MESSAGE_BYTES) return true;
  return utf8ByteLength(text) > MAX_MESSAGE_BYTES;
}

/** Exact UTF-8 size of a JS string, without encoding it. */
export function utf8ByteLength(text: string): number {
  return exactUtf8Length(text);
}

function exactUtf8Length(text: string): number {
  let bytes = 0;
  for (let i = 0; i < text.length; i += 1) {
    const unit = text.charCodeAt(i);
    if (unit < 0x80) bytes += 1;
    else if (unit < 0x800) bytes += 2;
    else if (unit >= 0xd800 && unit <= 0xdbff && i + 1 < text.length) {
      const next = text.charCodeAt(i + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        bytes += 4;
        i += 1;
      } else bytes += 3;
    } else bytes += 3; // BMP and lone surrogates (encoded as U+FFFD, 3 bytes).
  }
  return bytes;
}

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
  /** True on the first event after the provider dropped events from a full queue. */
  gap?: true;
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

/** Request, subscription and seq ids are 1..2^53-1 (decision 12): exact in JSON in every language. */
function isId(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 1;
}

/** `ok`/`err` may also carry id 0, which is reserved for the auth reply (decision 5). */
function isResultId(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

/** Stream ids are 1..2^32-1: they must also fit the u32 in a binary frame header. */
function isStreamId(value: unknown): value is number {
  return isU32(value) && value >= 1;
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
  if (exceedsMessageLimit(text)) throw new EnvelopeError("message exceeds 16 MiB");
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
        id: requireField(raw, "id", isId, "an id in 1..2^53-1"),
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
        id: requireField(raw, "id", isResultId, "an id in 0..2^53-1"),
        value: raw.value === undefined ? null : raw.value,
      };
    case "err": {
      const msg: ErrMessage = {
        t: "err",
        id: requireField(raw, "id", isResultId, "an id in 0..2^53-1"),
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
        id: requireField(raw, "id", isId, "an id in 1..2^53-1"),
        stream: requireField(raw, "stream", isString, "a string"),
      };
      const filter = optionalField(raw, "filter", isRecord, "an object");
      if (filter !== undefined) msg.filter = filter;
      const cap = optionalField(raw, "cap", isString, "a string");
      if (cap !== undefined) msg.cap = cap;
      return msg;
    }
    case "ev": {
      const msg: EvMessage = {
        t: "ev",
        sub: requireField(raw, "sub", isId, "an id in 1..2^53-1"),
        seq: requireField(raw, "seq", isId, "an id in 1..2^53-1"),
        data: raw.data === undefined ? null : raw.data,
      };
      // Decision 15: the provider dropped events before this one. Omitted when false.
      if (optionalField(raw, "gap", isBoolean, "a boolean")) msg.gap = true;
      return msg;
    }
    case "unsub":
      return { t: "unsub", sub: requireField(raw, "sub", isId, "an id in 1..2^53-1") };
    case "cancel":
      return { t: "cancel", id: requireField(raw, "id", isId, "an id in 1..2^53-1") };
    case "release":
      return { t: "release", handle: requireField(raw, "handle", isString, "a string") };
    case "open": {
      const msg: OpenMessage = {
        t: "open",
        id: requireField(raw, "id", isId, "an id in 1..2^53-1"),
        stream: requireField(raw, "stream", isStreamId, "a stream id in 1..2^32-1"),
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
        stream: requireField(raw, "stream", isStreamId, "a stream id in 1..2^32-1"),
        bytes: requireField(raw, "bytes", isU32, "a u32"),
      };
    case "end": {
      const msg: EndMessage = { t: "end", stream: requireField(raw, "stream", isStreamId, "a stream id in 1..2^32-1") };
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
  if (exceedsMessageLimit(text)) throw new EnvelopeError("message exceeds 16 MiB; use a byte stream");
  return text;
}

export interface BinaryFrame {
  stream: number;
  /** Credit granted to the receiver of this frame for the reverse direction; 0 means none. */
  credit: number;
  payload: Uint8Array;
}

export function encodeBinaryFrame(frame: BinaryFrame): Uint8Array {
  if (!isStreamId(frame.stream) || !isU32(frame.credit)) {
    throw new EnvelopeError("stream id must be in 1..2^32-1 and credit a u32");
  }
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
  const stream = view.getUint32(0, false);
  if (stream === 0) throw new EnvelopeError("binary frame for stream 0");
  return {
    stream,
    credit: view.getUint32(4, false),
    payload: bytes.subarray(BINARY_HEADER_BYTES),
  };
}
