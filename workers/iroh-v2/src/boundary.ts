import { z } from "zod";
import { identifier } from "./contracts/common";
import { RequestSchema, SocketSetupSchema, operationForSchema, type SchemaId } from "./contracts/requests";
import { ErrorResponseSchema, ResponseSchema, type ControlResponse } from "./contracts/responses";
import { OperationError, publicError } from "./errors";

export const INPUT_BYTES = 16 * 1024;
export const OUTPUT_BYTES = 64 * 1024;
const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false });

/** The same bounded decoder is used by HTTP and socket adapters. */
export function parseJSON(text: string, maxBytes = INPUT_BYTES): unknown {
  if (encoder.encode(text).byteLength > maxBytes) throw new OperationError("payload_too_large", 413);
  try { return JSON.parse(text); }
  catch { throw new OperationError("invalid_request", 400); }
}

export function decodeJSON(bytes: Uint8Array, maxBytes = INPUT_BYTES): unknown {
  if (bytes.byteLength > maxBytes) throw new OperationError("payload_too_large", 413);
  try { return parseJSON(decoder.decode(bytes), maxBytes); }
  catch (error) {
    if (error instanceof OperationError) throw error;
    throw new OperationError("invalid_request", 400);
  }
}

/** Check bytes while streaming, including requests without Content-Length. */
export async function readBoundedBody(message: Request | Response, maxBytes = INPUT_BYTES): Promise<unknown> {
  const declared = message.headers.get("content-length");
  if (declared !== null && (!/^\d+$/.test(declared) || Number(declared) > maxBytes)) {
    await message.body?.cancel();
    throw new OperationError("payload_too_large", 413);
  }
  if (!message.body) throw new OperationError("invalid_request", 400);
  const reader = message.body.getReader();
  const chunks: Uint8Array[] = [];
  let bytes = 0;
  try {
    for (;;) {
      const result = await reader.read();
      if (result.done) break;
      bytes += result.value.byteLength;
      if (bytes > maxBytes) {
        await reader.cancel();
        throw new OperationError("payload_too_large", 413);
      }
      chunks.push(result.value);
    }
  } finally { reader.releaseLock(); }
  const body = new Uint8Array(bytes);
  let offset = 0;
  for (const chunk of chunks) { body.set(chunk, offset); offset += chunk.byteLength; }
  return decodeJSON(body, maxBytes);
}

export function parseInput<S extends z.ZodType>(schema: S, input: unknown): z.infer<S> {
  const parsed = schema.safeParse(input);
  if (!parsed.success) throw new OperationError("invalid_request", 400);
  return parsed.data;
}

/** Never persist arbitrary method strings as rate-counter keys. */
export function inputOperation(input: unknown): string {
  if (input === null || typeof input !== "object") return "input.rejected";
  const schemaId = Reflect.get(input, "schemaId");
  return typeof schemaId === "string" && Object.hasOwn(operationForSchema, schemaId)
    ? operationForSchema[schemaId as SchemaId] : "input.rejected";
}

export function inputRequestId(input: unknown): string {
  const result = identifier.safeParse(input !== null && typeof input === "object" ? Reflect.get(input, "requestId") : undefined);
  return result.success ? result.data : "unidentified";
}

/** Retire a wire method deliberately, with the client's long-backoff signal. */
export function parseControlRequest(input: unknown, retired: ReadonlySet<string> = new Set()) {
  const schemaId = input !== null && typeof input === "object" ? Reflect.get(input, "schemaId") : undefined;
  if (typeof schemaId !== "string") throw new OperationError("invalid_request", 400);
  if (retired.has(schemaId)) throw new OperationError("client_upgrade_required", 426, true, 3_600_000);
  if (!Object.hasOwn(operationForSchema, schemaId)) throw new OperationError("unsupported_method", 400);
  return parseInput(RequestSchema, input);
}

export function parseSocketSetup(input: unknown) { return parseInput(SocketSetupSchema, input); }

/** Zod checks the server result as well as the client request. */
export function encodeResponse(response: ControlResponse): string {
  const parsed = ResponseSchema.safeParse(response);
  if (!parsed.success) throw new OperationError("internal_error", 500, true);
  const text = JSON.stringify(parsed.data);
  if (encoder.encode(text).byteLength > OUTPUT_BYTES) throw new OperationError("internal_error", 500, true);
  return text;
}

export function errorResponse(error: unknown, requestId: string) {
  const failure = publicError(error);
  const body = ErrorResponseSchema.parse({
    schemaId: "error.v1", requestId, code: failure.code, retryable: failure.retryable,
    ...(failure.retryAfterMs === undefined ? {} : { retryAfterMs: failure.retryAfterMs }),
  });
  return { failure, body };
}

export function httpFailure(error: unknown, requestId = "unidentified"): Response {
  const { failure, body } = errorResponse(error, requestId);
  return new Response(encodeResponse(body), {
    status: failure.status,
    headers: {
      "content-type": "application/json; charset=utf-8", "cache-control": "no-store",
      ...(failure.retryAfterMs === undefined ? {} : { "retry-after": String(Math.ceil(failure.retryAfterMs / 1000)) }),
    },
  });
}
