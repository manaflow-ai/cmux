import { describe, expect, mock, test } from "bun:test";

import { makeStripeWebhookReplayer } from "../services/billing/stripeWebhook";

function replayer(input: {
  readonly rows: readonly { id: string }[];
  readonly applySubscriptionUpdate: () => Promise<unknown>;
}) {
  const updates: Record<string, unknown>[] = [];
  const retrieveEvent = mock(async (id: string) => ({
    id,
    type: "customer.subscription.created",
    data: { object: { id: "sub_1" } },
  }));
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
    db: () =>
      ({
        select: () => ({
          from: () => ({
            where: () => ({
              orderBy: () => ({
                limit: () => Promise.resolve(input.rows),
              }),
            }),
          }),
        }),
        update: () => ({
          set: (values: Record<string, unknown>) => ({
            where: () => {
              updates.push(values);
              return Promise.resolve();
            },
          }),
        }),
      }) as never,
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
  return { replay, updates, retrieveEvent };
}

describe("Stripe webhook replay", () => {
  test("replays a failed event from Stripe's record and clears its error", async () => {
    const { replay, updates, retrieveEvent } = replayer({
      rows: [{ id: "evt_failed" }],
      applySubscriptionUpdate: async () => ({ scope: "user", stackUserId: "user_1", isActive: true }),
    });

    const summary = await replay(new Date("2026-10-07T02:00:00.000Z"));

    expect(summary).toEqual({ attempted: 1, succeeded: 1, failed: 0 });
    expect(retrieveEvent).toHaveBeenCalledWith("evt_failed");
    expect(updates.at(-1)).toMatchObject({ error: null });
  });

  test("keeps a still-failing event recorded for the alert", async () => {
    const { replay, updates } = replayer({
      rows: [{ id: "evt_failed" }],
      applySubscriptionUpdate: async () => {
        throw new Error("Stack Auth unavailable");
      },
    });

    const summary = await replay(new Date("2026-10-07T02:00:00.000Z"));

    expect(summary).toEqual({ attempted: 1, succeeded: 0, failed: 1 });
    expect(updates.at(-1)).toEqual({ error: "Stack Auth unavailable" });
  });
});
