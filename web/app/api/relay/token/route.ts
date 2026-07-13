// Mint endpoint-bound access credentials and a signed, server-driven Iroh relay policy.
// Auth is native-only because both credentials leave the browser boundary.

import type { KeyObject } from "node:crypto";

import { checkRateLimit } from "@vercel/firewall";

import { readBoundedJsonObject } from "../../../../services/apns/routePolicy";
import {
  enforceRelayRateLimit,
  jsonResponse,
  relayErrorResponse,
  runRelayEffect,
  type RelayRateLimitCheck,
} from "../../../../services/relay/http";
import {
  RELAY_TOKEN_TTL_SECONDS,
  isValidEndpointId,
  mintRelayToken,
  relaySigningKey,
} from "../../../../services/relay/token";
import {
  productionRelayWorkflowConfig,
  signedRelayPolicy,
  type SignedRelayPolicyResult,
} from "../../../../services/relay/workflows";
import { runRelayRepositoryEffect } from "../../../../services/relay/repository";
import {
  unauthorized,
  verifyRequest,
  type AuthedUser,
} from "../../../../services/vms/auth";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const MAX_BODY_BYTES = 4 * 1_024;

export interface RelayTokenDeps {
  readonly verifyRequest: (request: Request) => Promise<AuthedUser | null>;
  readonly signingKey: () => KeyObject | null;
  readonly nowSeconds: () => number;
  readonly signedPolicy: (
    accountId: string,
    nowSeconds: number,
  ) => Promise<SignedRelayPolicyResult>;
  readonly checkRateLimit: RelayRateLimitCheck;
  readonly rateLimitRuleId: () => string | undefined;
  readonly isVercel: () => boolean;
}

const productionDeps: RelayTokenDeps = {
  verifyRequest: (request) => verifyRequest(request, { allowCookie: false }),
  signingKey: relaySigningKey,
  nowSeconds: () => Math.floor(Date.now() / 1_000),
  signedPolicy: async (accountId, nowSeconds) => {
    const config = productionRelayWorkflowConfig();
    return await runRelayRepositoryEffect(signedRelayPolicy(accountId, {
      ...config,
      nowSeconds,
    }));
  },
  checkRateLimit,
  rateLimitRuleId: () => process.env.CMUX_RELAY_TOKEN_RATE_LIMIT_ID,
  isVercel: () => process.env.VERCEL === "1",
};

export async function handleRelayTokenRequest(
  request: Request,
  deps: RelayTokenDeps,
): Promise<Response> {
  const user = await deps.verifyRequest(request);
  if (!user) return unauthorized();

  try {
    await runRelayEffect(enforceRelayRateLimit({
      request,
      accountId: user.id,
      ruleId: deps.rateLimitRuleId(),
      check: deps.checkRateLimit,
      isVercel: deps.isVercel(),
    }));

    const key = deps.signingKey();
    if (!key) return jsonResponse({ error: "relay_token_not_configured" }, 503);

    const body = await readBoundedJsonObject(request, MAX_BODY_BYTES);
    if (!body.ok) {
      return jsonResponse(
        { error: body.error },
        body.error === "request_too_large" ? 413 : 400,
      );
    }
    const rawEndpointId = body.value.endpointId;
    if (typeof rawEndpointId !== "string" || !isValidEndpointId(rawEndpointId)) {
      return jsonResponse({ error: "invalid_endpoint_id" }, 400);
    }

    const nowSeconds = deps.nowSeconds();
    const policy = await deps.signedPolicy(user.id, nowSeconds);
    const token = mintRelayToken({
      sub: user.id,
      endpointId: rawEndpointId,
      key,
      nowSeconds,
    });
    return jsonResponse({
      token: token.token,
      expiresAt: token.expiresAt,
      ttlSeconds: RELAY_TOKEN_TTL_SECONDS,
      // Compatibility for clients predating signed policy support.
      relays: policy.payload.relays.map((relay) => relay.url),
      policy: policy.policy,
      preference: policy.preference,
      preferenceRevision: policy.preferenceRevision,
    });
  } catch (error) {
    return relayErrorResponse(error);
  }
}

export function POST(request: Request): Promise<Response> {
  return handleRelayTokenRequest(request, productionDeps);
}
