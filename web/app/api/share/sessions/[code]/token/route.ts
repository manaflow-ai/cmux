// Mint a connection token for an existing share code. Browser guests use
// cookie auth and can only receive host=false. A native bearer caller may ask
// for host=true to refresh the host grant for the same code.

import type { KeyObject } from "node:crypto";

import { checkRateLimit } from "@vercel/firewall";

import { readBoundedJsonObject } from "../../../../../../services/apns/routePolicy";
import {
  enforceShareRateLimit,
  jsonResponse,
  requireShareSigningKey,
  runShareEffect,
  shareErrorResponse,
  type ShareRateLimitCheck,
} from "../../../../../../services/share/http";
import {
  unauthorized,
  verifyRequest,
  type AuthedUser,
} from "../../../../../../services/vms/auth";
import {
  isValidShareCode,
  mintShareToken,
  shareSessionWsUrl,
  shareSigningKey,
} from "../../../../../../services/share/token";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const MAX_BODY_BYTES = 1_024;
const SHARE_TOKEN_RETRY_AFTER_SECONDS = 60;

export interface ShareGuestTokenDeps {
  readonly verifyGuestRequest: (
    request: Request,
  ) => Promise<AuthedUser | null>;
  readonly verifyNativeRequest: (
    request: Request,
  ) => Promise<AuthedUser | null>;
  readonly signingKey: () => KeyObject | null;
  readonly nowSeconds: () => number;
  readonly checkRateLimit: ShareRateLimitCheck;
  readonly rateLimitRuleId: () => string | undefined;
  readonly isVercel: () => boolean;
}

const productionDeps: ShareGuestTokenDeps = {
  verifyGuestRequest: (request) =>
    verifyRequest(request, { allowCookie: true }),
  verifyNativeRequest: (request) =>
    verifyRequest(request, { allowCookie: false }),
  signingKey: shareSigningKey,
  nowSeconds: () => Math.floor(Date.now() / 1000),
  checkRateLimit,
  rateLimitRuleId: () => process.env.CMUX_SHARE_TOKEN_RATE_LIMIT_ID,
  isVercel: () => process.env.VERCEL === "1",
};

export async function handleShareGuestToken(
  request: Request,
  code: string,
  deps: ShareGuestTokenDeps,
): Promise<Response> {
  if (!isValidShareCode(code)) {
    return jsonResponse({ error: "invalid_code" }, 400);
  }
  try {
    const body = await readBoundedJsonObject(request, MAX_BODY_BYTES);
    if (!body.ok) {
      return jsonResponse(
        { error: body.error },
        body.error === "request_too_large" ? 413 : 400,
      );
    }
    const host = body.value.host === true;
    const user = host
      ? await deps.verifyNativeRequest(request)
      : await deps.verifyGuestRequest(request);
    if (!user) return unauthorized();
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
      retryAfterSeconds: SHARE_TOKEN_RETRY_AFTER_SECONDS,
    }));
    await runShareEffect(enforceShareRateLimit({
      request,
      rateLimitKey: `${user.id}:${code}`,
      ruleId: rateLimitRuleId,
      check: deps.checkRateLimit,
      isVercel,
      retryAfterSeconds: SHARE_TOKEN_RETRY_AFTER_SECONDS,
    }));
    const { token, expiresAt } = mintShareToken({
      sub: user.id,
      email: user.primaryEmail ?? "",
      code,
      host,
      key,
      nowSeconds: deps.nowSeconds(),
    });
    return jsonResponse({
      token,
      expiresAt,
      wsUrl: shareSessionWsUrl(code),
    });
  } catch (error) {
    return shareErrorResponse(error);
  }
}

export async function POST(
  request: Request,
  context: { params: Promise<{ code: string }> },
): Promise<Response> {
  const { code } = await context.params;
  return handleShareGuestToken(request, code, productionDeps);
}
