import { describe, expect, mock, test } from "bun:test";

import { makeStripeWebhookReplayer } from "../services/billing/stripeWebhook";
import { memoryStripeWebhookInbox } from "./helpers/stripe-webhook-inbox-memory";

const NOW = new Date("2026-10-07T02:00:00.000Z");
const minutesAgo = (minutes: number) => new Date(NOW.getTime() - minutes * 60_000);

function replayer(input: {
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
    now: () => NOW,
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

  test("an effect still running after the lease expires prevents another worker from applying", async () => {
    let release!: () => void;
    let started!: () => void;
    const held = new Promise<void>((resolve) => { release = resolve; });
    const entered = new Promise<void>((resolve) => { started = resolve; });
    let effects = 0;
    const { replay, store, enqueue } = replayer({
      applySubscriptionUpdate: async () => {
        effects += 1;
        started();
        await held;
        return { scope: "user", stackUserId: "user_1", isActive: true };
      },
    });
    await enqueue("evt_slow", 20);
    const running = replay(NOW);
    await entered;
    try {
      const later = new Date(NOW.getTime() + 6 * 60_000);
      expect(await store.inbox.claim("evt_slow", later, new Date(later.getTime() + 60_000))).toBeNull();
      await enqueue("evt_sibling", 10);
      expect(await store.inbox.claim("evt_sibling", later, new Date(later.getTime() + 60_000))).toBeNull();
      expect(effects).toBe(1);
    } finally {
      release();
      await running;
    }
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
