/**
 * Prefix stored on a `stripe_webhook_events.error` whose processing lost a
 * transient race, such as two Stripe events for one purchase contending for
 * the same account mutation lease. Billing alerts give these rows time to
 * clear through Stripe redelivery and the replay cron before paging.
 */
export const STRIPE_WEBHOOK_RETRYABLE_ERROR_PREFIX = "retryable: ";
