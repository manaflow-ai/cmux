import { checkRateLimit as checkVercelRateLimit } from "@vercel/firewall";
import * as Effect from "effect/Effect";

import { getStackServerApp } from "../../../lib/stack";
import { readBoundedJsonObject } from "../../../../services/apns/routePolicy";
import {
  requestEmailVerificationRecovery,
  type EmailVerificationRecoveryResult,
} from "../../../../services/auth/emailVerificationRecovery";

const MAX_REQUEST_BYTES = 4 * 1_024;
const PRODUCTION_VERIFICATION_CALLBACK =
  "https://cmux.com/handler/email-verification";

type RateLimitCheck = typeof checkVercelRateLimit;

export type EmailVerificationRecoveryRouteDependencies = {
  readonly recover: (input: {
    readonly email: string;
    readonly callbackURL: string;
  }) => Promise<EmailVerificationRecoveryResult>;
  readonly checkRateLimit: RateLimitCheck;
  readonly rateLimitRuleID: () => string | undefined;
  readonly isVercel: () => boolean;
};

const productionDependencies: EmailVerificationRecoveryRouteDependencies = {
  recover: (input) =>
    Effect.runPromise(
      requestEmailVerificationRecovery(input, {
        stackApp: getStackServerApp(),
      }),
    ),
  checkRateLimit: checkVercelRateLimit,
  rateLimitRuleID: () => process.env.CMUX_FEEDBACK_RATE_LIMIT_ID,
  isVercel: () => process.env.VERCEL === "1",
};

export function makeEmailVerificationRecoveryHandler(
  dependencies: EmailVerificationRecoveryRouteDependencies = productionDependencies,
) {
  return async function POST(request: Request): Promise<Response> {
    const rateLimitResponse = await enforceRateLimit(request, dependencies);
    if (rateLimitResponse) return rateLimitResponse;

    const body = await readBoundedJsonObject(request, MAX_REQUEST_BYTES);
    if (!body.ok) {
      return json(
        { error: body.error },
        body.error === "request_too_large" ? 413 : 400,
      );
    }
    const email = validEmail(body.value.email);
    if (!email) return json({ error: "invalid_email" }, 400);

    try {
      await dependencies.recover({
        email,
        callbackURL: verificationCallbackURL(request),
      });
    } catch {
      console.error("auth.email_verification_recovery.unexpected", {
        failure: "unexpected",
      });
    }
    // Sent, no-match, already-verified, and delivery-failure outcomes share the
    // same public response so this endpoint cannot enumerate account state.
    return json({ ok: true }, 202);
  };
}

export const POST = makeEmailVerificationRecoveryHandler();

async function enforceRateLimit(
  request: Request,
  dependencies: EmailVerificationRecoveryRouteDependencies,
): Promise<Response | null> {
  if (!dependencies.isVercel()) return null;
  const ruleID = dependencies.rateLimitRuleID()?.trim();
  if (!ruleID) return json({ error: "recovery_unavailable" }, 503);
  try {
    const { error, rateLimited } = await dependencies.checkRateLimit(ruleID, {
      request,
    });
    if (rateLimited || error === "blocked") {
      return json({ error: "rate_limited" }, 429);
    }
    if (error) return json({ error: "recovery_unavailable" }, 503);
    return null;
  } catch {
    return json({ error: "recovery_unavailable" }, 503);
  }
}

function validEmail(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const email = value.trim();
  if (email.length === 0 || email.length > 254) return null;
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return null;
  return email;
}

function verificationCallbackURL(request: Request): string {
  const requestURL = new URL(request.url);
  if (
    requestURL.hostname === "localhost" ||
    requestURL.hostname === "127.0.0.1" ||
    requestURL.hostname === "[::1]"
  ) {
    return new URL("/handler/email-verification", requestURL.origin).toString();
  }
  return PRODUCTION_VERIFICATION_CALLBACK;
}

function json(body: Record<string, unknown>, status: number): Response {
  return Response.json(body, {
    status,
    headers: { "cache-control": "no-store" },
  });
}
