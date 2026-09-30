import {
  afterAll,
  beforeAll,
  beforeEach,
  describe,
  expect,
  mock,
  test,
} from "bun:test";
import type Stripe from "stripe";

import {
  accountMutationLeases,
  proWelcomeFulfillments,
} from "../db/schema";

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
let accountMutationOperationId: string | null = null;
let fulfillmentRow: Record<string, unknown> | null = null;
const sendEmail = mock(async (): Promise<{
  data: { id: string } | null;
  error: unknown | null;
}> => {
  expect(transactionDepth).toBe(0);
  return { data: { id: "email_1" }, error: null };
});

const tx = {
  execute: async () => undefined,
  select: () => ({
    from: (table: unknown) => ({
      where: () => ({
        limit: async () => {
          if (table === accountMutationLeases && accountMutationOperationId) {
            return [{ operationId: accountMutationOperationId }];
          }
          if (table === proWelcomeFulfillments && fulfillmentRow) {
            return [fulfillmentRow];
          }
          return [];
        },
      }),
    }),
  }),
  insert: (table: unknown) => ({
    values: async (values: unknown) => {
      if (table === accountMutationLeases) {
        accountMutationOperationId = (values as { operationId: string })
          .operationId;
      } else if (table === proWelcomeFulfillments) {
        fulfillmentRow = { ...(values as Record<string, unknown>) };
      }
    },
  }),
  update: (table: unknown) => ({
    set: (values: unknown) => ({
      where: async () => {
        if (table === proWelcomeFulfillments && fulfillmentRow) {
          fulfillmentRow = {
            ...fulfillmentRow,
            ...(values as Record<string, unknown>),
          };
        }
      },
    }),
  }),
  delete: (table: unknown) => ({
    where: async () => {
      if (table === accountMutationLeases) accountMutationOperationId = null;
    },
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

beforeEach(() => {
  transactionDepth = 0;
  accountMutationOperationId = null;
  fulfillmentRow = null;
  sendEmail.mockClear();
  mockImplementation(sendEmail, async () => {
    expect(transactionDepth).toBe(0);
    return { data: { id: "email_1" }, error: null };
  });
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

  test("does not redeliver immediately after an ambiguous provider failure", async () => {
    mockImplementation(sendEmail, async () => {
      expect(transactionDepth).toBe(0);
      throw new Error("connection reset after request write");
    });

    await expect(sendWelcome()).rejects.toThrow(
      "connection reset after request write",
    );
    await expect(sendWelcome()).rejects.toThrow(
      "cmux Pro welcome delivery is still in progress",
    );

    expect(sendEmail).toHaveBeenCalledTimes(1);
  });

  test("retries immediately when the provider explicitly rejects delivery", async () => {
    let attempt = 0;
    mockImplementation(sendEmail, async () => {
      expect(transactionDepth).toBe(0);
      attempt += 1;
      return attempt === 1
        ? { data: null, error: { message: "rejected" } }
        : { data: { id: "email_2" }, error: null };
    });

    await expect(sendWelcome()).rejects.toThrow(
      "cmux Pro welcome email failed: rejected",
    );
    await expect(sendWelcome()).resolves.toBeUndefined();

    expect(sendEmail).toHaveBeenCalledTimes(2);
    expect(fulfillmentRow?.sentAt).toBeInstanceOf(Date);
  });

  test("does not redeliver a welcome already marked sent", async () => {
    await sendWelcome();
    await sendWelcome();

    expect(sendEmail).toHaveBeenCalledTimes(1);
  });
});

async function sendWelcome(): Promise<void> {
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
}

function mockImplementation(
  fn: unknown,
  implementation: (...args: never[]) => unknown,
): void {
  (fn as { mockImplementation(next: typeof implementation): void })
    .mockImplementation(implementation);
}
