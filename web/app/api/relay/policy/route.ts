// Serve the signed, server-driven Iroh relay policy for the caller's account.
// Relay admission is decided by the relay's allow hook (/api/relay/allow), so
// this route carries no credentials: clients prove identity in the iroh
// handshake and only need the signed catalog plus their account preference.
// Auth is native-only because the policy names account-scoped infrastructure.

import { checkRateLimit } from "@vercel/firewall";

import {
  enforceRelayRateLimit,
  jsonResponse,
  relayErrorResponse,
  runRelayEffect,
  type RelayRateLimitCheck,
} from "../../../../services/relay/http";
import {
  productionRelayWorkflowConfig,
  signedRelayPolicy,
  type SignedRelayPolicyResult,
} from "../../../../services/relay/workflows";
import { runRelayRepositoryEffect } from "../../../../services/relay/repository";
import { relayAuthenticationError } from "../../../../services/relay/errors";
import {
  unauthorized,
  verifyRequest,
  type AuthedUser,
} from "../../../../services/vms/auth";

const RELAY_POLICY_RATE_LIMIT_BUCKET_SECONDS = 60;

export interface RelayPolicyDeps {
  readonly verifyRequest: (request: Request) => Promise<AuthedUser | null>;
  readonly nowSeconds: () => number;
  readonly signedPolicy: (
    accountId: string,
    nowSeconds: number,
  ) => Promise<SignedRelayPolicyResult>;
  readonly checkRateLimit: RelayRateLimitCheck;
  readonly rateLimitRuleId: () => string | undefined;
  readonly isVercel: () => boolean;
}

const productionDeps: RelayPolicyDeps = {
  verifyRequest: (request) => verifyRequest(request, { allowCookie: false }),
  nowSeconds: () => Math.floor(Date.now() / 1_000),
  signedPolicy: async (accountId, nowSeconds) => {
    const config = productionRelayWorkflowConfig();
    return await runRelayRepositoryEffect(signedRelayPolicy(accountId, {
      ...config,
      nowSeconds,
    }));
  },
  checkRateLimit,
  // Reuses the account-scoped rule that previously gated token minting.
  rateLimitRuleId: () => process.env.CMUX_RELAY_TOKEN_RATE_LIMIT_ID,
  isVercel: () => process.env.VERCEL === "1",
};

export async function handleRelayPolicyRequest(
  request: Request,
  deps: RelayPolicyDeps,
): Promise<Response> {
  let user: AuthedUser | null;
  try {
    user = await deps.verifyRequest(request);
  } catch (error) {
    return relayErrorResponse(relayAuthenticationError(error));
  }
  if (!user) return unauthorized();

  try {
    const nowSeconds = deps.nowSeconds();
    const retryAfterSeconds = RELAY_POLICY_RATE_LIMIT_BUCKET_SECONDS -
      (nowSeconds % RELAY_POLICY_RATE_LIMIT_BUCKET_SECONDS);
    await runRelayEffect(enforceRelayRateLimit({
      request,
      accountId: user.id,
      ruleId: deps.rateLimitRuleId(),
      check: deps.checkRateLimit,
      isVercel: deps.isVercel(),
      retryAfterSeconds,
    }));
    const policy = await deps.signedPolicy(user.id, nowSeconds);
    return jsonResponse({
      policy: policy.policy,
      preference: policy.preference,
      preferenceRevision: policy.preferenceRevision,
    });
  } catch (error) {
    return relayErrorResponse(error);
  }
}

export function GET(request: Request): Promise<Response> {
  return handleRelayPolicyRequest(request, productionDeps);
}
