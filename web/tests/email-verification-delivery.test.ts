import {
  afterAll,
  beforeAll,
  beforeEach,
  describe,
  expect,
  mock,
  test,
} from "bun:test";

import { billingEmailVerificationDeliveries } from "../db/schema";

const dbClientModule = await import("../db/client");
const realCloudDb = dbClientModule.cloudDb;
let useStubDb = false;
let transactionDepth = 0;
let deliveryRow: Record<string, unknown> | null = null;

const tx = {
  execute: async () => undefined,
  select: () => ({
    from: (table: unknown) => ({
      where: () => ({
        limit: async () =>
          table === billingEmailVerificationDeliveries && deliveryRow
            ? [deliveryRow]
            : [],
      }),
    }),
  }),
  insert: (table: unknown) => ({
    values: async (values: unknown) => {
      if (table === billingEmailVerificationDeliveries) {
        deliveryRow = { ...(values as Record<string, unknown>) };
      }
    },
  }),
  update: (table: unknown) => ({
    set: (values: unknown) => ({
      where: async () => {
        if (table === billingEmailVerificationDeliveries && deliveryRow) {
          deliveryRow = {
            ...deliveryRow,
            ...(values as Record<string, unknown>),
          };
        }
      },
    }),
  }),
};

const stubDb = {
  transaction: async <T>(operation: (client: typeof tx) => Promise<T>) => {
    transactionDepth += 1;
    try {
      return await operation(tx);
    } finally {
      transactionDepth -= 1;
    }
  },
};

mock.module("../db/client", () => ({
  ...dbClientModule,
  cloudDb: () => (useStubDb ? stubDb : realCloudDb()),
}));

const {
  makePurchaseMagicLinkDeliveryStore,
  PurchaseMagicLinkProviderRejectedError,
} = await import(
  "../services/billing/emailVerificationDelivery"
);

beforeAll(() => {
  useStubDb = true;
});

afterAll(() => {
  useStubDb = false;
});

beforeEach(() => {
  transactionDepth = 0;
  deliveryRow = null;
});

describe("purchase magic-link delivery", () => {
  test("commits the delivery claim before sending and deduplicates repeats", async () => {
    const send = mock(async () => {
      expect(transactionDepth).toBe(0);
    });
    const store = makePurchaseMagicLinkDeliveryStore(stubDb as never);
    const input = {
      checkoutSessionId: "cs_magic_link",
      stackUserId: "user_magic_link",
      email: "buyer@example.com",
    };

    await expect(store.deliverOnce(input, send)).resolves.toBe("sent");
    await expect(store.deliverOnce(input, send)).resolves.toBe("already_sent");

    expect(send).toHaveBeenCalledTimes(1);
    expect(deliveryRow?.sentAt).toBeInstanceOf(Date);
  });

  test("keeps an ambiguous provider attempt leased instead of sending twice", async () => {
    const send = mock(async () => {
      expect(transactionDepth).toBe(0);
      throw new Error("connection reset after request write");
    });
    const store = makePurchaseMagicLinkDeliveryStore(stubDb as never);
    const input = {
      checkoutSessionId: "cs_magic_link_ambiguous",
      stackUserId: "user_magic_link",
      email: "buyer@example.com",
    };

    await expect(store.deliverOnce(input, send)).rejects.toThrow(
      "connection reset after request write",
    );
    if (!deliveryRow) throw new Error("delivery claim was not recorded");
    deliveryRow.attemptLeaseExpiresAt = new Date(Date.now() - 1);
    await expect(store.deliverOnce(input, send)).resolves.toBe(
      "delivery_in_progress",
    );
    expect(send).toHaveBeenCalledTimes(1);
  });

  test("releases the claim after a definitive provider rejection", async () => {
    let attempts = 0;
    const send = mock(async () => {
      attempts += 1;
      if (attempts === 1) {
        throw new PurchaseMagicLinkProviderRejectedError("rejected");
      }
    });
    const store = makePurchaseMagicLinkDeliveryStore(stubDb as never);
    const input = {
      checkoutSessionId: "cs_magic_link_rejected",
      stackUserId: "user_magic_link",
      email: "buyer@example.com",
    };

    await expect(store.deliverOnce(input, send)).rejects.toThrow("rejected");
    await expect(store.deliverOnce(input, send)).resolves.toBe("sent");
    expect(send).toHaveBeenCalledTimes(2);
    expect(deliveryRow?.sentAt).toBeInstanceOf(Date);
  });
});
