import { isProviderId, SecretBytes, type ProviderCredential, type ProviderId } from "./drivers/types";
import { jsonResponse, vmErrorResponse } from "./routeHelpers";
import { SANDBOX_VM_IDEMPOTENCY_PREFIX } from "../runs/model";

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

export const VM_IDEMPOTENCY_KEY_MAX_LENGTH = 128;

export type IdempotencyKeyResult =
  | { readonly ok: true; readonly key: string | undefined }
  | { readonly ok: false; readonly response: Response };

export function idempotencyKeyFromRequest(request: Request): IdempotencyKeyResult {
  const raw = [
    request.headers.get("idempotency-key"),
    request.headers.get("x-cmux-idempotency-key"),
  ].map((value) => value?.trim()).find(Boolean) ?? "";
  if (raw.length > VM_IDEMPOTENCY_KEY_MAX_LENGTH) {
    return {
      ok: false,
      response: jsonResponse({
        error: "vm_idempotency_key_too_long",
        details: {
          field: "idempotencyKey",
          maxLength: VM_IDEMPOTENCY_KEY_MAX_LENGTH,
        },
      }, 400),
    };
  }
  // A sandboxed Run's VM is created under `sandbox-run:…` (services/runs/model.ts); the VM
  // workflows refuse pause, snapshot and fork on that key, and the Run reaper adopts a VM by it,
  // so no request may name a key in that namespace.
  if (raw.startsWith(SANDBOX_VM_IDEMPOTENCY_PREFIX)) {
    return {
      ok: false,
      response: jsonResponse({ error: "vm_idempotency_key_reserved", details: { field: "idempotencyKey" } }, 400),
    };
  }
  return { ok: true, key: raw || undefined };
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

/**
 * Reads the local client's short-lived GCP handoff headers. Headers are
 * intentionally separate from VM JSON so request-body logging cannot retain a
 * service credential. The workflow it is handed to wipes it when it ends.
 */
export function gcpCredentialFromRequest(request: Request, provider: ProviderId = "gcp"): ProviderCredential | undefined {
  if (provider !== "gcp") return undefined;
  const token = request.headers.get("x-cmux-gcp-access-token")?.trim();
  if (!token) return undefined;
  if (token.length > 16_384) return undefined;
  const expiryHeader = request.headers.get("x-cmux-gcp-access-token-expires-at");
  const expiresAt = expiryHeader ? Number(expiryHeader) : Number.NaN;
  const ssh = gcpSshFromRequest(request);
  if (!ssh) return undefined;
  const { sshPrivateKeyPem, sshPublicKey, sshUsername } = ssh;
  return {
    provider: "gcp",
    accessToken: new SecretBytes(new TextEncoder().encode(token)),
    expiresAtUnix: Number.isFinite(expiresAt) ? expiresAt : Math.floor(Date.now() / 1000) + 300,
    lifetime: new AbortController(),
    ...(sshPublicKey ? { sshPublicKey } : {}),
    ...(sshPrivateKeyPem ? { sshPrivateKeyPem } : {}),
    ...(sshUsername ? { sshUsername } : {}),
  };
}

/**
 * The optional SSH key pair and login name; null when any of them is malformed.
 * A key file has newlines, which a header cannot carry, so
 * `x-cmux-gcp-ssh-private-key` is the key file in standard base64.
 */
function gcpSshFromRequest(request: Request) {
  const encodedPrivateKey = request.headers.get("x-cmux-gcp-ssh-private-key")?.trim() || undefined;
  const sshPublicKey = request.headers.get("x-cmux-gcp-ssh-public-key")?.trim() || undefined;
  const sshUsername = request.headers.get("x-cmux-gcp-ssh-username")?.trim() || undefined;
  if (sshPublicKey && (sshPublicKey.length > 16_384 || /[\r\n]/.test(sshPublicKey))) return null;
  if (sshUsername && (sshUsername.length > 128 || !/^[A-Za-z_][A-Za-z0-9_.-]*$/.test(sshUsername))) return null;
  if (!encodedPrivateKey) return { sshPrivateKeyPem: undefined, sshPublicKey, sshUsername };
  const sshPrivateKeyPem = privateKeyFromHeader(encodedPrivateKey);
  return sshPrivateKeyPem ? { sshPrivateKeyPem, sshPublicKey, sshUsername } : null;
}

const SSH_PRIVATE_KEY_MAX_BYTES = 32_768;

/**
 * Decodes a base64 key file into one unpooled allocation the SecretBytes owns,
 * so its wipe clears the only decoded copy; null unless it is a PEM or
 * OpenSSH private key no larger than 32 KiB.
 */
function privateKeyFromHeader(encoded: string): SecretBytes | null {
  if (encoded.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(encoded)) return null;
  const decodedLength = (encoded.length / 4) * 3 - (encoded.match(/=+$/)?.[0].length ?? 0);
  if (decodedLength > SSH_PRIVATE_KEY_MAX_BYTES) return null;
  const bytes = Buffer.alloc(decodedLength);
  const written = bytes.write(encoded, "base64");
  const head = bytes.subarray(0, 64).toString("latin1");
  if (written !== decodedLength || !/^-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----\r?\n/.test(head)) {
    bytes.fill(0);
    return null;
  }
  return new SecretBytes(bytes);
}

export { wipeProviderCredential } from "./drivers/types";

/** Non-secret GCP placement knobs handed off by the local Labs UI. */
export function gcpProviderMetadataFromRequest(request: Request, provider: ProviderId = "gcp"): Record<string, unknown> | undefined {
  if (provider !== "gcp") return undefined;
  const fields: Array<[string, string]> = [
    ["project", "x-cmux-gcp-project"],
    ["zone", "x-cmux-gcp-zone"],
    ["machineType", "x-cmux-gcp-machine-type"],
    ["network", "x-cmux-gcp-network"],
    ["sshUsername", "x-cmux-gcp-ssh-username"],
  ];
  const metadata: Record<string, unknown> = {};
  for (const [key, header] of fields) {
    const value = request.headers.get(header)?.trim();
    if (value && value.length <= 256 && !/[\r\n]/.test(value)) metadata[key] = value;
  }
  const idle = Number(request.headers.get("x-cmux-gcp-idle-stop-minutes"));
  if (Number.isSafeInteger(idle) && idle >= 5 && idle <= 1_440) metadata.idleStopMinutes = idle;
  return Object.keys(metadata).length > 0 ? metadata : undefined;
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
