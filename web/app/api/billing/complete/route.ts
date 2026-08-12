import { NextRequest, NextResponse } from "next/server";
import * as Effect from "effect/Effect";
import type Stripe from "stripe";

import { getStackServerApp } from "../../../lib/stack";
import {
  trustedNativeCallbackScheme,
  validatedNativeCallbackScheme,
} from "../../../lib/native-callback";
import { captureBillingError } from "../../../../services/errors";
import {
  isCmuxCheckoutSession,
  recordCheckoutCompletion as recordCheckoutCompletionDefault,
} from "../../../../services/billing/purchase";
import { isStripeBillingConfigured, stripe } from "../../../../services/billing/stripe";
import {
  recordSpanError,
  withApiRouteSpan,
} from "../../../../services/telemetry";
import {
  requestEmailVerificationRecovery,
  type EmailVerificationRecoveryResult,
} from "../../../../services/auth/emailVerificationRecovery";


type BillingCompleteDependencies = {
  isConfigured: () => boolean;
  stripe: typeof stripe;
  recordCheckoutCompletion: typeof recordCheckoutCompletionDefault;
  requestEmailVerification: (input: {
    email: string;
    callbackURL: string;
  }) => Promise<EmailVerificationRecoveryResult>;
};

const defaultDependencies: BillingCompleteDependencies = {
  isConfigured: isStripeBillingConfigured,
  stripe,
  recordCheckoutCompletion: recordCheckoutCompletionDefault,
  requestEmailVerification: (input) =>
    Effect.runPromise(
      requestEmailVerificationRecovery(input, {
        stackApp: getStackServerApp(),
      }),
    ),
};

export const GET = makeBillingCompleteHandler();

export function makeBillingCompleteHandler(
  dependencies: BillingCompleteDependencies = defaultDependencies,
) {
  return async function GET(request: NextRequest) {
  return withApiRouteSpan(
    request,
    "/api/billing/complete",
    { "cmux.subsystem": "billing", "cmux.billing.operation": "stripe_complete" },
    async (span) => {
      if (!dependencies.isConfigured()) {
        return NextResponse.redirect(new URL("/pricing?billing=unavailable", request.url));
      }

      const sessionId = request.nextUrl.searchParams.get("session_id");
      if (!sessionId) {
        return NextResponse.redirect(new URL("/pricing?billing=error", request.url));
      }

      const requestedScheme = validatedNativeCallbackScheme(
        request.nextUrl.searchParams.get("cmux_scheme"),
        request,
      );
      try {
        const session = await dependencies.stripe().checkout.sessions.retrieve(sessionId, {
          expand: ["subscription", "customer"],
        });
        if (!isCmuxCheckoutSession(session)) {
          return NextResponse.redirect(new URL("/pricing?billing=error", request.url));
        }
        const scheme =
          trustedNativeCallbackScheme(session.metadata?.nativeCallbackScheme) ??
          requestedScheme;
        if (
          session.payment_status === "paid" ||
          session.payment_status === "no_payment_required"
        ) {
          const completion = await dependencies.recordCheckoutCompletion({
            session,
            subscription: expandedSubscription(session),
            customer: expandedCustomer(session),
          });
          if ("skipped" in completion) {
            return NextResponse.redirect(new URL("/pricing?billing=account_deletion", request.url));
          }
          if (completion.scope === "user") {
            const email = checkoutEmail(session, expandedCustomer(session));
            if (email) {
              try {
                await dependencies.requestEmailVerification({
                  email,
                  callbackURL: emailVerificationCallbackURL(request),
                });
              } catch (error) {
                captureBillingError(error, {
                  route: "/api/billing/complete",
                  operation: "requestEmailVerification",
                  hasSessionId: true,
                });
              }
            }
          }
          if (session.metadata?.plan === "team") {
            return NextResponse.redirect(
              new URL("/dashboard/billing?welcome=team", request.nextUrl.origin),
            );
          }
          const success = new URL("/billing/success", request.nextUrl.origin);
          success.searchParams.set("session_id", session.id);
          success.searchParams.set("cmux_scheme", scheme);
          return NextResponse.redirect(success);
        }
        return NextResponse.redirect(new URL("/pricing?welcome=pending", request.url));
      } catch (error) {
        recordSpanError(span, error);
        captureBillingError(error, {
          route: "/api/billing/complete",
          hasSessionId: Boolean(sessionId),
        });
        return NextResponse.redirect(new URL("/pricing?billing=error", request.url));
      }
    },
  );
  };
}

function expandedSubscription(session: Stripe.Checkout.Session): Stripe.Subscription | null {
  return typeof session.subscription === "object" && session.subscription !== null
    ? session.subscription
    : null;
}

function expandedCustomer(
  session: Stripe.Checkout.Session,
): Stripe.Customer | Stripe.DeletedCustomer | null {
  return typeof session.customer === "object" && session.customer !== null
    ? session.customer
    : null;
}

function checkoutEmail(
  session: Stripe.Checkout.Session,
  customer: Stripe.Customer | Stripe.DeletedCustomer | null,
): string | null {
  const email =
    session.customer_details?.email ??
    (customer && !customer.deleted ? customer.email : null);
  const normalized = email?.trim().toLowerCase();
  return normalized || null;
}

function emailVerificationCallbackURL(request: NextRequest): string {
  if (
    request.nextUrl.hostname === "localhost" ||
    request.nextUrl.hostname === "127.0.0.1" ||
    request.nextUrl.hostname === "[::1]"
  ) {
    return new URL(
      "/handler/email-verification",
      request.nextUrl.origin,
    ).toString();
  }
  return "https://cmux.com/handler/email-verification";
}
