import { describe, expect, mock, test } from "bun:test";

import { billingDunningDeliveries } from "../db/schema";
import {
  BillingDunningProviderRejectedError,
  makeBillingDunningDeliveryStore,
  sendBillingDunningEmail,
} from "../services/billing/dunning";

function makeDeliveryLedger() {
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

  return {
    db,
    execute,
    row: () => row,
    updateRow: (values: Record<string, unknown>) => {
      if (!row) throw new Error("delivery claim was not recorded");
      row = { ...row, ...values };
    },
  };
}

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
    const ledger = makeDeliveryLedger();
    const store = makeBillingDunningDeliveryStore(ledger.db as never);
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
    expect(ledger.execute).toHaveBeenCalled();
  });

  test("retries an ambiguous provider outcome and sends exactly one email", async () => {
    const ledger = makeDeliveryLedger();
    const store = makeBillingDunningDeliveryStore(ledger.db as never);
    const providerDeliveries = new Set<string>();
    const sendEmail = mock(async (...args: unknown[]) => {
      const options = args[1] as { readonly idempotencyKey: string };
      if (!providerDeliveries.has(options.idempotencyKey)) {
        providerDeliveries.add(options.idempotencyKey);
        throw new Error("connection reset after provider acceptance");
      }
      return { error: null };
    });
    const input = {
      invoiceId: "in_ambiguous_retry",
      email: "buyer@example.com",
      portalUrl: "https://cmux.test/api/billing/portal",
      scope: { scope: "user" as const, stackUserId: "user_dunning" },
      locale: "en" as const,
    };
    const dependencies = {
      sendEmail: sendEmail as never,
      fromEmail: () => "billing@example.com",
      deliveryStore: store,
    };

    await expect(sendBillingDunningEmail(input, dependencies)).rejects.toThrow(
      "connection reset after provider acceptance",
    );
    const claimedRow = ledger.row();
    if (!claimedRow) throw new Error("delivery claim was not recorded");
    expect(
      (claimedRow.attemptLeaseExpiresAt as Date).getTime() -
        (claimedRow.deliveryStartedAt as Date).getTime(),
    ).toBe(15 * 60 * 1000);

    await expect(sendBillingDunningEmail(input, dependencies)).rejects.toThrow(
      "billing dunning delivery is still in progress",
    );

    ledger.updateRow({ attemptLeaseExpiresAt: new Date(Date.now() - 1) });
    await expect(sendBillingDunningEmail(input, dependencies)).resolves.toBe("sent");
    await expect(sendBillingDunningEmail(input, dependencies)).resolves.toBe(
      "already_sent",
    );

    expect(sendEmail).toHaveBeenCalledTimes(2);
    expect(providerDeliveries.size).toBe(1);
  });

  test("signals an abandoned delivery and never sends it twice", async () => {
    const ledger = makeDeliveryLedger();
    const store = makeBillingDunningDeliveryStore(ledger.db as never);
    const providerDeliveries = new Set<string>();
    const sendEmail = mock(async (...args: unknown[]) => {
      const options = args[1] as { readonly idempotencyKey: string };
      providerDeliveries.add(options.idempotencyKey);
      throw new Error("connection reset after provider acceptance");
    });
    const reportAbandoned = mock(async () => undefined);
    const input = {
      invoiceId: "in_ambiguous_abandoned",
      email: "buyer@example.com",
      portalUrl: "https://cmux.test/api/billing/portal",
      scope: { scope: "team" as const, stackTeamId: "team_dunning" },
      locale: "en" as const,
    };
    const dependencies = {
      sendEmail: sendEmail as never,
      fromEmail: () => "billing@example.com",
      deliveryStore: store,
      reportAbandoned,
    };

    await expect(sendBillingDunningEmail(input, dependencies)).rejects.toThrow(
      "connection reset after provider acceptance",
    );
    ledger.updateRow({
      deliveryStartedAt: new Date(Date.now() - 23 * 60 * 60 * 1000),
      attemptLeaseExpiresAt: new Date(Date.now() - 1),
    });

    await expect(sendBillingDunningEmail(input, dependencies)).resolves.toBe(
      "delivery_abandoned",
    );

    expect(reportAbandoned).toHaveBeenCalledTimes(1);
    expect(reportAbandoned).toHaveBeenCalledWith({
      invoiceId: "in_ambiguous_abandoned",
      scope: { scope: "team", stackTeamId: "team_dunning" },
    });
    expect(sendEmail).toHaveBeenCalledTimes(1);
    expect(providerDeliveries.size).toBe(1);
  });
});
