// Classifies a completed Stripe checkout session for the welcome-email
// telemetry. cmux Pro and Founder's Edition sessions are handled by this
// endpoint's personal welcome; Team and unrelated checkout shapes remain
// excluded from delivery.
//
// - "founders_edition": sessions created from the cmux Founder's Edition
//   payment link, which copies `founders_edition=true` onto each session.
// - "pro_plan": cmux Pro subscription checkouts created by
//   /api/billing/checkout, which set `{ app: "cmux", plan: "pro" }` (monthly
//   and yearly intervals share this metadata).
// - "team_plan": cmux Team subscription checkouts (`{ app: "cmux", plan:
//   "team" }`).
// - "other": any other completed checkout session.
//
// Kept free of Stripe/Resend/env imports so it can be unit-tested directly
// (web/tests/founders-welcome-email.test.ts); the route handler (./route.ts)
// owns the I/O.

export type WelcomeTrigger =
  | "founders_edition"
  | "pro_plan"
  | "team_plan"
  | "other";

export function welcomeTriggerForMetadata(
  metadata: Record<string, string> | null | undefined,
): WelcomeTrigger {
  if (metadata?.founders_edition === "true") {
    return "founders_edition";
  }
  if (metadata?.app === "cmux" && metadata?.plan === "pro") {
    return "pro_plan";
  }
  if (metadata?.app === "cmux" && metadata?.plan === "team") {
    return "team_plan";
  }
  return "other";
}

/**
 * Classify a checkout using the session metadata first, then an expanded
 * subscription when the session has no product marker. Stripe can place the
 * checkout product metadata on either object depending on which API creates
 * the session. An explicit session app, plan, or Founder marker remains the
 * trust boundary, so a nested subscription cannot turn a foreign checkout
 * into a cmux welcome.
 */
export function welcomeTriggerForCheckout(
  sessionMetadata: Record<string, string> | null | undefined,
  subscriptionMetadata: Record<string, string> | null | undefined,
): WelcomeTrigger {
  const hasSessionProductMarker = Boolean(
    sessionMetadata &&
      (Object.prototype.hasOwnProperty.call(sessionMetadata, "app") ||
        Object.prototype.hasOwnProperty.call(sessionMetadata, "plan") ||
        Object.prototype.hasOwnProperty.call(
          sessionMetadata,
          "founders_edition",
        )),
  );
  if (hasSessionProductMarker) {
    return welcomeTriggerForMetadata(sessionMetadata);
  }
  return welcomeTriggerForMetadata(subscriptionMetadata);
}
