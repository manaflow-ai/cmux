import { describe, expect, mock, test } from "bun:test";

import { makeStripeWebhookReplayer } from "../services/billing/stripeWebhook";
import { memoryStripeWebhookInbox } from "./helpers/stripe-webhook-inbox-memory";

const NOW = new Date("2026-10-07T02:00:00.000Z");
const minutesAgo = (minutes: number) => new Date(NOW.getTime() - minutes * 60_000);

function replayer(input: {
  readonly clock?: () => Date;
  readonly applySubscriptionUpdate: () => Promise<unknown>;
  readonly retrieveEvent?: (id: string) => Promise<unknown>;
}) {
  const store = memoryStripeWebhookInbox(() => NOW);
  const retrieveEvent = mock(input.retrieveEvent ?? (async (id: string) => ({
    id,
    type: "customer.subscription.created",
    data: { object: { id: "sub_1" } },
  })));
  const replay = makeStripeWebhookReplayer({
    webhookSecret: () => "whsec_test",
    isConfigured: () => true,
    stripe: () =>
      ({
        events: { retrieve: retrieveEvent },
        subscriptions: {
          retrieve: async () => ({
            id: "sub_1",
            customer: "cus_1",
            status: "active",
            metadata: { stackUserId: "user_1", app: "cmux" },
          }),
        },
      }) as never,
    inbox: store.inbox,
    now: input.clock ?? (() => NOW),
    recordCheckoutCompletion: (async () => {
      throw new Error("unexpected checkout");
    }) as never,
    applySubscriptionUpdate: input.applySubscriptionUpdate as never,
    sendProSignupWelcome: async () => {},
    isPersonalWelcomeConfigured: () => true,
    revokeCoderouterRouteTokens: async () => {},
    revokeCoderouterTeamRouteTokens: async () => {},
    captureStripeBillingEvent: async () => {},
    defer: () => {},
  });
  const enqueue = async (id: string, storedMinutesAgo: number, objectKey: string | null = "sub_1") => {
    await store.inbox.record({ id, type: "customer.subscription.created", payloadHash: "h", objectKey, createdAt: null });
    const row = store.rows.get(id)!;
    row.storedAt = minutesAgo(storedMinutesAgo);
    row.nextAttemptAt = minutesAgo(storedMinutesAgo - 2);
  };
  return { replay, store, enqueue, retrieveEvent };
}

