import { NextRequest, NextResponse } from "next/server";
import type Stripe from "stripe";

import {
  trustedNativeCallbackScheme,
  validatedNativeCallbackScheme,
} from "../../../lib/native-callback";
import { captureBillingError } from "../../../../services/errors";
import {
  isCmuxCheckoutSession,
  hasConflictingFounderMetadata,
  recordCheckoutCompletion as recordCheckoutCompletionDefault,
  recordFoundersCheckoutCompletion as recordFoundersCheckoutCompletionDefault,
} from "../../../../services/billing/purchase";
import { isStripeBillingConfigured, stripe } from "../../../../services/billing/stripe";
import {
  recordSpanError,
  withApiRouteSpan,
} from "../../../../services/telemetry";


type BillingCompleteDependencies = {
  isConfigured: () => boolean;
  stripe: typeof stripe;
  recordCheckoutCompletion: typeof recordCheckoutCompletionDefault;
  recordFoundersCheckoutCompletion?: typeof recordFoundersCheckoutCompletionDefault;
};

const defaultDependencies: BillingCompleteDependencies = {
  isConfigured: isStripeBillingConfigured,
  stripe,
  recordCheckoutCompletion: recordCheckoutCompletionDefault,
  recordFoundersCheckoutCompletion: recordFoundersCheckoutCompletionDefault,
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
        const expandedSubscriptionValue = expandedSubscription(session);
        if (hasConflictingFounderMetadata(session, expandedSubscriptionValue)) {
          return NextResponse.redirect(new URL("/pricing?billing=error", request.url));
        }
        if (!isCmuxCheckoutSession(session, expandedSubscriptionValue)) {
          return NextResponse.redirect(new URL("/pricing?billing=error", request.url));
        }
        const scheme =
          trustedNativeCallbackScheme(session.metadata?.nativeCallbackScheme) ??
          requestedScheme;
        if (
          session.payment_status === "paid" ||
          session.payment_status === "no_payment_required"
        ) {
          const isFounderCheckout =
            session.metadata?.founders_edition === "true" ||
            expandedSubscriptionValue?.metadata?.founders_edition === "true";
          const completion = isFounderCheckout
            ? await (dependencies.recordFoundersCheckoutCompletion ?? recordFoundersCheckoutCompletionDefault)({
                session,
                subscription: expandedSubscriptionValue,
                customer: expandedCustomer(session),
              })
            : await dependencies.recordCheckoutCompletion({
                session,
                subscription: expandedSubscriptionValue,
                customer: expandedCustomer(session),
              });
          if ("skipped" in completion) {
            const reason = completion.skipped === "account_deletion_in_progress"
              ? "account_deletion"
              : "error";
            return NextResponse.redirect(new URL(`/pricing?billing=${reason}`, request.url));
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
