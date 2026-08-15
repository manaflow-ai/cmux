// Classifies a completed Stripe checkout session for the welcome-email
// telemetry. cmux Pro is handled by the billing webhook, while explicit
// Founder's Edition sessions and the existing catch-all purchase shapes retain
// this endpoint's personal founder welcome.
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
