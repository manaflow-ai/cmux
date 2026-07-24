// Create a workspace share session: mint the share code and the host token.
// Native-only auth (the host is the macOS app); the browser guest path is
// app/api/share/sessions/[code]/token/route.ts. The session itself
// materializes in the share worker's Durable Object when the host connects —
// there is no database row, the code+token pair is the whole grant.

import type { KeyObject } from "node:crypto";

import { checkRateLimit } from "@vercel/firewall";

import {
  enforceShareRateLimit,
  jsonResponse,
  requireShareSigningKey,
  runShareEffect,
  shareErrorResponse,
  type ShareRateLimitCheck,
} from "../../../../services/share/http";
import {
  unauthorized,
  verifyRequest,
  type AuthedUser,
} from "../../../../services/vms/auth";
import {
  generateShareCode,
  mintShareToken,
  sharePageUrl,
  shareSessionWsUrl,
  shareSigningKey,
} from "../../../../services/share/token";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const SHARE_SESSION_CREATE_RETRY_AFTER_SECONDS = 10 * 60;

export interface ShareSessionCreateDeps {
  readonly verifyRequest: (request: Request) => Promise<AuthedUser | null>;
  readonly signingKey: () => KeyObject | null;
  readonly nowSeconds: () => number;
  readonly generateCode: () => string;
  readonly checkRateLimit: ShareRateLimitCheck;
  readonly rateLimitRuleId: () => string | undefined;
  readonly isVercel: () => boolean;
}

const productionDeps: ShareSessionCreateDeps = {
  verifyRequest: (request) => verifyRequest(request, { allowCookie: false }),
  signingKey: shareSigningKey,
  nowSeconds: () => Math.floor(Date.now() / 1000),
  generateCode: generateShareCode,
  checkRateLimit,
  rateLimitRuleId: () => process.env.CMUX_SHARE_SESSION_CREATE_RATE_LIMIT_ID,
  isVercel: () => process.env.VERCEL === "1",
};

export async function handleShareSessionCreate(
  request: Request,
  deps: ShareSessionCreateDeps,
): Promise<Response> {
  try {
    const user = await deps.verifyRequest(request);
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
      retryAfterSeconds: SHARE_SESSION_CREATE_RETRY_AFTER_SECONDS,
    }));
    await runShareEffect(enforceShareRateLimit({
      request,
      rateLimitKey: user.id,
      ruleId: rateLimitRuleId,
      check: deps.checkRateLimit,
      isVercel,
      retryAfterSeconds: SHARE_SESSION_CREATE_RETRY_AFTER_SECONDS,
    }));
    const code = deps.generateCode();
    const { token, expiresAt } = mintShareToken({
      sub: user.id,
      email: user.primaryEmail ?? "",
      code,
      host: true,
      create: true,
      key,
      nowSeconds: deps.nowSeconds(),
    });
    return jsonResponse({
      code,
      token,
      expiresAt,
      wsUrl: shareSessionWsUrl(code),
      shareUrl: sharePageUrl(code),
    });
  } catch (error) {
    return shareErrorResponse(error);
  }
}

export async function POST(request: Request): Promise<Response> {
  return handleShareSessionCreate(request, productionDeps);
}
