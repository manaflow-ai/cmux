// Mint a short-lived relay access token for the private cmux iroh relay fleet.
//
// A signed-in cmux endpoint POSTs here and gets a short-TTL EdDSA JWT plus the
// fleet RelayMap in one round-trip; it presents the JWT as the iroh relay auth
// token. The relay verifies it offline against the baked public key. If the
// signing key is not provisioned this returns 503, so it is safe to ship before
// the secret is set. Token-minting logic lives in services/relay/token.ts.
//
// Auth: native-only (Stack Bearer + X-Stack-Refresh-Token, no browser cookie),
// since the minted token is exported to the native client — same posture as
// /api/devices. The request handler takes its auth/key/clock dependencies as a
// parameter so route behavior is unit-testable without leaking module mocks.

import type { KeyObject } from "node:crypto";

import {
  unauthorized,
  verifyRequest,
  type AuthedUser,
} from "../../../../services/vms/auth";
import { jsonResponse } from "../../../../services/vms/routeHelpers";
import { readBoundedJsonObject } from "../../../../services/apns/routePolicy";
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

export interface RelayTokenDeps {
  verifyRequest: (request: Request) => Promise<AuthedUser | null>;
  signingKey: () => KeyObject | null;
  nowSeconds: () => number;
}

const productionDeps: RelayTokenDeps = {
  verifyRequest: (request) => verifyRequest(request, { allowCookie: false }),
  signingKey: relaySigningKey,
  nowSeconds: () => Math.floor(Date.now() / 1000),
};

export async function handleRelayTokenRequest(
  request: Request,
  deps: RelayTokenDeps,
): Promise<Response> {
  const user = await deps.verifyRequest(request);
  if (!user) return unauthorized();

  const key = deps.signingKey();
  if (!key) {
    // The private signing key is not provisioned in this environment.
    return jsonResponse({ error: "relay_token_not_configured" }, 503);
  }

  // Streams and cancels at MAX_BODY_BYTES, treats an empty body as {}, and
  // rejects non-object JSON (null / arrays / primitives).
  const body = await readBoundedJsonObject(request, MAX_BODY_BYTES);
  if (!body.ok) {
    const status = body.error === "request_too_large" ? 413 : 400;
    return jsonResponse({ error: body.error }, status);
  }

  // Optional: bind the token to a specific iroh endpoint id (anti-replay).
  let endpointId: string | undefined;
  const rawEndpointId = body.value.endpointId;
  if (rawEndpointId !== undefined && rawEndpointId !== null) {
    if (
      typeof rawEndpointId !== "string" ||
      !isValidEndpointId(rawEndpointId)
    ) {
      return jsonResponse({ error: "invalid_endpoint_id" }, 400);
    }
    endpointId = rawEndpointId;
  }

  const { token, expiresAt } = mintRelayToken({
    sub: user.id,
    endpointId,
    key,
    nowSeconds: deps.nowSeconds(),
  });
  return jsonResponse({
    token,
    expiresAt,
    ttlSeconds: RELAY_TOKEN_TTL_SECONDS,
    relays: relayUrls(),
  });
}

export function POST(request: Request): Promise<Response> {
  return handleRelayTokenRequest(request, productionDeps);
}
