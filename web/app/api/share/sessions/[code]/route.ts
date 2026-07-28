import type { KeyObject } from "node:crypto";

import { checkRateLimit } from "@vercel/firewall";

import {
  enforceShareRateLimit,
  jsonResponse,
  requireShareSigningKey,
  runShareEffect,
  shareErrorResponse,
  type ShareRateLimitCheck,
} from "../../../../../services/share/http";
import {
  revokeShareSession,
  type ShareSessionRelayError,
} from "../../../../../services/share/session";
import {
  isValidShareCode,
  mintShareToken,
  shareSigningKey,
} from "../../../../../services/share/token";
import {
  verifyRequest,
  type AuthedUser,
} from "../../../../../services/vms/auth";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const SHARE_SESSION_END_RETRY_AFTER_SECONDS = 60;

export interface ShareSessionEndDeps {
  readonly verifyNativeRequest: (
    request: Request,
  ) => Promise<AuthedUser | null>;
  readonly signingKey: () => KeyObject | null;
  readonly nowSeconds: () => number;
  readonly revokeSession: (input: {
    readonly code: string;
    readonly token: string;
  }) => Promise<void>;
  readonly checkRateLimit: ShareRateLimitCheck;
  readonly rateLimitRuleId: () => string | undefined;
  readonly isVercel: () => boolean;
}

const productionDeps: ShareSessionEndDeps = {
  verifyNativeRequest: (request) =>
    verifyRequest(request, { allowCookie: false }),
  signingKey: shareSigningKey,
  nowSeconds: () => Math.floor(Date.now() / 1_000),
  revokeSession: revokeShareSession,
  checkRateLimit,
  rateLimitRuleId: () => process.env.CMUX_SHARE_TOKEN_RATE_LIMIT_ID,
  isVercel: () => process.env.VERCEL === "1",
};

export async function handleShareSessionEnd(
  request: Request,
  code: string,
  deps: ShareSessionEndDeps,
): Promise<Response> {
  if (!isValidShareCode(code)) {
    return jsonResponse({ error: "invalid_code" }, 400);
  }
  try {
    const user = await deps.verifyNativeRequest(request);
    if (!user) {
      return jsonResponse({ error: "unauthorized" }, 401);
    }
    const key = await runShareEffect(
      requireShareSigningKey(deps.signingKey()),
    );
    const rateLimitRuleId = deps.rateLimitRuleId();
    const isVercel = deps.isVercel();
    await runShareEffect(enforceShareRateLimit({
      request,
      ruleId: rateLimitRuleId,
      check: deps.checkRateLimit,
      isVercel,
      retryAfterSeconds: SHARE_SESSION_END_RETRY_AFTER_SECONDS,
    }));
    await runShareEffect(enforceShareRateLimit({
      request,
      rateLimitKey: `${user.id}:${code}`,
      ruleId: rateLimitRuleId,
      check: deps.checkRateLimit,
      isVercel,
      retryAfterSeconds: SHARE_SESSION_END_RETRY_AFTER_SECONDS,
    }));
    const { token } = mintShareToken({
      sub: user.id,
      email: user.primaryEmail ?? "",
      code,
      host: true,
      key,
      nowSeconds: deps.nowSeconds(),
    });
    try {
      await deps.revokeSession({ code, token });
    } catch (error) {
      if (
        (error as ShareSessionRelayError | null)?._tag ===
          "ShareSessionRelayError" &&
        (error as ShareSessionRelayError).code ===
          "share_session_not_found"
      ) {
        // Revocation is idempotent. An absent or expired Durable Object
        // session already satisfies the requested terminal state.
        return new Response(null, {
          status: 204,
          headers: { "cache-control": "no-store" },
        });
      }
      throw error;
    }
    return new Response(null, {
      status: 204,
      headers: { "cache-control": "no-store" },
    });
  } catch (error) {
    return shareErrorResponse(error);
  }
}

export async function DELETE(
  request: Request,
  context: { params: Promise<{ code: string }> },
): Promise<Response> {
  const { code } = await context.params;
  return handleShareSessionEnd(request, code, productionDeps);
}
