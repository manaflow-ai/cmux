import { checkRateLimit as checkVercelRateLimit } from "@vercel/firewall";
import * as Effect from "effect/Effect";
import { after } from "next/server";

import { env } from "../../../env";
import { getStackServerApp, isStackConfigured } from "../../../lib/stack";
import { preferredLocaleFromAcceptLanguage } from "../../../../i18n/accept-language";
import { loadMessages } from "../../../../i18n/messages";
import englishMessages from "../../../../messages/en.json";
import { readBoundedJsonObject } from "../../../../services/apns/routePolicy";
import {
  requestEmailVerificationRecovery,
} from "../../../../services/auth/emailVerificationRecovery";
import {
  findPaidBillingPurchaseByEmail,
  provisionPaidBillingPurchase,
} from "../../../../services/billing/recovery";
import {
  processBillingRecovery,
  type BillingRecoveryDeliveryDependencies,
} from "../../../../services/billing/recoveryDelivery";
import { recordSpanError, withApiRouteSpan, withSpan } from "../../../../services/telemetry";

const MAX_REQUEST_BYTES = 4 * 1_024;
const PRODUCTION_MAGIC_LINK_CALLBACK = "https://cmux.com/handler/after-sign-in";
export const BILLING_RECOVERY_RESPONSE_MESSAGE =
  (englishMessages as { billingRecovery: { message: string } }).billingRecovery
    .message;

type RateLimitCheck = typeof checkVercelRateLimit;

export type BillingRecoveryRouteDependencies = BillingRecoveryDeliveryDependencies & {
  readonly afterResponse: (task: () => Promise<void>) => void;
  readonly checkRateLimit: RateLimitCheck;
  readonly rateLimitRuleID: () => string | undefined;
  readonly isVercel: () => boolean;
};

const productionDependencies: BillingRecoveryRouteDependencies = {
  afterResponse: after,
  recoverPaid: async (email) => {
    if (!isStackConfigured()) return false;
    const stackApp = getStackServerApp();
    const purchase = await findPaidBillingPurchaseByEmail(email);
    if (!purchase) return false;
    const completion = await provisionPaidBillingPurchase(
      {
        ...purchase,
        input: {
          ...purchase.input,
          sendRecoveryMagicLink: true,
        },
      },
      { stackApp },
    );
    if (!completion || !("scope" in completion) || completion.scope !== "user") {
      if (completion && "skipped" in completion) {
        return { skipped: completion.skipped };
      }
      return { deliveryEmail: email, deliveryHandled: true };
    }
    const user = await stackApp.getUser(completion.stackUserId);
    return {
      deliveryEmail: user?.primaryEmail?.trim() || email,
      deliveryHandled: true,
    };
  },
  sendMagicLink: async ({ email, callbackURL }) => {
    const result = await getStackServerApp().sendMagicLinkEmail(email, {
      callbackUrl: callbackURL,
    });
    if (isFailedStackResult(result)) {
      throw new Error("Stack sign-in code request failed");
    }
  },
  sendVerification: ({ email, callbackURL }) =>
    Effect.runPromise(
      requestEmailVerificationRecovery(
        { email, callbackURL },
        { stackApp: getStackServerApp() },
      ),
    ),
  checkRateLimit: checkVercelRateLimit,
  // Use the dedicated recovery rule first. The feedback rule is only a
  // migration fallback for deployments that have not created the new rule.
  rateLimitRuleID: () =>
    env.CMUX_BILLING_RECOVERY_RATE_LIMIT_ID ?? env.CMUX_FEEDBACK_RATE_LIMIT_ID,
  isVercel: () => process.env.VERCEL === "1",
};

