// Pure decision of whether a completed Stripe checkout session earns the
// founders welcome email, and which condition matched.
//
// Two session shapes qualify (product decision: Founder's Edition and cmux Pro
// are the same tier and get the same welcome):
//
// - "founders_edition": sessions created from the cmux Founder's Edition
//   payment link, which copies `founders_edition=true` onto each session.
// - "pro_plan": cmux Pro subscription checkouts created by
//   /api/billing/checkout, which set `{ app: "cmux", plan: "pro" }` (monthly
//   and yearly intervals share this metadata). The Team plan (`plan: "team"`)
//   is intentionally excluded.
//
// Kept free of Stripe/Resend/env imports so it can be unit-tested directly
// (web/tests/founders-welcome-email.test.ts); the route handler (./route.ts)
// owns the I/O.

export type WelcomeTrigger = "founders_edition" | "pro_plan";

export function welcomeTriggerForMetadata(
  metadata: Record<string, string> | null | undefined,
): WelcomeTrigger | null {
  if (metadata?.founders_edition === "true") {
    return "founders_edition";
  }
  if (metadata?.app === "cmux" && metadata?.plan === "pro") {
    return "pro_plan";
  }
  return null;
}
