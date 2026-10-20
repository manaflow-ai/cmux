// Anthropic Messages API <-> Amazon Bedrock adapter.
//
// Bedrock's InvokeModel accepts the Anthropic Messages body almost verbatim:
// `model` and `stream` move to the URL, `anthropic_version` is pinned. The
// streaming response is AWS event-stream framing whose `chunk` payloads carry
// base64 JSON of ordinary Anthropic SSE events; this file turns that back into
// `event:`/`data:` lines so the guest's Anthropic SDK sees a plain stream.

export const BEDROCK_ANTHROPIC_VERSION = "bedrock-2023-05-31";

/**
 * Anthropic model id -> Bedrock model id. Keys are the ids Claude Code sends
 * (undated aliases); dated ids and `-latest` aliases fold onto the same key.
 * Teams may override or extend this map in their upstream config.
 */
export const BEDROCK_MODEL_IDS: Readonly<Record<string, string>> = {
  "claude-opus-4-1": "anthropic.claude-opus-4-1-20250805-v1:0",
  "claude-opus-4": "anthropic.claude-opus-4-20250514-v1:0",
  "claude-sonnet-4-5": "anthropic.claude-sonnet-4-5-20250929-v1:0",
  "claude-sonnet-4": "anthropic.claude-sonnet-4-20250514-v1:0",
  "claude-haiku-4-5": "anthropic.claude-haiku-4-5-20251001-v1:0",
  "claude-3-5-haiku": "anthropic.claude-3-5-haiku-20241022-v1:0",
};

const CROSS_REGION_PREFIX = /^(global|us|eu|apac|jp|au|ca)\./;
const BEDROCK_ID = /^(?:(?:global|us|eu|apac|jp|au|ca)\.)?anthropic\.claude-/;

/**
 * Resolves the id Bedrock should be invoked with. A caller-supplied
 * `global.` (or other inference-profile) prefix on an Anthropic id is kept
 * and applied to the mapped Bedrock id. Ids that already look like Bedrock
 * ids pass through. Returns null for models this adapter does not know.
 */
export function bedrockModelId(
  requested: string,
  overrides: Readonly<Record<string, string>> = {},
): string | null {
  const model = requested.trim();
  if (!model) return null;
  if (BEDROCK_ID.test(model)) return model;
  const prefixMatch = CROSS_REGION_PREFIX.exec(model);
  const prefix = prefixMatch ? `${prefixMatch[1]}.` : "";
  const bare = prefix ? model.slice(prefix.length) : model;
  for (const candidate of aliasCandidates(bare)) {
    const mapped = overrides[candidate] ?? BEDROCK_MODEL_IDS[candidate];
    if (!mapped) continue;
    if (!prefix || CROSS_REGION_PREFIX.test(mapped)) return mapped;
    return `${prefix}${mapped}`;
  }
  return null;
}

function aliasCandidates(model: string): string[] {
  const candidates = [model];
  const undated = model.replace(/-\d{8}$/, "");
  if (undated !== model) candidates.push(undated);
  const unlatest = model.replace(/-latest$/, "");
  if (unlatest !== model) candidates.push(unlatest);
  return candidates;
}

export type BedrockInvokeBody = {
  readonly model: string | null;
  readonly stream: boolean;
  readonly body: Record<string, unknown>;
};

/**
 * Request fields the Bedrock Anthropic Messages API rejects with
 * `400 <field>: Extra inputs are not permitted` even though api.anthropic.com
 * accepts them. Claude Code 2.1 always sends `context_management` (the
 * `context-management-2025-06-27` beta's clear_thinking edit); it is a
 * client-side context optimization, so the request stays valid without it.
 * Everything else Claude Code sends (`metadata`, `thinking.display`, tools,
 * cache_control) is accepted by Bedrock, verified live 2026-09-02.
 */
const BEDROCK_REJECTED_TOP_LEVEL_FIELDS = ["context_management"] as const;

/** Removes `model` and `stream`, drops fields Bedrock rejects, pins `anthropic_version`. */
export function bedrockInvokeBody(value: Record<string, unknown>): BedrockInvokeBody {
  const { model, stream, ...rest } = value;
  for (const field of BEDROCK_REJECTED_TOP_LEVEL_FIELDS) {
    delete rest[field];
  }
  return {
    model: typeof model === "string" ? model : null,
    stream: stream === true,
    body: { ...rest, anthropic_version: BEDROCK_ANTHROPIC_VERSION },
  };
}

export function bedrockRuntimeUrl(region: string, modelId: string, operation: string): URL {
  return new URL(
    `https://bedrock-runtime.${region}.amazonaws.com/model/${encodeURIComponent(modelId)}/${operation}`,
  );
}

