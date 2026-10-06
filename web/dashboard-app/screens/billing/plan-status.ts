/**
 * Where a paid plan stands, for the account menu badge and the billing
 * screen's notice. Dates come from Stripe (`endsAt` is its `cancel_at`, or the
 * period end of a `cancel_at_period_end` subscription); nothing is computed here.
 */
export type PlanStanding =
  | { readonly kind: "free" }
  | { readonly kind: "active" }
  /** Cancelled, still paid for until `endsAt`, then Free. */
  | { readonly kind: "cancelling"; readonly endsAt: string | null }
  /** The latest payment failed; Stripe is retrying. */
  | { readonly kind: "pastDue" };

export function planStanding(input: {
  readonly isPro: boolean;
  readonly cancelScheduled: boolean;
  readonly endsAt: string | null;
  readonly paymentPastDue: boolean;
}): PlanStanding {
  if (!input.isPro) return { kind: "free" };
  // A failed payment is the more urgent of the two: access can end before the period does.
  if (input.paymentPastDue) return { kind: "pastDue" };
  if (input.cancelScheduled || input.endsAt) return { kind: "cancelling", endsAt: input.endsAt };
  return { kind: "active" };
}