describe("Stripe webhook inbox drain", () => {
  test("processes a due event from Stripe's record and marks it processed", async () => {
    const { replay, store, enqueue, retrieveEvent } = replayer({
      applySubscriptionUpdate: async () => ({ scope: "user", stackUserId: "user_1", isActive: true }),
    });
    await enqueue("evt_failed", 10);

    const summary = await replay(NOW);

    expect(summary).toEqual({ attempted: 1, succeeded: 1, failed: 0 });
    expect(retrieveEvent).toHaveBeenCalledWith("evt_failed");
    expect(store.rows.get("evt_failed")).toMatchObject({ error: null, processedAt: NOW });
  });

  test("keeps a still-failing event with its error and backs off further each attempt", async () => {
    const { replay, store, enqueue } = replayer({
      applySubscriptionUpdate: async () => {
        throw new Error("Stack Auth unavailable");
      },
    });
    await enqueue("evt_failed", 10);

    expect(await replay(NOW)).toEqual({ attempted: 1, succeeded: 0, failed: 1 });
    const row = store.rows.get("evt_failed")!;
    expect(row).toMatchObject({ error: "Stack Auth unavailable", processedAt: null, attempts: 1 });
    const firstDelay = row.nextAttemptAt.getTime() - NOW.getTime();
    expect(firstDelay).toBe(60_000);

    // Not due again until the backoff ends.
    expect(await replay(NOW)).toEqual({ attempted: 0, succeeded: 0, failed: 0 });
    row.nextAttemptAt = NOW;
    await replay(NOW);
    expect(row.attempts).toBe(2);
    expect(row.nextAttemptAt.getTime() - NOW.getTime()).toBe(5 * 60_000);
  });

  test("leaves a fresh event to the webhook's own processing", async () => {
    const { replay, store } = replayer({
      applySubscriptionUpdate: async () => ({ scope: "user", stackUserId: "user_1", isActive: true }),
    });
    await store.inbox.record({ id: "evt_fresh", type: "invoice.paid", payloadHash: "h", objectKey: "sub_1", createdAt: null });

    expect(await replay(NOW)).toEqual({ attempted: 0, succeeded: 0, failed: 0 });
  });

  test("processes one event per subscription at a time", async () => {
    const { replay, store, enqueue } = replayer({
      applySubscriptionUpdate: async () => ({ scope: "user", stackUserId: "user_1", isActive: true }),
    });
    await enqueue("evt_a", 20);
    await enqueue("evt_b", 10);
    await store.inbox.claim("evt_a", NOW, new Date(NOW.getTime() + 60_000));

    expect(await replay(NOW)).toEqual({ attempted: 0, succeeded: 0, failed: 0 });
    expect(store.rows.get("evt_b")?.processedAt).toBeNull();
  });

  test("a worker whose lease was taken over cannot record its result", async () => {
    const { store, enqueue } = replayer({ applySubscriptionUpdate: async () => ({ skipped: true }) });
    await enqueue("evt_a", 10);
    const stale = (await store.inbox.claim("evt_a", NOW, new Date(NOW.getTime() + 1_000)))!;
    const later = new Date(NOW.getTime() + 2_000);
    const current = (await store.inbox.claim("evt_a", later, new Date(later.getTime() + 60_000)))!;

    expect(await store.inbox.complete(stale, null)).toBe(false);
    expect(await store.inbox.fail(stale, "late", later)).toBe(false);
    expect(await store.inbox.complete(current, null)).toBe(true);
  });

  test("a row stored before the inbox gains its object key and waits for a running sibling", async () => {
    const { replay, store } = replayer({
      applySubscriptionUpdate: async () => ({ scope: "user", stackUserId: "user_1", isActive: true }),
    });
    await store.inbox.record({ id: "evt_legacy", type: "customer.subscription.created", payloadHash: "h", objectKey: null, createdAt: null });
    Object.assign(store.rows.get("evt_legacy")!, { storedAt: minutesAgo(30), nextAttemptAt: minutesAgo(20) });
    await store.inbox.record({ id: "evt_running", type: "invoice.paid", payloadHash: "h", objectKey: "sub_1", createdAt: null });
    await store.inbox.claim("evt_running", NOW, new Date(NOW.getTime() + 60_000));

    expect(await replay(NOW)).toEqual({ attempted: 0, succeeded: 0, failed: 0 });
    expect(store.rows.get("evt_legacy")).toMatchObject({ objectKey: "sub_1", processedAt: null, attempts: 0 });
  });

  test("leases each drained event from the time it is claimed", async () => {
    let clock = NOW;
    const { replay, store, enqueue } = replayer({
      clock: () => clock,
      applySubscriptionUpdate: async () => {
        // The first event takes ten minutes.
        clock = new Date(clock.getTime() + 10 * 60_000);
        return { skipped: true };
      },
    });
    await enqueue("evt_a", 20, "sub_a");
    await enqueue("evt_b", 10, "sub_b");
    const leases: number[] = [];
    const claim = store.inbox.claim;
    store.inbox.claim = async (id, now, leaseUntil) => {
      leases.push(leaseUntil.getTime() - NOW.getTime());
      return claim(id, now, leaseUntil);
    };

    await replay(NOW);

    expect(leases).toEqual([15 * 60_000, 25 * 60_000]);
  });

  test("claims nothing while an unkeyed row of the pre-inbox build is held", async () => {
    const { replay, store, enqueue } = replayer({
      applySubscriptionUpdate: async () => ({ scope: "user", stackUserId: "user_1", isActive: true }),
    });
    await enqueue("evt_a", 10, "sub_a");
    await store.inbox.record({ id: "evt_old_build", type: "invoice.paid", payloadHash: "h", objectKey: null, createdAt: null });
    // What the pre-inbox build's insert gets from the column default.
    Object.assign(store.rows.get("evt_old_build")!, { leaseExpiresAt: new Date(NOW.getTime() + 15 * 60_000) });

    expect(await replay(NOW)).toEqual({ attempted: 0, succeeded: 0, failed: 0 });
    expect(store.rows.get("evt_a")?.processedAt).toBeNull();
  });

  test("records an event Stripe no longer serves as a failure for the alert", async () => {
    const { replay, store, enqueue } = replayer({
      applySubscriptionUpdate: async () => ({ scope: "user", stackUserId: "user_1", isActive: true }),
      retrieveEvent: async () => {
        throw new Error("No such event");
      },
    });
    await enqueue("evt_gone", 10);

    expect(await replay(NOW)).toEqual({ attempted: 1, succeeded: 0, failed: 1 });
    expect(store.rows.get("evt_gone")).toMatchObject({ error: "No such event", processedAt: null, leaseExpiresAt: null });
  });
});
