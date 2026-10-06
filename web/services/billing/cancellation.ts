// When a Stripe subscription stops renewing, and the date access ends.
//
// Stripe marks a scheduled cancellation two ways. The legacy flag
// `cancel_at_period_end` is what our own Cancel button sets. Since the Basil
// API versions, a Billing Portal cancellation (and any subscription on the
// flexible billing mode) leaves that flag false and sets `cancel_at` to the
// end timestamp instead. Reading only the flag showed a cancelled plan as
// "Renews on ...", so every reader goes through these helpers.

/** The cancellation fields of a Stripe subscription payload (or our `raw` copy of it). */
export type StripeCancellationFields = {
  readonly cancel_at_period_end?: boolean | null;
  readonly cancel_at?: number | null;
};

function cancellationFields(value: unknown): StripeCancellationFields {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  const record = value as Record<string, unknown>;
  return {
    cancel_at_period_end: record.cancel_at_period_end === true,
    cancel_at: typeof record.cancel_at === "number" && Number.isFinite(record.cancel_at) ? record.cancel_at : null,
  };
}

/** Whether the subscription is scheduled to stop renewing, by either Stripe signal. */
export function stripeCancelScheduled(subscription: unknown): boolean {
  const fields = cancellationFields(subscription);
  return fields.cancel_at_period_end === true || fields.cancel_at != null;
}

/**
 * The moment access ends for a subscription that will not renew: Stripe's own
 * `cancel_at`, else the current period end for a `cancel_at_period_end`
 * subscription. Null while the subscription renews.
 */
export function stripeAccessEndsAt(subscription: unknown, currentPeriodEnd: Date | null): Date | null {
  const fields = cancellationFields(subscription);
  if (fields.cancel_at != null) return new Date(fields.cancel_at * 1000);
  return fields.cancel_at_period_end ? currentPeriodEnd : null;
}

/**
 * The Stripe update that undoes a scheduled cancellation: it clears the
 * field that scheduled it. Setting `cancel_at_period_end: false` leaves a
 * Portal-set `cancel_at` in place, so that one is cleared with `""`.
 */
export function stripeResumeParams(subscription: unknown): { cancel_at_period_end: false } | { cancel_at: "" } {
  const fields = cancellationFields(subscription);
  return !fields.cancel_at_period_end && fields.cancel_at != null ? { cancel_at: "" } : { cancel_at_period_end: false };
}

/**
 * The cancellation state of a stored `stripe_subscriptions` row. Rows synced
 * before both signals were read carry only `raw.cancel_at`, so the raw payload
 * counts as well as the column.
 */
export function storedSubscriptionCancellation(row: {
  readonly cancelAtPeriodEnd: boolean | null;
  readonly currentPeriodEnd: Date | null;
  readonly raw: unknown;
}): { readonly cancelScheduled: boolean; readonly endsAt: Date | null } {
  const raw = cancellationFields(row.raw);
  const fields = { cancel_at_period_end: row.cancelAtPeriodEnd === true || raw.cancel_at_period_end, cancel_at: raw.cancel_at };
  return { cancelScheduled: stripeCancelScheduled(fields), endsAt: stripeAccessEndsAt(fields, row.currentPeriodEnd) };
}