export function makeBillingRecoveryHandler(
  dependencies: BillingRecoveryRouteDependencies = productionDependencies,
) {
  return async function POST(request: Request): Promise<Response> {
    return withApiRouteSpan(
      request,
      "/api/billing/recover",
      { "cmux.subsystem": "billing", "cmux.billing.operation": "recover" },
      async (span) => {
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

        // Construct the entire response before registering work. Account lookup,
        // provisioning and delivery must not determine acceptance latency.
        const response = json(
          {
            accepted: true,
            delivery: "unconfirmed",
            retryable: true,
            message: await billingRecoveryResponseMessage(request),
          },
          202,
        );
        const input = {
          email,
          callbackURL: magicLinkCallbackURL(request),
          verificationURL: emailVerificationCallbackURL(request),
        };
        try {
          // Pass a callback, not an already-started promise: Next invokes it
          // after the response closes and keeps the Vercel function alive.
          dependencies.afterResponse(() =>
            withSpan(
              "cmux-billing",
              "cmux.billing.recovery.process",
              { "cmux.subsystem": "billing" },
              (processingSpan) => Effect.runPromise(
                processBillingRecovery(input, dependencies).pipe(
                  Effect.catchAll((error) => Effect.sync(() => {
                    // The typed error deliberately carries no provider payload,
                    // email, or cause. Raw SDK errors can contain customer data.
                    recordSpanError(processingSpan, error);
                    console.error("billing.recovery.provider_failure", {
                      failure: "provider_unavailable",
                    });
                  })),
                ),
              ),
            ),
          );
        } catch {
          // No account-dependent work has started, so registration failure can
          // safely fail closed without becoming an account-existence signal.
          return json({ error: "recovery_unavailable" }, 503);
        }
        span.setAttribute("cmux.billing.recovery.response_ready", true);
        return response;
      },
    );
  };
}

async function billingRecoveryResponseMessage(request: Request): Promise<string> {
  try {
    const locale = preferredLocaleFromAcceptLanguage(
      request.headers.get("accept-language") ?? "",
    );
    const messages = await loadMessages(locale);
    const candidate = (messages.billingRecovery as { message?: unknown } | undefined)
      ?.message;
    return typeof candidate === "string" && candidate.length > 0
      ? candidate
      : BILLING_RECOVERY_RESPONSE_MESSAGE;
  } catch {
    // Localization must never turn an otherwise generic recovery response into
    // an availability or account-enumeration signal.
    return BILLING_RECOVERY_RESPONSE_MESSAGE;
  }
}

export const POST = makeBillingRecoveryHandler();

async function enforceRateLimit(
  request: Request,
  dependencies: BillingRecoveryRouteDependencies,
): Promise<Response | null> {
  // The Vercel Firewall client is the only limiter wired to this public route.
  // A non-Vercel runtime therefore has no usable throttle and must fail closed
  // before it can send authentication mail.
  if (!dependencies.isVercel()) {
    return json({ error: "recovery_unavailable" }, 503);
  }
  const ruleID = dependencies.rateLimitRuleID()?.trim();
  // Recovery sends authentication mail and must fail closed when its rule is
  // absent; unlike feedback, an unthrottled endpoint is not acceptable.
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
  if (!/^\S+@\S+\.\S+$/.test(email)) return null;
  return email;
}

function magicLinkCallbackURL(request: Request): string {
  const requestURL = new URL(request.url);
  if (
    requestURL.hostname === "localhost" ||
    requestURL.hostname === "127.0.0.1" ||
    requestURL.hostname === "[::1]"
  ) {
    return new URL("/handler/after-sign-in", requestURL.origin).toString();
  }
  return PRODUCTION_MAGIC_LINK_CALLBACK;
}

function emailVerificationCallbackURL(request: Request): string {
  const requestURL = new URL(request.url);
  if (
    requestURL.hostname === "localhost" ||
    requestURL.hostname === "127.0.0.1" ||
    requestURL.hostname === "[::1]"
  ) {
    return new URL("/handler/email-verification", requestURL.origin).toString();
  }
  return "https://cmux.com/handler/email-verification";
}

function json(body: Record<string, unknown>, status: number): Response {
  return Response.json(body, {
    status,
    headers: { "cache-control": "no-store" },
  });
}

function isFailedStackResult(value: unknown): boolean {
  return Boolean(
    value &&
      typeof value === "object" &&
      "status" in value &&
      (value as { status?: unknown }).status === "error",
  );
}
