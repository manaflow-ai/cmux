// Mint a short-lived relay access token for the private cmux iroh relay fleet.
//
// A signed-in cmux endpoint POSTs here and gets a short-TTL EdDSA JWT plus the
// fleet RelayMap in one round-trip; it presents the JWT as the iroh relay auth
// token. The relay verifies it offline against the baked public key. If the
// signing key is not provisioned this returns 503, so it is safe to ship before
// the secret is set. Token-minting logic lives in services/relay/token.ts.
//
// Auth: Stack Bearer + X-Stack-Refresh-Token (same native-client path as
// /api/devices). Any signed-in user may mint a token for their own endpoints.

import { unauthorized, verifyRequest } from "../../../../services/vms/auth";
import { jsonResponse } from "../../../../services/vms/routeHelpers";
import {
  RELAY_TOKEN_TTL_SECONDS,
  isValidEndpointId,
  mintRelayToken,
  relaySigningKey,
  relayUrls,
} from "../../../../services/relay/token";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const MAX_BODY_BYTES = 4 * 1024;

export async function POST(request: Request): Promise<Response> {
  const user = await verifyRequest(request);
  if (!user) return unauthorized();

  const key = relaySigningKey();
  if (!key) {
    // The private signing key is not provisioned in this environment.
    return jsonResponse({ error: "relay_token_not_configured" }, 503);
  }

  const contentLength = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(contentLength) && contentLength > MAX_BODY_BYTES) {
    return jsonResponse({ error: "payload_too_large" }, 413);
  }

  // Optional: bind the token to a specific iroh endpoint id (anti-replay).
  let endpointId: string | undefined;
  const raw = await request.text();
  if (raw.length > MAX_BODY_BYTES) {
    return jsonResponse({ error: "payload_too_large" }, 413);
  }
  if (raw.trim().length > 0) {
    let body: { endpointId?: unknown };
    try {
      body = JSON.parse(raw) as { endpointId?: unknown };
    } catch {
      return jsonResponse({ error: "invalid_json" }, 400);
    }
    if (body.endpointId !== undefined && body.endpointId !== null) {
      if (
        typeof body.endpointId !== "string" ||
        !isValidEndpointId(body.endpointId)
      ) {
        return jsonResponse({ error: "invalid_endpoint_id" }, 400);
      }
      endpointId = body.endpointId;
    }
  }

  const nowSeconds = Math.floor(Date.now() / 1000);
  const { token, expiresAt } = mintRelayToken({
    sub: user.id,
    endpointId,
    key,
    nowSeconds,
  });
  return jsonResponse({
    token,
    expiresAt,
    ttlSeconds: RELAY_TOKEN_TTL_SECONDS,
    relays: relayUrls(),
  });
}