/** Anthropic-shaped `/v1/models` listing for the static table plus overrides. */
export function bedrockModelCatalog(
  overrides: Readonly<Record<string, string>> = {},
): { readonly data: readonly { type: "model"; id: string; display_name: string; created_at: string }[]; readonly has_more: false; readonly first_id: string | null; readonly last_id: string | null } {
  const ids = [...new Set([...Object.keys(BEDROCK_MODEL_IDS), ...Object.keys(overrides)])];
  const data = ids.map((id) => ({
    type: "model" as const,
    id,
    display_name: id,
    created_at: "1970-01-01T00:00:00Z",
  }));
  return {
    data,
    has_more: false,
    first_id: data[0]?.id ?? null,
    last_id: data[data.length - 1]?.id ?? null,
  };
}

// AWS event-stream binary framing.
//
// message  = prelude (total length u32, headers length u32, prelude CRC u32)
//            headers payload message-CRC u32
// header   = name length u8, name, value type u8, value
// CRCs are not verified: the transport is TLS and a corrupt frame surfaces as
// a JSON parse failure a few bytes later.

export type AwsEventStreamMessage = {
  readonly headers: Readonly<Record<string, string | number | boolean | Uint8Array>>;
  readonly payload: Uint8Array;
};

const PRELUDE_BYTES = 12;
const MESSAGE_CRC_BYTES = 4;

export function decodeAwsEventStream(): TransformStream<Uint8Array, AwsEventStreamMessage> {
  let buffered: Uint8Array = new Uint8Array(0);
  return new TransformStream<Uint8Array, AwsEventStreamMessage>({
    transform(chunk, controller) {
      buffered = concat(buffered, chunk);
      for (;;) {
        if (buffered.byteLength < PRELUDE_BYTES) return;
        const view = new DataView(buffered.buffer, buffered.byteOffset, buffered.byteLength);
        const totalLength = view.getUint32(0);
        const headersLength = view.getUint32(4);
        if (totalLength < PRELUDE_BYTES + MESSAGE_CRC_BYTES || headersLength > totalLength) {
          controller.error(new Error("invalid event-stream frame"));
          return;
        }
        if (buffered.byteLength < totalLength) return;
        const headersEnd = PRELUDE_BYTES + headersLength;
        const payloadEnd = totalLength - MESSAGE_CRC_BYTES;
        controller.enqueue({
          headers: parseHeaders(buffered.subarray(PRELUDE_BYTES, headersEnd)),
          payload: buffered.slice(headersEnd, payloadEnd),
        });
        buffered = buffered.slice(totalLength);
      }
    },
    flush(controller) {
      if (buffered.byteLength > 0) {
        controller.error(new Error("truncated event-stream frame"));
      }
    },
  });
}

function parseHeaders(bytes: Uint8Array): Record<string, string | number | boolean | Uint8Array> {
  const headers: Record<string, string | number | boolean | Uint8Array> = {};
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const decoder = new TextDecoder();
  let offset = 0;
  while (offset < bytes.byteLength) {
    const nameLength = view.getUint8(offset);
    offset += 1;
    const name = decoder.decode(bytes.subarray(offset, offset + nameLength));
    offset += nameLength;
    const type = view.getUint8(offset);
    offset += 1;
    switch (type) {
      case 0:
        headers[name] = true;
        break;
      case 1:
        headers[name] = false;
        break;
      case 2:
        headers[name] = view.getInt8(offset);
        offset += 1;
        break;
      case 3:
        headers[name] = view.getInt16(offset);
        offset += 2;
        break;
      case 4:
        headers[name] = view.getInt32(offset);
        offset += 4;
        break;
      case 5:
      case 8:
        headers[name] = Number(view.getBigInt64(offset));
        offset += 8;
        break;
      case 6: {
        const length = view.getUint16(offset);
        offset += 2;
        headers[name] = bytes.slice(offset, offset + length);
        offset += length;
        break;
      }
      case 7: {
        const length = view.getUint16(offset);
        offset += 2;
        headers[name] = decoder.decode(bytes.subarray(offset, offset + length));
        offset += length;
        break;
      }
      case 9:
        headers[name] = bytes.slice(offset, offset + 16);
        offset += 16;
        break;
      default:
        throw new Error("invalid event-stream header type");
    }
  }
  return headers;
}

function concat(left: Uint8Array, right: Uint8Array): Uint8Array {
  if (left.byteLength === 0) return right;
  const joined = new Uint8Array(left.byteLength + right.byteLength);
  joined.set(left, 0);
  joined.set(right, left.byteLength);
  return joined;
}

/** Test helper: builds one event-stream frame (CRC fields are zero). */
export function encodeAwsEventStreamMessage(
  headers: Readonly<Record<string, string>>,
  payload: Uint8Array,
): Uint8Array {
  const encoder = new TextEncoder();
  const headerParts: Uint8Array[] = [];
  for (const [name, value] of Object.entries(headers)) {
    const nameBytes = encoder.encode(name);
    const valueBytes = encoder.encode(value);
    const part = new Uint8Array(1 + nameBytes.byteLength + 1 + 2 + valueBytes.byteLength);
    let offset = 0;
    part[offset++] = nameBytes.byteLength;
    part.set(nameBytes, offset);
    offset += nameBytes.byteLength;
    part[offset++] = 7;
    part[offset++] = valueBytes.byteLength >> 8;
    part[offset++] = valueBytes.byteLength & 0xff;
    part.set(valueBytes, offset);
    headerParts.push(part);
  }
  const headersLength = headerParts.reduce((sum, part) => sum + part.byteLength, 0);
  const totalLength = PRELUDE_BYTES + headersLength + payload.byteLength + MESSAGE_CRC_BYTES;
  const frame = new Uint8Array(totalLength);
  const view = new DataView(frame.buffer);
  view.setUint32(0, totalLength);
  view.setUint32(4, headersLength);
  let offset = PRELUDE_BYTES;
  for (const part of headerParts) {
    frame.set(part, offset);
    offset += part.byteLength;
  }
  frame.set(payload, offset);
  return frame;
}

