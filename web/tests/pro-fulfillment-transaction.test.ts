import { afterAll, beforeAll, describe, expect, mock, test } from "bun:test";
import type Stripe from "stripe";

process.env.RESEND_API_KEY ??= "test-resend-key";
process.env.CMUX_FEEDBACK_FROM_EMAIL ??= "feedback@example.com";
process.env.CMUX_FEEDBACK_RATE_LIMIT_ID ??= "test-feedback-rate-limit";
process.env.STACK_SECRET_SERVER_KEY ??= "test-stack-secret";
process.env.NEXT_PUBLIC_STACK_PROJECT_ID ??=
  "00000000-0000-4000-8000-000000000000";
process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY ??=
  "test-stack-publishable";

const dbClientModule = await import("../db/client");
const realCloudDb = dbClientModule.cloudDb;
let useStubDb = false;
let transactionDepth = 0;
const sendEmail = mock(async () => {
  expect(transactionDepth).toBe(0);
  return { data: { id: "email_1" }, error: null };
});

const tx = {
  execute: async () => undefined,
  select: () => ({
    from: () => ({
      where: () => ({
        limit: async () => [],
      }),
    }),
  }),
  insert: () => ({
    values: async () => undefined,
  }),
  update: () => ({
    set: () => ({
      where: async () => undefined,
    }),
  }),
  delete: () => ({
    where: async () => undefined,
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
  cloudDb: () => useStubDb ? stubDb : realCloudDb(),
}));

mock.module("resend", () => ({
  Resend: class {
    emails = { send: sendEmail };
  },
}));

const { sendProSignupWelcome } = await import(
  "../services/billing/proFulfillment"
);

beforeAll(() => {
  useStubDb = true;
});

afterAll(() => {
  useStubDb = false;
});

describe("cmux Pro welcome transaction lifecycle", () => {
  test("commits its delivery claim before calling Resend", async () => {
    await sendProSignupWelcome({
      session: {
        id: "cs_transaction_boundary",
        locale: "en",
        customer_details: {
          email: "buyer@example.com",
          name: "Buyer",
        },
      } as Stripe.Checkout.Session,
      stackUserId: "user_transaction_boundary",
    });

    expect(sendEmail).toHaveBeenCalledTimes(1);
  });
});
