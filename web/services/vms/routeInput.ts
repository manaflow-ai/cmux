import { optionalVmClientIdentifier, parseVmProviderOverrideField, vmOptionalTrimmedString } from "./requestSchemas";
import { type ProviderId } from "./drivers/types";
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

/** Parse an optional JSON object body. An empty body is the same as `{}`. */
export async function parseOptionalObjectBody(
  request: Request,
  options: ObjectBodyOptions,
): Promise<ParsedOptionalObjectBody> {
  const raw = await request.text();
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
  const raw = await request.text();
  if (!raw.trim()) return { ok: true, body: null };

  const parsed = parseJson(raw);
  if (!parsed.ok) return { ok: false, response: invalidJsonResponse(options) };
  if (!isObjectRecord(parsed.value)) {
    return { ok: false, response: expectedObjectResponse(options) };
  }
  return { ok: true, body: parsed.value };
}

/** Parse a best-effort JSON object body used by legacy attach/session endpoints. */
export async function parseLenientObjectBody(request: Request): Promise<Record<string, unknown>> {
  try {
    const body = await request.json();
    return isObjectRecord(body) ? body : {};
  } catch {
    return {};
  }
}

export function stringField(body: Record<string, unknown>, key: string): string | undefined {
  return vmOptionalTrimmedString(body[key]);
}

export function optionalString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed || null;
}

export function optionalClientIdentifier(value: unknown, fieldName: string): string | undefined {
  const parsed = optionalVmClientIdentifier(value, fieldName);
  if (!parsed.ok) throw new Error(parsed.message);
  return parsed.value;
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
  return parseVmProviderOverrideField(body.provider);
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
