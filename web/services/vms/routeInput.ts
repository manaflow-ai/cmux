import { isProviderId, type ProviderId } from "./drivers/types";
import { vmErrorResponse } from "./routeHelpers";

export type ParsedOptionalObjectBody =
  | { readonly ok: true; readonly body: Record<string, unknown> }
  | { readonly ok: false; readonly response: Response };

export type ParsedRequiredObjectBody =
  | { readonly ok: true; readonly body: Record<string, unknown> | null }
  | { readonly ok: false; readonly response: Response };

export type ObjectBodyOptions = {
  readonly operation: string;
  readonly action: string;
};

/** Maximum bytes read from any JSON object body before parsing it. */
export const MAX_OBJECT_BODY_BYTES = 64 * 1024;

type BoundedBodyText =
  | { readonly ok: true; readonly text: string }
  | { readonly ok: false };

/**
 * Read a request body with a hard byte bound. Content-Length is only an early
 * rejection hint. The stream is still counted because chunked requests can
 * omit it or lie about it.
 */
export async function readBoundedBodyText(request: Request): Promise<BoundedBodyText> {
  const declaredLength = request.headers.get("content-length")?.trim();
  if (declaredLength && /^\d+$/.test(declaredLength) && Number(declaredLength) > MAX_OBJECT_BODY_BYTES) {
    return { ok: false };
  }
  const body = request.body;
  if (!body) return { ok: true, text: "" };

  const reader = body.getReader();
  const bytes = new Uint8Array(MAX_OBJECT_BODY_BYTES);
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    if (!value || value.byteLength === 0) continue;
    const next = total + value.byteLength;
    if (next > MAX_OBJECT_BODY_BYTES) {
      // A client can close the stream while we reject it. Preserve the
      // deterministic 413 response even when cancellation reports that race.
      try {
        await reader.cancel();
      } catch {
        // The body is already over the hard limit. There is no useful
        // recovery action for a cancellation failure.
      }
      return { ok: false };
    }
    bytes.set(value, total);
    total = next;
  }
  return { ok: true, text: new TextDecoder().decode(bytes.subarray(0, total)) };
}

/** Parse an optional JSON object body. An empty body is the same as `{}`. */
export async function parseOptionalObjectBody(
  request: Request,
  options: ObjectBodyOptions,
): Promise<ParsedOptionalObjectBody> {
  const body = await readBoundedBodyText(request);
  if (!body.ok) return { ok: false, response: oversizedBodyResponse(options) };
  const raw = body.text;
  if (!raw.trim()) return { ok: true, body: {} };

  const parsed = parseJson(raw);
  if (!parsed.ok) return { ok: false, response: invalidJsonResponse(options) };
  if (!isObjectRecord(parsed.value)) {
    return { ok: false, response: expectedObjectResponse(options) };
  }
  return { ok: true, body: parsed.value };
}

/** Parse a required JSON object body. An empty body is returned as `null` for route validation. */
export async function parseRequiredObjectBody(
  request: Request,
  options: ObjectBodyOptions,
): Promise<ParsedRequiredObjectBody> {
  const body = await readBoundedBodyText(request);
  if (!body.ok) return { ok: false, response: oversizedBodyResponse(options) };
  const raw = body.text;
  if (!raw.trim()) return { ok: true, body: null };

  const parsed = parseJson(raw);
  if (!parsed.ok) return { ok: false, response: invalidJsonResponse(options) };
  if (!isObjectRecord(parsed.value)) {
    return { ok: false, response: expectedObjectResponse(options) };
  }
  return { ok: true, body: parsed.value };
}

/** Parse a best-effort JSON object body used by legacy attach/session endpoints. */
export async function parseLenientObjectBody(
  request: Request,
  options: ObjectBodyOptions,
): Promise<ParsedOptionalObjectBody> {
  const body = await readBoundedBodyText(request);
  if (!body.ok) return { ok: false, response: oversizedBodyResponse(options) };
  if (!body.text.trim()) return { ok: true, body: {} };
  try {
    const parsed = JSON.parse(body.text) as unknown;
    return { ok: true, body: isObjectRecord(parsed) ? parsed : {} };
  } catch {
    return { ok: true, body: {} };
  }
}

export function stringField(body: Record<string, unknown>, key: string): string | undefined {
  const value = body[key];
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

export function optionalString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed || null;
}

export function optionalClientIdentifier(value: unknown, fieldName: string): string | undefined {
  const trimmed = optionalString(value);
  if (!trimmed) return undefined;
  if (!/^[A-Za-z0-9._:-]{1,128}$/.test(trimmed)) {
    throw new Error(`${fieldName} must be 1-128 characters of letters, numbers, dot, underscore, colon, or dash`);
  }
  return trimmed;
}

/** Client transport capabilities: short lowercase tokens, bounded, anything else dropped. */
export function capabilityList(value: unknown): string[] | undefined {
  if (!Array.isArray(value)) return undefined;
  const tokens = value
    .filter((entry): entry is string => typeof entry === "string")
    .map((entry) => entry.trim())
    .filter((entry) => /^[a-z0-9-]{1,64}$/.test(entry));
  return tokens.length ? Array.from(new Set(tokens)).slice(0, 16) : undefined;
}

export function idempotencyKeyFromRequest(request: Request): string | undefined {
  const raw = [
    request.headers.get("idempotency-key"),
    request.headers.get("x-cmux-idempotency-key"),
  ].map((value) => value?.trim()).find(Boolean) ?? "";
  return raw ? raw.slice(0, 128) : undefined;
}

export type ProviderFieldResult =
  | { readonly ok: true; readonly provider?: ProviderId }
  | { readonly ok: false; readonly response: Response };

export function providerField(body: Record<string, unknown>): ProviderFieldResult {
  const value = stringField(body, "provider");
  if (!value) return { ok: true };
  if (isProviderId(value)) return { ok: true, provider: value };
  return {
    ok: false,
    response: vmErrorResponse({
      error: "vm_invalid_provider",
      status: 400,
      message: "Unsupported Cloud VM service override.",
      action: "Use the default Cloud VM service, or pass a supported provider.",
      details: { field: "provider" },
    }),
  };
}

function parseJson(raw: string): { readonly ok: true; readonly value: unknown } | { readonly ok: false } {
  try {
    return { ok: true, value: JSON.parse(raw) as unknown };
  } catch {
    return { ok: false };
  }
}

function isObjectRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function invalidJsonResponse(options: ObjectBodyOptions): Response {
  return vmErrorResponse({
    error: "vm_json_parse_failed",
    status: 400,
    message: `Cloud VM ${options.operation} expected valid JSON.`,
    action: options.action,
  });
}

function expectedObjectResponse(options: ObjectBodyOptions): Response {
  return vmErrorResponse({
    error: "vm_expected_object",
    status: 400,
    message: `Cloud VM ${options.operation} expected a JSON object body.`,
    action: options.action,
  });
}

export function oversizedBodyResponse(options: ObjectBodyOptions): Response {
  return vmErrorResponse({
    error: "vm_request_body_too_large",
    status: 413,
    message: `Cloud VM ${options.operation} request body exceeds ${MAX_OBJECT_BODY_BYTES} bytes.`,
    action: options.action,
  });
}
