import { createHash } from "node:crypto";

/**
 * Idempotency keys for the Stripe objects checkout creates. Each key is
 * derived from who is buying and the exact parameters sent, so a double
 * click, a retried navigation or two racing requests get Stripe's first
 * answer back instead of a second object. Stripe compares a replayed key's
 * parameters with the first request's and refuses a mismatch, so the
 * parameters are part of the key: any change (plan, price, seats, return
 * URL, attribution) is a different request with its own key.
 */

// A Checkout Session key covers one attempt. A replay inside the window is
// still checked against the session's current status (see isIdempotentReplay);
// the window only bounds how long one key is reused.
const CHECKOUT_ATTEMPT_WINDOW_MS = 10 * 60 * 1000;

// Stripe accepts keys up to 255 characters; Stack ids are UUIDs, and the
// digest covers the full id either way.
const MAX_READABLE_ID_LENGTH = 64;

export type CheckoutPrincipal = {
  readonly scope: "user" | "team";
  readonly id: string;
};

export function checkoutSessionIdempotencyKey(
  principal: CheckoutPrincipal,
  params: unknown,
  now: number = Date.now(),
): string {
  const attempt = Math.floor(now / CHECKOUT_ATTEMPT_WINDOW_MS);
  return idempotencyKey(`checkout-session/${principal.scope}`, principal.id, [attempt, params]);
}

/** The key for the attempt after `staleSessionId`, a replayed session that is no longer open. */
export function checkoutSessionRetryIdempotencyKey(key: string, staleSessionId: string): string {
  return idempotencyKey("checkout-session/after", staleSessionId, key);
}

/**
 * Whether Stripe answered with the stored response of an earlier request
 * under the same key. A replay is that first response as it was then, so a
 * replayed Checkout Session can read as open after it completed or expired.
 * stripe-node's Node client exposes plain lowercase headers, its fetch client
 * a Headers object.
 */
export function isIdempotentReplay(response: unknown): boolean {
  const headers = (response as { lastResponse?: { headers?: unknown } } | null)?.lastResponse?.headers;
  if (!headers || typeof headers !== "object") return false;
  const value = headers instanceof Headers
    ? headers.get("idempotent-replayed")
    : (headers as Record<string, unknown>)["idempotent-replayed"];
  return value === "true";
}

/**
 * One Stripe customer per team: racing first checkouts for a team get the
 * same customer back from Stripe for as long as Stripe keeps the key.
 */
export function teamCustomerIdempotencyKey(teamId: string, params: unknown): string {
  return idempotencyKey("team-customer", teamId, params);
}

function idempotencyKey(kind: string, id: string, payload: unknown): string {
  const digest = createHash("sha256").update(stableJson([id, payload])).digest("hex");
  return `cmux/${kind}/${id.slice(0, MAX_READABLE_ID_LENGTH)}/${digest}`;
}

/** JSON with sorted object keys; undefined fields are dropped, as Stripe's encoder drops them. */
function stableJson(value: unknown): string {
  return JSON.stringify(value, (_key, field: unknown) => {
    if (!field || typeof field !== "object" || Array.isArray(field)) return field;
    return Object.fromEntries(
      Object.entries(field as Record<string, unknown>).sort(([left], [right]) => (left < right ? -1 : left > right ? 1 : 0)),
    );
  });
}