/**
 * Turns a Bedrock InvokeModelWithResponseStream body into Anthropic SSE.
 * `message_start` is rewritten to the model id the caller asked for, and
 * Bedrock's `amazon-bedrock-invocationMetrics` is dropped from `message_stop`.
 */
export function bedrockEventStreamToSse(
  body: ReadableStream<Uint8Array>,
  requestedModel: string,
): ReadableStream<Uint8Array> {
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();
  return body.pipeThrough(decodeAwsEventStream()).pipeThrough(
    new TransformStream<AwsEventStreamMessage, Uint8Array>({
      transform(message, controller) {
        const messageType = message.headers[":message-type"];
        if (messageType === "event") {
          const eventType = message.headers[":event-type"];
          if (eventType !== "chunk") return;
          const event = anthropicEventFromChunk(decoder.decode(message.payload), requestedModel);
          if (event) controller.enqueue(encoder.encode(sseLine(event.type, event.json)));
          return;
        }
        const exceptionType = String(
          message.headers[":exception-type"] ?? message.headers[":error-code"] ?? "unknown",
        );
        const detail = errorMessage(decoder.decode(message.payload));
        controller.enqueue(encoder.encode(sseLine("error", JSON.stringify({
          type: "error",
          error: {
            type: anthropicErrorType(exceptionType),
            message: detail ?? exceptionType,
          },
        }))));
      },
    }),
  );
}

function anthropicEventFromChunk(
  payload: string,
  requestedModel: string,
): { type: string; json: string } | null {
  let envelope: unknown;
  try {
    envelope = JSON.parse(payload);
  } catch {
    return null;
  }
  if (!isRecord(envelope) || typeof envelope.bytes !== "string") return null;
  let decoded: unknown;
  try {
    decoded = JSON.parse(Buffer.from(envelope.bytes, "base64").toString("utf8"));
  } catch {
    return null;
  }
  if (!isRecord(decoded) || typeof decoded.type !== "string") return null;
  const type = decoded.type;
  let event: Record<string, unknown> = decoded;
  if (type === "message_start" && isRecord(event.message)) {
    event = { ...event, message: { ...event.message, model: requestedModel } };
  }
  if (type === "message_stop" && "amazon-bedrock-invocationMetrics" in event) {
    event = { ...event };
    delete event["amazon-bedrock-invocationMetrics"];
  }
  return { type, json: JSON.stringify(event) };
}

function sseLine(type: string, json: string): string {
  return `event: ${type}\ndata: ${json}\n\n`;
}

/**
 * Maps a Bedrock error status and body to the Anthropic error envelope.
 */
export function anthropicErrorFromBedrock(status: number, bodyText: string, errorType?: string | null): {
  readonly status: number;
  readonly body: { type: "error"; error: { type: string; message: string } };
} {
  const message = errorMessage(bodyText) ?? "Bedrock request failed";
  const type = errorType ? anthropicErrorType(errorType) : anthropicErrorTypeForStatus(status);
  return { status, body: { type: "error", error: { type, message } } };
}

function anthropicErrorType(exceptionType: string): string {
  const name = exceptionType.replace(/^.*#/, "");
  switch (name) {
    case "ValidationException":
      return "invalid_request_error";
    case "AccessDeniedException":
    case "UnrecognizedClientException":
    case "InvalidSignatureException":
      return "authentication_error";
    case "ResourceNotFoundException":
      return "not_found_error";
    case "ThrottlingException":
      return "rate_limit_error";
    case "ServiceUnavailableException":
    case "ModelNotReadyException":
      return "overloaded_error";
    default:
      return "api_error";
  }
}

function anthropicErrorTypeForStatus(status: number): string {
  if (status === 400) return "invalid_request_error";
  if (status === 401 || status === 403) return "authentication_error";
  if (status === 404) return "not_found_error";
  if (status === 429) return "rate_limit_error";
  if (status === 503) return "overloaded_error";
  return "api_error";
}

function errorMessage(bodyText: string): string | null {
  try {
    const value: unknown = JSON.parse(bodyText);
    if (isRecord(value) && typeof value.message === "string") return value.message.slice(0, 2_000);
    if (isRecord(value) && typeof value.Message === "string") return value.Message.slice(0, 2_000);
  } catch {
    // Non-JSON error bodies are not surfaced to the guest.
  }
  return null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
