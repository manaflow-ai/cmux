import { createHash } from "node:crypto";

/**
 * How long a repeated identical checkout request reuses one Stripe Checkout
 * Session. A double click, a retried navigation, or two tabs racing past the
 * "already subscribed" check inside this window get the same session instead
 * of a second one.
 */
export const CHECKOUT_IDEMPOTENCY_WINDOW_MS = 10 * 60_000;

export type CheckoutIdempotencyInput = {
  /** Who pays: the personal account, the team, or the Cloud intro pass. */
  readonly scope: "user" | "team" | "cloud-intro";
  /** The verified Stack user or team id the session is for. */
  readonly subjectId: string;
  readonly plan: string;
  readonly interval: string;
  /**
   * The exact Checkout Session parameters. Stripe refuses a reused key whose
   * parameters differ, so their digest is part of the key: identical requests
   * share one session, and a different request (another return page or app
   * scheme) never collides with it.
   */
  readonly params: unknown;
  readonly now?: number;
};

/**
 * The Stripe idempotency key for one Checkout Session create: deterministic in
 * the subject, plan, interval, a short time bucket and the request's own
 * parameters. Local work only (one SHA-256 over the params); no extra call.
 */
export function checkoutIdempotencyKey(input: CheckoutIdempotencyInput): string {
  const bucket = Math.floor((input.now ?? Date.now()) / CHECKOUT_IDEMPOTENCY_WINDOW_MS);
  const digest = createHash("sha256").update(JSON.stringify(input.params) ?? "").digest("hex").slice(0, 24);
  return `checkout/${input.scope}/${input.subjectId}/${input.plan}/${input.interval}/${bucket}/${digest}`;
}
