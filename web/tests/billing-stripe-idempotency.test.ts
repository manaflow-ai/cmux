import { describe, expect, test } from "bun:test";

import {
  checkoutSessionIdempotencyKey,
  isIdempotentReplay,
  teamCustomerIdempotencyKey,
} from "../services/billing/stripeIdempotency";

const USER = { scope: "user", id: "user-1" } as const;
const NOW = Date.UTC(2026, 9, 30, 12, 0, 0);
const MINUTE = 60 * 1000;

describe("Stripe checkout idempotency keys", () => {
  test("ignore field order and undefined fields, as Stripe's encoder does", () => {
    const first = checkoutSessionIdempotencyKey(USER, { mode: "subscription", customer: undefined, metadata: { a: "1", b: "2" } }, NOW);
    const second = checkoutSessionIdempotencyKey(USER, { metadata: { b: "2", a: "1" }, mode: "subscription" }, NOW);
    expect(second).toBe(first);
  });

  test("change with any parameter, the buyer's scope or id, and the attempt window", () => {
    const params = { mode: "subscription", line_items: [{ price: "price_pro", quantity: 1 }] };
    const key = checkoutSessionIdempotencyKey(USER, params, NOW);
    expect(checkoutSessionIdempotencyKey(USER, { ...params, line_items: [{ price: "price_max", quantity: 1 }] }, NOW)).not.toBe(key);
    expect(checkoutSessionIdempotencyKey({ scope: "team", id: "user-1" }, params, NOW)).not.toBe(key);
    expect(checkoutSessionIdempotencyKey({ scope: "user", id: "user-2" }, params, NOW)).not.toBe(key);
    expect(checkoutSessionIdempotencyKey(USER, params, NOW + 9 * MINUTE)).toBe(key);
    expect(checkoutSessionIdempotencyKey(USER, params, NOW + 10 * MINUTE)).not.toBe(key);
  });

  test("a team customer key is stable for the team and fits Stripe's 255-character limit", () => {
    const params = { name: "Team", metadata: { stackTeamId: "team-1", app: "cmux" } };
    expect(teamCustomerIdempotencyKey("team-1", params)).toBe(teamCustomerIdempotencyKey("team-1", { ...params }));
    expect(teamCustomerIdempotencyKey("team-2", params)).not.toBe(teamCustomerIdempotencyKey("team-1", params));
    expect(teamCustomerIdempotencyKey("t".repeat(500), params).length).toBeLessThanOrEqual(255);
  });

  test("recognize Stripe's Idempotent-Replayed header from either HTTP client", () => {
    expect(isIdempotentReplay({ lastResponse: { headers: { "idempotent-replayed": "true" } } })).toBe(true);
    expect(isIdempotentReplay({ lastResponse: { headers: new Headers({ "Idempotent-Replayed": "true" }) } })).toBe(true);
    expect(isIdempotentReplay({ lastResponse: { headers: { "idempotent-replayed": "false" } } })).toBe(false);
    expect(isIdempotentReplay({ lastResponse: { headers: {} } })).toBe(false);
    expect(isIdempotentReplay({ id: "cs_1" })).toBe(false);
    expect(isIdempotentReplay(null)).toBe(false);
  });
});
