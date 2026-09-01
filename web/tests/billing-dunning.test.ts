import { describe, expect, mock, test } from "bun:test";

import { billingDunningDeliveries } from "../db/schema";
import {
  BillingDunningProviderRejectedError,
  makeBillingDunningDeliveryStore,
  sendBillingDunningEmail,
} from "../services/billing/dunning";

describe("billing dunning email", () => {
  test("includes the portal link and sends one message per invoice", async () => {
    const sendEmail = mock(async () => ({ error: null }));
    let delivered = false;
    const deliveryStore = {
      deliverOnce: async (_input: unknown, deliver: () => Promise<void>) => {
        if (delivered) return "already_sent" as const;
        await deliver();
        delivered = true;
        return "sent" as const;
      },
    };

    await expect(
      sendBillingDunningEmail(
        {
          invoiceId: "in_dunning_1",
          email: "buyer@example.com",
          customerName: "Ada Lovelace",
          portalUrl: "https://cmux.test/api/billing/portal",
          scope: { scope: "user", stackUserId: "user_dunning" },
          locale: "en",
        },
        {
          sendEmail: sendEmail as never,
          fromEmail: () => "billing@example.com",
          deliveryStore,
        },
      ),
    ).resolves.toBe("sent");

    await expect(
      sendBillingDunningEmail(
        {
          invoiceId: "in_dunning_1",
          email: "buyer@example.com",
          customerName: "Ada Lovelace",
          portalUrl: "https://cmux.test/api/billing/portal",
          scope: { scope: "user", stackUserId: "user_dunning" },
          locale: "en",
        },
        {
          sendEmail: sendEmail as never,
          fromEmail: () => "billing@example.com",
          deliveryStore,
        },
      ),
    ).resolves.toBe("already_sent");

    expect(sendEmail).toHaveBeenCalledTimes(1);
    const [payload, options] = (sendEmail as unknown as {
      mock: { calls: unknown[][] };
    }).mock.calls[0] as [
      { to: string[]; subject: string; text: string },
      { idempotencyKey: string },
    ];
    expect(payload.to).toEqual(["buyer@example.com"]);
    expect(payload.subject).toContain("payment");
    expect(payload.text).toContain("https://cmux.test/api/billing/portal");
    expect(options).toEqual({ idempotencyKey: "billing-dunning/in_dunning_1" });
  });

  test("does not attempt delivery without a customer email", async () => {
    const sendEmail = mock(async () => ({ error: null }));
    const deliveryStore = {
      deliverOnce: mock(async () => "sent" as const),
    };

    await expect(
      sendBillingDunningEmail(
        {
          invoiceId: "in_without_email",
          email: null,
          portalUrl: "https://cmux.test/api/billing/portal",
          scope: { scope: "user", stackUserId: "user_dunning" },
          locale: "en",
        },
        {
          sendEmail: sendEmail as never,
          deliveryStore,
        },
      ),
    ).resolves.toBe("no_customer_email");

    expect(sendEmail).not.toHaveBeenCalled();
    expect(deliveryStore.deliverOnce).not.toHaveBeenCalled();
  });
});

describe("billing dunning delivery ledger", () => {
  test("releases an explicitly rejected attempt and marks the retry sent", async () => {
    let row: Record<string, unknown> | null = null;
    const execute = mock(async () => undefined);
    const tx = {
      execute,
      select: () => ({
        from: (table: unknown) => ({
          where: () => ({
            limit: async () =>
              table === billingDunningDeliveries && row ? [row] : [],
          }),
        }),
      }),
      insert: () => ({
        values: async (values: Record<string, unknown>) => {
          row = { ...values };
        },
      }),
      update: () => ({
        set: (values: Record<string, unknown>) => ({
          where: async () => {
            row = row ? { ...row, ...values } : row;
          },
        }),
      }),
    };
    const db = {
      transaction: async <T>(operation: (client: typeof tx) => Promise<T>) =>
        await operation(tx),
    };
    const store = makeBillingDunningDeliveryStore(db as never);
    let attempt = 0;

    await expect(
      store.deliverOnce(
        {
          invoiceId: "in_retry",
          email: "buyer@example.com",
          scope: { scope: "user", stackUserId: "user_dunning" },
        },
        async () => {
          attempt += 1;
          throw new BillingDunningProviderRejectedError("rejected");
        },
      ),
    ).rejects.toThrow("rejected");

    await expect(
      store.deliverOnce(
        {
          invoiceId: "in_retry",
          email: "buyer@example.com",
          scope: { scope: "user", stackUserId: "user_dunning" },
        },
        async () => {
          attempt += 1;
        },
      ),
    ).resolves.toBe("sent");

    await expect(
      store.deliverOnce(
        {
          invoiceId: "in_retry",
          email: "buyer@example.com",
          scope: { scope: "user", stackUserId: "user_dunning" },
        },
        async () => {
          attempt += 1;
        },
      ),
    ).resolves.toBe("already_sent");

    expect(attempt).toBe(2);
    expect(execute).toHaveBeenCalled();
  });
});
