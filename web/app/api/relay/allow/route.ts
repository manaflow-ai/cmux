// Per-connection access-control hook for the self-hosted relay fleet.
// iroh-relay 1.0.3 HTTP access mode: the relay POSTs for each connecting
// endpoint and grants access only on HTTP 200 with response text exactly
// `true`; every other status or body is a deny. JSON `true`/`false` IS that
// exact text, so the body stays JSON without breaking the contract.
//
// Auth is a shared-secret HMAC (CMUX_RELAY_ALLOW_HMAC_SECRET_B64): base64url
// HMAC-SHA256 over the raw request body. Upstream iroh-relay sends an empty
// body and can only attach a static bearer token, so the fleet is configured
// with `bearer_token = relayAllowSignature(secret, empty)`; a relay-side
// caller that sends the JSON body form signs that body instead. Unset secret
// means 503: admissions of NEW endpoints fail closed, the relay side carries
// availability through its allow cache.

import { env } from "../../../env";
import { jsonResponse } from "../../../../services/relay/http";
import {
  RELAY_ALLOW_SIGNATURE_HEADER,
  parseRelayAllowSecret,
  relayAllowAdmission,
  verifyRelayAllowSignature,
  type RelayAllowAdmission,
} from "../../../../services/relay/allow";

const MAX_BODY_BYTES = 4 * 1_024;
// Suggested relay-side cache TTLs, surfaced as standard cache hints. Allow
// decisions are safe to reuse for an hour; denials stay short so a fresh
// registration or an un-wedged account is admitted quickly.
const ALLOW_CACHE_SECONDS = 3_600;
const DENY_CACHE_SECONDS = 60;
// iroh-relay 1.0.3 sends the hex EndpointId in this header (constant
// X_IROH_ENDPOINT_ID = "X-Iroh-NodeId" in its src/main.rs).
const ENDPOINT_ID_HEADER = "x-iroh-nodeid";
const ENDPOINT_ID_RE = /^[0-9a-f]{64}$/;

export interface RelayAllowDeps {
  readonly secretBase64: () => string | undefined;
  readonly admission: (endpointId: string) => Promise<RelayAllowAdmission>;
}

const productionDeps: RelayAllowDeps = {
  secretBase64: () => env.CMUX_RELAY_ALLOW_HMAC_SECRET_B64,
  admission: relayAllowAdmission,
};

export async function handleRelayAllowRequest(
  request: Request,
  deps: RelayAllowDeps,
): Promise<Response> {
  const secret = parseRelayAllowSecret(deps.secretBase64());
  if (!secret) return jsonResponse({ error: "relay_allow_not_configured" }, 503);

  const body = await readBoundedBody(request);
  if (!body.ok) return body.response;

  const provided = providedSignature(request);
  if (!provided || !verifyRelayAllowSignature(secret, body.bytes, provided)) {
    return jsonResponse({ error: "invalid_relay_allow_signature" }, 401);
  }

  const endpointId = extractEndpointId(request, body.bytes);
  if (endpointId instanceof Response) return endpointId;

  try {
    return admissionResponse(await deps.admission(endpointId));
  } catch {
    // Never log EndpointIDs; the route and failure class are enough.
    console.error("relay allow admission failed", { failure: "unexpected" });
    return jsonResponse({ error: "relay_allow_unavailable" }, 503);
  }
}

function providedSignature(request: Request): string | null {
  const header = request.headers.get(RELAY_ALLOW_SIGNATURE_HEADER)?.trim();
  if (header) return header;
  const authorization = request.headers.get("authorization")?.trim();
  if (!authorization || !/^bearer /i.test(authorization)) return null;
  return authorization.slice("bearer ".length).trim() || null;
}

function extractEndpointId(
  request: Request,
  bodyBytes: Uint8Array,
): string | Response {
  const header = request.headers.get(ENDPOINT_ID_HEADER)?.trim().toLowerCase();
  if (header) {
    return ENDPOINT_ID_RE.test(header)
      ? header
      : jsonResponse({ error: "invalid_endpoint_id" }, 400);
  }
  if (bodyBytes.byteLength === 0) {
    return jsonResponse({ error: "missing_endpoint_id" }, 400);
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(Buffer.from(bodyBytes).toString("utf8"));
  } catch {
    return jsonResponse({ error: "invalid_json" }, 400);
  }
  const candidate = parsed && typeof parsed === "object" && !Array.isArray(parsed)
    ? (parsed as Record<string, unknown>).endpointId
    : undefined;
  if (typeof candidate !== "string") {
    return jsonResponse({ error: "missing_endpoint_id" }, 400);
  }
  const endpointId = candidate.trim().toLowerCase();
  return ENDPOINT_ID_RE.test(endpointId)
    ? endpointId
    : jsonResponse({ error: "invalid_endpoint_id" }, 400);
}

function admissionResponse(admission: RelayAllowAdmission): Response {
  const allow = admission === "allow";
  // The body MUST be exactly `true` to grant; JSON true serializes to that
  // exact text. Cache hints let the relay honor server-suggested TTLs.
  return new Response(allow ? "true" : "false", {
    status: 200,
    headers: {
      "content-type": "application/json",
      "cache-control": `max-age=${allow ? ALLOW_CACHE_SECONDS : DENY_CACHE_SECONDS}`,
    },
  });
}

async function readBoundedBody(request: Request): Promise<
  | { readonly ok: true; readonly bytes: Uint8Array }
  | { readonly ok: false; readonly response: Response }
> {
  const contentLength = request.headers.get("content-length");
  if (contentLength) {
    const parsed = Number(contentLength);
    if (!Number.isSafeInteger(parsed) || parsed < 0 || parsed > MAX_BODY_BYTES) {
      return { ok: false, response: jsonResponse({ error: "request_too_large" }, 413) };
    }
  }
  const reader = request.body?.getReader();
  // iroh-relay's access-mode POST carries no body at all.
  if (!reader) return { ok: true, bytes: new Uint8Array() };
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const next = await reader.read();
      if (next.done) break;
      total += next.value.byteLength;
      if (total > MAX_BODY_BYTES) {
        await reader.cancel();
        return { ok: false, response: jsonResponse({ error: "request_too_large" }, 413) };
      }
      chunks.push(next.value);
    }
  } catch {
    return { ok: false, response: jsonResponse({ error: "invalid_body" }, 400) };
  }
  return {
    ok: true,
    bytes: Buffer.concat(chunks.map((chunk) => Buffer.from(chunk)), total),
  };
}

export function POST(request: Request): Promise<Response> {
  return handleRelayAllowRequest(request, productionDeps);
}
