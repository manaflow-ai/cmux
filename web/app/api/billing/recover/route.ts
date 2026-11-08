import { checkRateLimit as checkVercelRateLimit } from "@vercel/firewall";
import * as Effect from "effect/Effect";

import { env } from "../../../env";
import { getStackServerApp, isStackConfigured } from "../../../lib/stack";
import { preferredLocaleFromAcceptLanguage } from "../../../../i18n/accept-language";
import { loadMessages } from "../../../../i18n/messages";
import englishMessages from "../../../../messages/en.json";
import { readBoundedJsonObject } from "../../../../services/apns/routePolicy";
import {
  requestEmailVerificationRecovery,
  type EmailVerificationRecoveryResult,
} from "../../../../services/auth/emailVerificationRecovery";
import {
  findPaidBillingPurchaseByEmail,
  provisionPaidBillingPurchase,
} from "../../../../services/billing/recovery";
import { recordSpanError, withApiRouteSpan } from "../../../../services/telemetry";

const MAX_REQUEST_BYTES = 4 * 1_024;
const PRODUCTION_MAGIC_LINK_CALLBACK = "https://cmux.com/handler/after-sign-in";
export const BILLING_RECOVERY_RESPONSE_MESSAGE =
  (englishMessages as { billingRecovery: { message: string } }).billingRecovery
    .message;

type PaidRecoveryResult =
  | false
  | true
  | {
      readonly deliveryEmail: string | null;
      /** The completion recorder already used the delivery ledger. */
      readonly deliveryHandled?: boolean;
    }
  | {
      readonly skipped:
        | "account_deletion_in_progress"
        | "no_customer_email";
    };

type RateLimitCheck = typeof checkVercelRateLimit;

export type BillingRecoveryRouteDependencies = {
  readonly recoverPaid: (email: string) => Promise<PaidRecoveryResult>;
  readonly sendMagicLink: (input: {
    readonly email: string;
    readonly callbackURL: string;
  }) => Promise<void>;
  readonly sendVerification: (input: {
    readonly email: string;
    readonly callbackURL: string;
  }) => Promise<EmailVerificationRecoveryResult>;
  readonly checkRateLimit: RateLimitCheck;
  readonly rateLimitRuleID: () => string | undefined;
  readonly isVercel: () => boolean;
};

const productionDependencies: BillingRecoveryRouteDependencies = {
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

        const callbackURL = magicLinkCallbackURL(request);
        const verificationURL = emailVerificationCallbackURL(request);
        try {
          const paid = await dependencies.recoverPaid(email);
          if (paid && typeof paid === "object" && "skipped" in paid) {
            // Do not expose whether a paid account exists or why delivery was
            // skipped. Continue with the same generic response as every other
            // address. No authentication message is sent for this outcome.
          } else if (paid) {
            const candidateDeliveryEmail =
              typeof paid === "object" ? paid.deliveryEmail : null;
            const deliveryHandled =
              typeof paid === "object" && paid.deliveryHandled === true;
            if (!deliveryHandled) {
              const deliveryEmail =
                candidateDeliveryEmail && validEmail(candidateDeliveryEmail)
                  ? candidateDeliveryEmail
                  : email;
              await dependencies.sendMagicLink({
                email: deliveryEmail,
                callbackURL,
              });
            }
          } else if (!paid) {
            await dependencies.sendVerification({
              email,
              callbackURL: verificationURL,
            });
          }
        } catch (error) {
          // Never turn provider state into an account-enumeration signal. The
          // span records the failure without customer identifiers or payloads.
          recordSpanError(span, error);
          console.error("billing.recovery.provider_failure", {
            failure: "provider_unavailable",
          });
          // Keep the successful-address response generic. Returning a provider
          // error only for addresses that reached a delivery path would let a
          // caller distinguish paid or registered mailboxes.
        }

        return json(
          {
            accepted: true,
            // This is an accepted request, not proof that a message was sent.
            // Keep the delivery state and retry guidance identical for every
            // valid address so provider failures do not become an account-
            // existence signal.
            delivery: "unconfirmed",
            retryable: true,
            message: await billingRecoveryResponseMessage(request),
          },
          202,
        );
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
