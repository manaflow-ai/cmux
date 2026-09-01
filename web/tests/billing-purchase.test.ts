import { beforeEach, describe, expect, mock, test } from "bun:test";

import {
  accountDeletionTombstones,
  accountMutationLeases,
  billingEmailClaims,
  stripeCustomers,
  stripeSubscriptions,
} from "../db/schema";
import { FOUNDER_TESTFLIGHT_GROUP_ID } from "../services/asc/testflightOwnership";

process.env.RESEND_API_KEY ??= "test-resend-key";
process.env.CMUX_FEEDBACK_FROM_EMAIL ??= "feedback@example.com";
process.env.CMUX_FEEDBACK_RATE_LIMIT_ID ??= "test-feedback-rate-limit";
process.env.STACK_SECRET_SERVER_KEY ??= "test-stack-secret";
process.env.NEXT_PUBLIC_STACK_PROJECT_ID ??= "00000000-0000-4000-8000-000000000000";
process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY ??= "test-stack-publishable";

const {
  applySubscriptionUpdate,
  canonicalizeEmailForMatching,
  findBillingUserByEmail,
  findUserIdByEmail,
  isCmuxCheckoutSession,
  isActiveStripeSubscriptionStatus,
  latestStripeSubscriptionForSession,
  recordCheckoutCompletion,
  recordFoundersCheckoutCompletion,
  recordProCheckoutCompletionByEmail,
} = await import(
  "../services/billing/purchase"
);

const inserts: Array<{ table: unknown; values: Record<string, unknown> }> = [];
const updates: Array<{ table: unknown; values: Record<string, unknown> }> = [];
const upsertUpdates: Array<{ table: unknown; values: Record<string, unknown> }> = [];
const insertErrorsByTable = new Map<unknown, unknown>();
let selectResults: unknown[][] = [];
let tombstoneSelectResults: unknown[][] = [];
let accountMutationOperationId: string | null = null;

function fakeDb() {
  const client = {
    insert: (table: unknown) => ({
      values: (values: Record<string, unknown>) => {
        if (table === accountMutationLeases) {
          accountMutationOperationId = values.operationId as string;
        } else {
          inserts.push({ table, values });
        }
        return {
          onConflictDoUpdate: (options?: { set?: Record<string, unknown> }) => {
            upsertUpdates.push({ table, values: options?.set ?? {} });
            const error = insertErrorsByTable.get(table);
            if (error) return Promise.reject(error);
            return Promise.resolve();
          },
          then: (resolve: (value: unknown) => void) => resolve(undefined),
        };
      },
    }),
    select: () => ({
      from: (table: unknown) => ({
        where: () => {
          if (table === accountDeletionTombstones) {
            return tombstoneSelectableResult();
          }
          if (table === accountMutationLeases) {
            return accountMutationLeaseSelectableResult();
          }
          return selectableResult();
        },
      }),
    }),
    update: (table: unknown) => ({
      set: (values: Record<string, unknown>) => ({
        where: () => {
          if (table !== accountMutationLeases) {
            updates.push({ table, values });
          }
          return Promise.resolve();
        },
      }),
    }),
    delete: (table: unknown) => ({
      where: async () => {
        if (table === accountMutationLeases) {
          accountMutationOperationId = null;
        }
      },
    }),
  };
  return {
    ...client,
    execute: async (_query?: unknown) => {
      void _query;
    },
    transaction: async <T>(
      callback: (tx: typeof client & { execute: (_query?: unknown) => Promise<void> }) => Promise<T>,
    ) => await callback({
      ...client,
      execute: async (_query?: unknown) => {
        void _query;
      },
    }),
  };
}

function selectableResult() {
  return {
    orderBy: () => selectableResult(),
    limit: () => Promise.resolve(selectResults.shift() ?? []),
  };
}

function tombstoneSelectableResult() {
  return {
    orderBy: () => tombstoneSelectableResult(),
    limit: () => Promise.resolve(tombstoneSelectResults.shift() ?? []),
  };
}

function accountMutationLeaseSelectableResult() {
  return {
    orderBy: () => accountMutationLeaseSelectableResult(),
    limit: () => Promise.resolve(
      accountMutationOperationId
        ? [{ operationId: accountMutationOperationId }]
        : [],
    ),
  };
}

function checkoutInput(customerId = "cus_123") {
  return {
    session: {
      id: "cs_123",
      client_reference_id: "user_123",
      customer: customerId,
      customer_details: { email: "Buyer@Example.com" },
      subscription: "sub_123",
    },
    subscription: {
      id: "sub_123",
      customer: customerId,
      status: "active",
      metadata: { stackUserId: "user_123", app: "cmux" },
      cancel_at_period_end: false,
      items: {
        data: [
          {
            current_period_end: 1_800_000_000,
            price: { id: "price_123" },
          },
        ],
      },
    },
    customer: {
      id: customerId,
      deleted: false,
      email: "Buyer@Example.com",
    },
  };
}

function teamCheckoutInput(customerId = "cus_team", stackUserId?: string) {
  const metadata = {
    stackTeamId: "team_123",
    plan: "team",
    app: "cmux",
    ...(stackUserId ? { stackUserId } : {}),
  };
  return {
    session: {
      id: "cs_team",
      client_reference_id: "team_123",
      customer: customerId,
      customer_details: { email: "buyer@example.com" },
      subscription: "sub_team",
      metadata,
    },
    subscription: {
      id: "sub_team",
      customer: customerId,
      status: "active",
      metadata,
      cancel_at_period_end: false,
      items: {
        data: [
          {
            quantity: 4,
            current_period_end: 1_800_000_000,
            price: { id: "price_team" },
          },
        ],
      },
    },
    customer: {
      id: customerId,
      deleted: false,
      email: "buyer@example.com",
    },
  };
}

describe("Stripe subscription entitlement states", () => {
  for (const status of ["active", "trialing", "past_due"]) {
    test(`${status} retains Pro access`, () => {
      expect(isActiveStripeSubscriptionStatus(status)).toBe(true);
    });
  }

  for (const status of [
    "canceled",
    "incomplete",
    "incomplete_expired",
    "paused",
    "unpaid",
  ]) {
    test(`${status} revokes Pro access`, () => {
      expect(isActiveStripeSubscriptionStatus(status)).toBe(false);
    });
  }
});

describe("billing email matching", () => {
  test("canonicalizes Gmail dots but preserves plus tags", () => {
    expect(canonicalizeEmailForMatching(" Billing.Fi.Xture@GMAIL.COM ")).toBe(
      "billingfixture@gmail.com",
    );
    expect(canonicalizeEmailForMatching("billing.fixture+tag@gmail.com")).toBe(
      "billingfixture+tag@gmail.com",
    );
    expect(canonicalizeEmailForMatching("b.illing+tag.one@gmail.com")).toBe(
      "billing+tag.one@gmail.com",
    );
    expect(canonicalizeEmailForMatching("A.l.i.a.s@googlemail.com")).toBe(
      "alias@gmail.com",
    );
    expect(canonicalizeEmailForMatching(" User@Example.com ")).toBe(
      "user@example.com",
    );
    expect(canonicalizeEmailForMatching("a.b@outlook.com")).toBe(
      "a.b@outlook.com",
    );
  });

  test("recognizes Founder's Edition sessions as cmux checkouts", () => {
    expect(
      isCmuxCheckoutSession({
        client_reference_id: null,
        metadata: { founders_edition: "true" },
      }),
    ).toBe(true);
  });

  test("does not let a cmux subscription override a foreign session marker", () => {
    expect(
      isCmuxCheckoutSession(
        {
          client_reference_id: "foreign-user",
          metadata: { app: "other", plan: "pro" },
        },
        { metadata: { app: "cmux", plan: "pro" } },
      ),
    ).toBe(false);
  });

  test("does not let Founder metadata override a foreign session marker", () => {
    expect(
      isCmuxCheckoutSession(
        {
          client_reference_id: "foreign-user",
          metadata: { app: "other", founders_edition: "true" },
        },
        { metadata: { app: "cmux", founders_edition: "true" } },
      ),
    ).toBe(false);
  });

  test("chooses the undotted Gmail account when a duplicate alias exists", async () => {
    const undotted = {
      id: "real",
      primaryEmail: "billingfixture@gmail.com",
      primaryEmailVerified: true,
      update: mock(async () => undefined),
    };
    const dotted = {
      id: "duplicate",
      primaryEmail: "billing.fixture@gmail.com",
      primaryEmailVerified: false,
      update: mock(async () => undefined),
    };
    const getUser = mock(async (...args: unknown[]) => {
      const id = args[0] as string;
      return id === "real" ? undotted : dotted;
    });
    const user = await findBillingUserByEmail(
      {
        listUsers: async () => [dotted, undotted],
        getUser,
      } as never,
      "billing.fixture@gmail.com",
    );
    expect(user?.id).toBe("real");
    expect(getUser).not.toHaveBeenCalled();
  });

  test("checks every Gmail spelling before choosing a verified owner", async () => {
    const unverified = {
      id: "unverified-canonical",
      primaryEmail: "billingfixture@gmail.com",
      primaryEmailVerified: false,
      isAnonymous: false,
      isRestricted: true,
    };
    const verified = {
      id: "verified-dotted",
      primaryEmail: "billing.fixture@gmail.com",
      primaryEmailVerified: true,
      isAnonymous: false,
      isRestricted: false,
    };
    const listUsers = mock(async (...args: unknown[]) => {
      const query = (args[0] as { query?: string }).query;
      if (query === "billingfixture@gmail.com") return [unverified];
      if (query === "billing.fixture@gmail.com") return [verified];
      return [];
    });
    const getUser = mock(async (...args: unknown[]) =>
      (args[0] as string) === verified.id ? verified : unverified,
    );

    const user = await findBillingUserByEmail(
      { listUsers, getUser } as never,
      "billing.fixture@gmail.com",
    );

    expect(user?.id).toBe(verified.id);
    expect(listUsers).toHaveBeenCalledWith({
      query: "billing.fixture@gmail.com",
      limit: 20,
      includeAnonymous: true,
      includeRestricted: true,
    });
  });

  test("finds a dotted Gmail account through the paginated canonical fallback", async () => {
    const dotted = {
      id: "dotted-only",
      primaryEmail: "billing.fixture@gmail.com",
      primaryEmailVerified: true,
      update: mock(async () => undefined),
    };
    const listUsers = mock(async (...args: unknown[]) => {
      const options = (args[0] ?? {}) as { query?: string };
      return options.query ? [] : [dotted];
    });

    const user = await findBillingUserByEmail(
      { listUsers, getUser: async () => dotted } as never,
      "billingfixture@gmail.com",
    );

    expect(user?.id).toBe("dotted-only");
    expect(listUsers).toHaveBeenCalledWith({
      limit: 100,
      includeAnonymous: true,
      includeRestricted: true,
    });
  });

  test("uses the same canonical fallback when checking email ownership", async () => {
    const listUsers = mock(async (...args: unknown[]) => {
      const options = (args[0] ?? {}) as { query?: string };
      return options.query
        ? []
        : [{ id: "dotted-owner", primaryEmail: "billing.fixture@gmail.com" }];
    });

    await expect(
      findUserIdByEmail(
        { listUsers } as never,
        "billingfixture@gmail.com",
      ),
    ).resolves.toBe("dotted-owner");
  });
});

describe("Founder success read-back", () => {
  beforeEach(() => {
    selectResults = [];
  });

  test("reads a synthetic Founder entitlement by Stripe customer when no subscription id exists", async () => {
    const row = {
      id: "founders_cs_fixture",
      status: "active",
      raw: { metadata: { founders_edition: "true" } },
    };
    selectResults = [[row]];

    await expect(
      latestStripeSubscriptionForSession(
        {
          id: "cs_fixture",
          customer: "cus_fixture",
          subscription: null,
          metadata: { founders_edition: "true" },
        } as never,
        fakeDb() as never,
      ),
    ).resolves.toEqual(row);
  });

  test("does not use customer fallback for a non-Founder checkout without a subscription id", async () => {
    const unrelatedRow = { id: "sub_pro", status: "active" };
    selectResults = [[unrelatedRow]];

    await expect(
      latestStripeSubscriptionForSession(
        {
          id: "cs_pro_fixture",
          customer: "cus_fixture",
          subscription: null,
          metadata: { app: "cmux", plan: "pro" },
        } as never,
        fakeDb() as never,
      ),
    ).resolves.toBeNull();
    expect(selectResults).toEqual([[unrelatedRow]]);
  });

  test("selects only a Founder-marked row from a customer with multiple Pro purchases", async () => {
    const unrelatedRow = {
      id: "sub_pro",
      status: "active",
      raw: { metadata: { app: "cmux", plan: "pro" } },
    };
    const founderRow = {
      id: "founders_cs_fixture",
      status: "active",
      raw: { metadata: { founders_edition: "true" } },
    };
    selectResults = [[unrelatedRow, founderRow]];

    await expect(
      latestStripeSubscriptionForSession(
        {
          id: "cs_fixture",
          customer: "cus_fixture",
          subscription: null,
          metadata: { founders_edition: "true" },
        } as never,
        fakeDb() as never,
      ),
    ).resolves.toEqual(founderRow);
  });

  test("does not substitute a different customer subscription for a known id", async () => {
    const unrelatedRow = {
      id: "sub_other",
      customerId: "cus_fixture",
      status: "canceled",
    };
    selectResults = [[], [unrelatedRow]];

    await expect(
      latestStripeSubscriptionForSession(
        {
          id: "cs_fixture",
          customer: "cus_fixture",
          subscription: "sub_missing",
        } as never,
        fakeDb() as never,
      ),
    ).resolves.toBeNull();
  });
});

describe("recordFoundersCheckoutCompletion", () => {
  beforeEach(() => {
    inserts.length = 0;
    updates.length = 0;
    upsertUpdates.length = 0;
    insertErrorsByTable.clear();
    selectResults = [];
    tombstoneSelectResults = [];
    accountMutationOperationId = null;
  });

  test("finds and parks a Founder buyer until mailbox verification", async () => {
    const update = mock(async () => undefined);
    const sendMagicLinkEmail = mock(async () => undefined);
    const user = {
      id: "founder_1",
      primaryEmail: null,
      primaryEmailVerified: false,
      clientReadOnlyMetadata: {},
      update,
    };
    const createUser = mock(async () => user);
    const listUsers = mock(async () => []);
    const enroll = mock(async () => undefined);
    // tombstone, customer ownership, existing customer, lease reads/writes
    selectResults = [[], [], [], [], [], [], []];

    const result = await recordFoundersCheckoutCompletion(
      {
        session: {
          id: "cs_founder",
          customer: "cus_founder",
          customer_details: {
            email: "Buyer@Example.com",
            name: "Sample Buyer",
          },
          metadata: { founders_edition: "true" },
          subscription: "sub_founder",
        } as never,
        subscription: {
          id: "sub_founder",
          customer: "cus_founder",
          status: "active",
          metadata: { founders_edition: "true" },
          cancel_at_period_end: false,
          items: { data: [{ price: { id: "price_founder" } }] },
        } as never,
        customer: {
          id: "cus_founder",
          deleted: false,
          email: "Buyer@Example.com",
        } as never,
      },
      {
        db: fakeDb() as never,
        stackApp: {
          getUser: async () => user,
          listUsers,
          createUser,
          sendMagicLinkEmail,
        } as never,
        testflight: { enrollTester: enroll },
      },
    );

    expect(result).toEqual({
      scope: "user",
      stackUserId: "founder_1",
      subscriptionId: "sub_founder",
    });
    expect(createUser).toHaveBeenCalledWith({
      primaryEmail: "buyer@example.com",
      primaryEmailAuthEnabled: true,
      primaryEmailVerified: false,
    });
    expect(
      inserts.some(
        (entry) =>
          entry.table === stripeCustomers &&
          entry.values.email === "Buyer@Example.com" &&
          entry.values.stackUserId === "founder_1",
      ),
    ).toBe(true);
    expect(
      inserts.some(
        (entry) =>
          entry.table === stripeSubscriptions &&
          entry.values.plan === "pro" &&
          entry.values.scope === "user",
      ),
    ).toBe(true);
    expect(update).toHaveBeenCalledWith({
      primaryEmail: "buyer@example.com",
      primaryEmailAuthEnabled: true,
      primaryEmailVerified: false,
    });
    expect(update).not.toHaveBeenCalledWith({ primaryEmailVerified: true });
    expect(sendMagicLinkEmail).toHaveBeenCalledWith("buyer@example.com", {
      callbackUrl: "https://cmux.com/handler/after-sign-in",
    });
    expect(
      inserts.some(
        (entry) =>
          entry.table === billingEmailClaims &&
          entry.values.email === "buyer@example.com" &&
          entry.values.stackUserId === "founder_1",
      ),
    ).toBe(true);
    expect(update).not.toHaveBeenCalledWith({
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
    });
    expect(enroll).not.toHaveBeenCalled();
  });

  test("does not verify an existing Founder account from payment email alone", async () => {
    const update = mock(async () => undefined);
    const setPrimaryEmail = mock(async () => undefined);
    const sendMagicLinkEmail = mock(async () => undefined);
    const user = {
      id: "founder_existing",
      primaryEmail: "Billing.Fixture@gmail.com",
      primaryEmailVerified: false,
      primaryEmailAuthEnabled: true,
      clientReadOnlyMetadata: {},
      update,
      setPrimaryEmail,
    };
    selectResults = Array.from({ length: 20 }, () => []);

    await recordFoundersCheckoutCompletion(
      {
        session: {
          id: "cs_existing",
          customer: "cus_existing",
          customer_details: {
            email: "billing.fixture@gmail.com",
          },
          metadata: { founders_edition: "true" },
          subscription: "sub_existing",
        } as never,
        subscription: {
          id: "sub_existing",
          customer: "cus_existing",
          status: "active",
          metadata: { founders_edition: "true" },
          cancel_at_period_end: false,
          items: { data: [] },
        } as never,
        customer: {
          id: "cus_existing",
          deleted: false,
          email: "billing.fixture@gmail.com",
        } as never,
      },
      {
        db: fakeDb() as never,
        stackApp: {
          getUser: async () => user,
          listUsers: async () => [
            {
              id: user.id,
              primaryEmail: user.primaryEmail,
              primaryEmailVerified: false,
              primaryEmailAuthEnabled: true,
              update,
              setPrimaryEmail,
            },
          ],
          sendMagicLinkEmail,
        } as never,
      },
    );

    expect(setPrimaryEmail).not.toHaveBeenCalled();
    expect(update).not.toHaveBeenCalledWith({
      primaryEmail: "billing.fixture@gmail.com",
      primaryEmailAuthEnabled: true,
    });
    expect(sendMagicLinkEmail).toHaveBeenCalledWith("billing.fixture@gmail.com", {
      callbackUrl: "https://cmux.com/handler/after-sign-in",
    });
  });

  test("does not verify an existing Founder account before the deletion guard", async () => {
    const update = mock(async () => undefined);
    const createUser = mock(async () => {
      throw new Error("must not create while deleting");
    });
    const user = {
      id: "founder_deleting",
      primaryEmail: "buyer@example.com",
      primaryEmailVerified: false,
      primaryEmailAuthEnabled: true,
      isAnonymous: false,
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
      update,
    };
    selectResults = Array.from({ length: 20 }, () => []);

    const result = await recordFoundersCheckoutCompletion(
      {
        session: {
          id: "cs_deleting",
          customer: "cus_deleting",
          customer_details: { email: "buyer@example.com" },
          metadata: { founders_edition: "true" },
          subscription: "sub_deleting",
        } as never,
        subscription: {
          id: "sub_deleting",
          customer: "cus_deleting",
          status: "active",
          metadata: { founders_edition: "true" },
          cancel_at_period_end: false,
          items: { data: [] },
        } as never,
        customer: {
          id: "cus_deleting",
          deleted: false,
          email: "buyer@example.com",
        } as never,
      },
      {
        db: fakeDb() as never,
        stackApp: {
          getUser: async () => user,
          listUsers: async () => [user],
          createUser,
        } as never,
      },
    );

    expect(result).toEqual({
      skipped: "account_deletion_in_progress",
      stackUserId: "founder_deleting",
      subscriptionId: "sub_deleting",
    });
    expect(update).not.toHaveBeenCalled();
    expect(createUser).not.toHaveBeenCalled();
    expect(inserts).toHaveLength(0);
  });

  test("does not recreate a deleted Founder account from a replayed checkout", async () => {
    const createUser = mock(async () => {
      throw new Error("must not recreate a deleted account");
    });
    // The first row guards the synthetic email lease. The second row is the
    // tombstone for the Stack id retained in the Stripe checkout metadata.
    tombstoneSelectResults = [
      [],
      [{ status: "completed", updatedAt: new Date() }],
    ];

    await expect(
      recordFoundersCheckoutCompletion(
        {
          session: {
            id: "cs_deleted_replay",
            customer: "cus_deleted_replay",
            customer_details: { email: "deleted@example.com" },
            client_reference_id: "deleted_stack_user",
            metadata: {
              founders_edition: "true",
              stackUserId: "deleted_stack_user",
            },
            subscription: "sub_deleted_replay",
          } as never,
          subscription: {
            id: "sub_deleted_replay",
            customer: "cus_deleted_replay",
            status: "active",
            metadata: {
              founders_edition: "true",
              stackUserId: "deleted_stack_user",
            },
            cancel_at_period_end: false,
            items: { data: [] },
          } as never,
          customer: {
            id: "cus_deleted_replay",
            deleted: false,
            email: "deleted@example.com",
          } as never,
        },
        {
          db: fakeDb() as never,
          stackApp: {
            getUser: async () => null,
            listUsers: async () => [],
            createUser,
          } as never,
        },
      ),
    ).rejects.toThrow("account deletion");
    expect(createUser).not.toHaveBeenCalled();
    expect(inserts).toHaveLength(0);
  });

  test("checks a mapped Stripe owner before creating a Founder account", async () => {
    const createUser = mock(async () => {
      throw new Error("must not recreate a mapped deleted account");
    });
    const deletedOwnerID = "deleted_founder_owner";
    // The durable Stripe customer owner is read before the Stack email lookup.
    selectResults = [[{ stackUserId: deletedOwnerID, stackTeamId: null }]];
    tombstoneSelectResults = [[{ status: "completed", updatedAt: new Date() }]];

    const result = await recordFoundersCheckoutCompletion(
      {
        session: {
          id: "cs_mapped_deleted_replay",
          customer: "cus_mapped_deleted_replay",
          customer_details: { email: "deleted-mapped@example.com" },
          metadata: { founders_edition: "true" },
          subscription: "sub_mapped_deleted_replay",
        } as never,
        subscription: {
          id: "sub_mapped_deleted_replay",
          customer: "cus_mapped_deleted_replay",
          status: "active",
          metadata: { founders_edition: "true" },
          cancel_at_period_end: false,
          items: { data: [] },
        } as never,
        customer: {
          id: "cus_mapped_deleted_replay",
          deleted: false,
          email: "deleted-mapped@example.com",
        } as never,
      },
      {
        db: fakeDb() as never,
        stackApp: {
          getUser: async () => null,
          listUsers: async () => [],
          createUser,
        } as never,
      },
    );

    expect(result).toEqual({
      skipped: "account_deletion_in_progress",
      stackUserId: deletedOwnerID,
      subscriptionId: "sub_mapped_deleted_replay",
    });
    expect(createUser).not.toHaveBeenCalled();
    expect(inserts).toHaveLength(0);
  });

  test("skips a Founder session without an email before Stack mutation", async () => {
    const createUser = mock(async () => {
      throw new Error("must not create");
    });
    const result = await recordFoundersCheckoutCompletion(
      {
        session: {
          id: "cs_no_email",
          customer: "cus_no_email",
          customer_details: null,
          metadata: { founders_edition: "true" },
          subscription: "sub_no_email",
        } as never,
        subscription: {
          id: "sub_no_email",
          customer: "cus_no_email",
          status: "active",
          metadata: { founders_edition: "true" },
          cancel_at_period_end: false,
          items: { data: [] },
        } as never,
      },
      { db: fakeDb() as never, stackApp: { getUser: async () => null, listUsers: async () => [], createUser } as never },
    );
    expect(result).toEqual({ skipped: "no_customer_email", subscriptionId: "sub_no_email" });
    expect(createUser).not.toHaveBeenCalled();
  });

  test("skips a Founder session without an email even when Stripe has no customer id", async () => {
    const result = await recordFoundersCheckoutCompletion(
      {
        session: {
          id: "cs_no_email_customer",
          customer: null,
          customer_details: null,
          metadata: { founders_edition: "true" },
          subscription: null,
        } as never,
        customer: null,
      },
      { db: fakeDb() as never, stackApp: { listUsers: async () => [] } as never },
    );

    expect(result).toEqual({
      skipped: "no_customer_email",
      subscriptionId: "founders_cs_no_email_customer",
    });
  });

  test("replays a Founder checkout idempotently", async () => {
    const update = mock(async () => undefined);
    const user = {
      id: "founder_replay",
      primaryEmail: "replay@example.com",
      primaryEmailVerified: true,
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
      update,
    };
    const listUsers = mock(async () => [
      {
        id: user.id,
        primaryEmail: user.primaryEmail,
        primaryEmailVerified: true,
      },
    ]);
    const enroll = mock(async () => undefined);
    const input = {
      session: {
        id: "cs_replay",
        customer: "cus_replay",
        customer_details: { email: "replay@example.com", name: "Replay Buyer" },
        metadata: { founders_edition: "true" },
        subscription: "sub_replay",
      },
      subscription: {
        id: "sub_replay",
        customer: "cus_replay",
        status: "active",
        metadata: { founders_edition: "true" },
        cancel_at_period_end: false,
        items: { data: [] },
      },
      customer: { id: "cus_replay", deleted: false, email: "replay@example.com" },
    } as never;
    const stackApp = { getUser: async () => user, listUsers };

    selectResults = Array.from({ length: 20 }, () => []);
    await recordFoundersCheckoutCompletion(input, {
      db: fakeDb() as never,
      stackApp: stackApp as never,
      testflight: { enrollTester: enroll },
    });
    selectResults = Array.from({ length: 20 }, () => []);
    await recordFoundersCheckoutCompletion(input, {
      db: fakeDb() as never,
      stackApp: stackApp as never,
      testflight: { enrollTester: enroll },
    });

    expect(listUsers).toHaveBeenCalledTimes(2);
    expect(enroll).toHaveBeenCalledTimes(2);
    expect(inserts.filter((entry) => entry.table === stripeSubscriptions)).toHaveLength(2);
  });

  test("keeps a paid Founder entitlement active when provider history is canceled", async () => {
    const user = {
      id: "founder_history",
      primaryEmail: "history@example.com",
      primaryEmailVerified: true,
      clientReadOnlyMetadata: {},
      update: mock(async () => undefined),
    };
    selectResults = Array.from({ length: 20 }, () => []);
    await recordFoundersCheckoutCompletion(
      {
        session: {
          id: "cs_history",
          customer: "cus_history",
          customer_details: { email: "history@example.com" },
          metadata: { founders_edition: "true" },
          subscription: "sub_history",
        } as never,
        subscription: {
          id: "sub_history",
          customer: "cus_history",
          status: "canceled",
          metadata: { founders_edition: "true" },
          cancel_at_period_end: false,
          items: { data: [] },
        } as never,
        customer: { id: "cus_history", deleted: false, email: "history@example.com" } as never,
      },
      {
        db: fakeDb() as never,
        stackApp: {
          getUser: async () => user,
          listUsers: async () => [{ id: user.id, primaryEmail: user.primaryEmail, primaryEmailVerified: true }],
        } as never,
      },
    );
    const subscriptionInsert = inserts.find((entry) => entry.table === stripeSubscriptions);
    expect(subscriptionInsert?.values.status).toBe("active");
  });

  test("preserves a locally marked Founder entitlement on an unmarked event", async () => {
    const update = mock(async () => undefined);
    const user = {
      id: "user_123",
      primaryEmail: "founder@example.com",
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
      update,
    };
    selectResults = [
      [{ stackUserId: "user_123" }],
      [{
        id: "sub_user",
        raw: { metadata: { founders_edition: "true" } },
      }],
    ];

    const result = await applySubscriptionUpdate(
      userSubscriptionUpdate({ status: "canceled" }) as never,
      {
        db: fakeDb() as never,
        stackApp: { getUser: async () => user } as never,
      },
    );

    expect(result).toEqual({ skipped: true });
    expect(inserts).toHaveLength(0);
    expect(updates).toHaveLength(0);
    expect(update).not.toHaveBeenCalled();
  });

  test("does not let a later Founder subscription webhook revoke the entitlement", async () => {
    const result = await applySubscriptionUpdate(
      {
        id: "sub_founder_webhook",
        customer: "cus_founder_webhook",
        status: "canceled",
        metadata: {
          founders_edition: "true",
          app: "cmux",
          plan: "pro",
          stackUserId: "founder_webhook",
        },
      } as never,
      { db: fakeDb() as never },
    );

    expect(result).toEqual({ skipped: true });
    expect(inserts).toHaveLength(0);
    expect(updates).toHaveLength(0);
  });

  test("routes a dotted Gmail purchase to the existing undotted account", async () => {
    const anonymous = {
      id: "anonymous_purchase",
      isAnonymous: true,
      primaryEmail: null,
      clientReadOnlyMetadata: {},
      update: mock(async () => undefined),
    };
    const real = {
      id: "alias_real",
      isAnonymous: false,
      primaryEmail: "billingfixture@gmail.com",
      primaryEmailVerified: true,
      clientReadOnlyMetadata: {},
      update: mock(async () => undefined),
    };
    const listUsers = mock(async () => [
      {
        id: real.id,
        primaryEmail: real.primaryEmail,
        primaryEmailVerified: false,
        isAnonymous: false,
      },
    ]);
    const getUser = mock(async (...args: unknown[]) => {
      const id = args[0] as string;
      return id === anonymous.id ? anonymous : real;
    });
    // The first select is the normal customer's existing-row lookup. Keep all
    // subsequent account-mutation lease reads empty.
    selectResults = [[], [], [], [], [], [], [], []];

    const result = await recordCheckoutCompletion(
      {
        session: {
          id: "cs_alias",
          client_reference_id: anonymous.id,
          customer: "cus_alias",
          customer_details: { email: "billing.fixture@gmail.com" },
          subscription: "sub_alias",
          metadata: { app: "cmux", plan: "pro" },
        } as never,
        subscription: {
          id: "sub_alias",
          customer: "cus_alias",
          status: "active",
          metadata: { app: "cmux", plan: "pro", stackUserId: anonymous.id },
          cancel_at_period_end: false,
          items: { data: [{ price: { id: "price_pro" } }] },
        } as never,
        customer: {
          id: "cus_alias",
          deleted: false,
          email: "billing.fixture@gmail.com",
        } as never,
      },
      {
        db: fakeDb() as never,
        stackApp: { getUser, listUsers } as never,
      },
    );

    expect(result).toEqual({
      scope: "user",
      stackUserId: real.id,
      subscriptionId: "sub_alias",
    });
    expect(
      inserts.some(
        (entry) =>
          entry.table === stripeSubscriptions &&
          entry.values.stackUserId === real.id,
      ),
    ).toBe(true);
    expect(inserts.some((entry) => entry.table === billingEmailClaims)).toBe(false);
    expect(real.update).not.toHaveBeenCalledWith({ primaryEmailVerified: true });
  });

  test("moves an already-parked alias customer without leaving a claim", async () => {
    const anonymous = {
      id: "anonymous_parked",
      isAnonymous: true,
      primaryEmail: null,
      clientReadOnlyMetadata: {},
      update: mock(async () => undefined),
    };
    const real = {
      id: "alias_real_parked",
      isAnonymous: false,
      primaryEmail: "billingfixture@gmail.com",
      primaryEmailVerified: true,
      emailAuthEnabled: true,
      clientReadOnlyMetadata: {},
      update: mock(async () => undefined),
    };
    const db = fakeDb();
    selectResults = [
      [{ stackUserId: anonymous.id, stackTeamId: null }],
      [{ stackUserId: anonymous.id, stackTeamId: null }],
      [],
      [],
      [],
      [],
      [],
    ];
    const result = await recordCheckoutCompletion(
      {
        session: {
          id: "cs_alias_parked",
          client_reference_id: anonymous.id,
          customer: "cus_alias_parked",
          customer_details: { email: "billing.fixture@gmail.com" },
          subscription: "sub_alias_parked",
        } as never,
        subscription: {
          id: "sub_alias_parked",
          customer: "cus_alias_parked",
          status: "active",
          metadata: { app: "cmux", plan: "pro", stackUserId: anonymous.id },
          cancel_at_period_end: false,
          items: { data: [] },
        } as never,
        customer: { id: "cus_alias_parked", deleted: false, email: "billing.fixture@gmail.com" } as never,
      },
      {
        db: db as never,
        stackApp: {
          getUser: async (id: string) => id === anonymous.id ? anonymous : real,
          listUsers: async () => [{ id: real.id, primaryEmail: real.primaryEmail, primaryEmailVerified: true, emailAuthEnabled: true }],
        } as never,
      },
    );
    expect(result).toMatchObject({ scope: "user", stackUserId: real.id });
    expect(
      updates.some(
        (entry) => entry.table === stripeCustomers && entry.values.stackUserId === real.id,
      ),
    ).toBe(true);
    expect(
      updates.some(
        (entry) => entry.table === stripeSubscriptions && entry.values.stackUserId === real.id,
      ),
    ).toBe(true);
    expect(inserts.some((entry) => entry.table === billingEmailClaims)).toBe(false);
  });
});

describe("recordCheckoutCompletion", () => {
  beforeEach(() => {
    inserts.length = 0;
    updates.length = 0;
    upsertUpdates.length = 0;
    insertErrorsByTable.clear();
    selectResults = [];
    tombstoneSelectResults = [];
    accountMutationOperationId = null;
  });

  test("attaches Stripe email as an unverified auth channel", async () => {
    const update = mock(async () => undefined);
    const sendMagicLinkEmail = mock(async () => undefined);
    const user = { id: "user_123", primaryEmail: null, clientReadOnlyMetadata: {}, update };

    await recordCheckoutCompletion(checkoutInput() as never, {
      db: fakeDb() as never,
      stackApp: { getUser: async () => user, sendMagicLinkEmail } as never,
    });

    expect(update).toHaveBeenCalledWith({
      primaryEmail: "buyer@example.com",
      primaryEmailAuthEnabled: true,
      primaryEmailVerified: false,
    });
    expect(update).not.toHaveBeenCalledWith({ primaryEmailVerified: true });
    expect(sendMagicLinkEmail).toHaveBeenCalledWith("buyer@example.com", {
      callbackUrl: "https://cmux.com/handler/after-sign-in",
    });
    expect(update).toHaveBeenCalledWith({
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
    });
  });

  test("promotes an already verified anonymous checkout account before granting Pro access", async () => {
    const previousFetch = globalThis.fetch;
    const update = mock(async () => undefined);
    const sendMagicLinkEmail = mock(async () => undefined);
    const user = {
      id: "anonymous_checkout",
      isAnonymous: true,
      isRestricted: true,
      primaryEmail: "buyer@example.com",
      primaryEmailVerified: true,
      clientReadOnlyMetadata: {},
      update,
    };
    const fetchMock = mock(async (rawInput: unknown, rawInit?: unknown) => {
      const request = new Request(rawInput as RequestInfo | URL, rawInit as RequestInit);
      expect(request.method).toBe("PATCH");
      expect(request.url).toContain("/api/v1/users/anonymous_checkout");
      expect(await request.json()).toEqual({
        primary_email_auth_enabled: true,
        is_anonymous: false,
      });
      return new Response(null, { status: 200 });
    });
    globalThis.fetch = fetchMock as typeof globalThis.fetch;
    try {
      const input = checkoutInput();
      input.session.client_reference_id = user.id;
      input.subscription.metadata.stackUserId = user.id;
      await recordCheckoutCompletion(input as never, {
        db: fakeDb() as never,
        stackApp: {
          getUser: async () => user,
          sendMagicLinkEmail,
        } as never,
      });
    } finally {
      globalThis.fetch = previousFetch;
    }

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(user.update).not.toHaveBeenCalledWith({
      primaryEmail: "buyer@example.com",
      primaryEmailAuthEnabled: true,
    });
    expect(user.update).toHaveBeenCalledWith({
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
    });
    expect(sendMagicLinkEmail).toHaveBeenCalledWith("buyer@example.com", {
      callbackUrl: "https://cmux.com/handler/after-sign-in",
    });
  });

  test("sends recovery mail without verifying an existing unverified purchase email", async () => {
    const update = mock(async () => undefined);
    const sendMagicLinkEmail = mock(async () => undefined);
    const user = {
      id: "user_123",
      primaryEmail: "buyer@example.com",
      primaryEmailVerified: false,
      primaryEmailAuthEnabled: true,
      clientReadOnlyMetadata: {},
      update,
    };

    await recordCheckoutCompletion(checkoutInput() as never, {
      db: fakeDb() as never,
      stackApp: { getUser: async () => user, sendMagicLinkEmail } as never,
    });

    expect(update).not.toHaveBeenCalledWith({ primaryEmailVerified: true });
    expect(sendMagicLinkEmail).toHaveBeenCalledWith("buyer@example.com", {
      callbackUrl: "https://cmux.com/handler/after-sign-in",
    });
  });

  test("deduplicates recovery mail when the same checkout webhook repeats", async () => {
    const update = mock(async () => undefined);
    const sendMagicLinkEmail = mock(async () => undefined);
    const user = {
      id: "user_123",
      primaryEmail: "buyer@example.com",
      primaryEmailVerified: false,
      primaryEmailAuthEnabled: true,
      clientReadOnlyMetadata: {},
      update,
    };
    const sentCheckoutSessions = new Set<string>();
    let deliveryCalls = 0;
    const magicLinkDelivery = {
      deliverOnce: async (
        input: { checkoutSessionId: string },
        deliver: () => Promise<void>,
      ) => {
        deliveryCalls += 1;
        if (sentCheckoutSessions.has(input.checkoutSessionId)) {
          return "already_sent" as const;
        }
        await deliver();
        sentCheckoutSessions.add(input.checkoutSessionId);
        return "sent" as const;
      },
    };
    const input = checkoutInput();
    const dependencies = {
      db: fakeDb() as never,
      stackApp: { getUser: async () => user, sendMagicLinkEmail } as never,
      magicLinkDelivery: magicLinkDelivery as never,
    };

    await recordCheckoutCompletion(input as never, dependencies);
    await recordCheckoutCompletion(input as never, dependencies);

    expect(deliveryCalls).toBe(2);
    expect(sendMagicLinkEmail).toHaveBeenCalledTimes(1);
  });

  test("keeps an unverified anonymous checkout account until mailbox confirmation", async () => {
    const previousFetch = globalThis.fetch;
    const update = mock(async () => undefined);
    const sendMagicLinkEmail = mock(async () => undefined);
    const user = {
      id: "anonymous_unverified",
      isAnonymous: true,
      isRestricted: true,
      primaryEmail: null,
      primaryEmailVerified: false,
      clientReadOnlyMetadata: {},
      update,
    };
    const fetchMock = mock(async () => {
      throw new Error("anonymous promotion must wait for verification");
    });
    globalThis.fetch = fetchMock as typeof globalThis.fetch;
    try {
      const input = checkoutInput();
      input.session.client_reference_id = user.id;
      input.subscription.metadata.stackUserId = user.id;
      await recordCheckoutCompletion(input as never, {
        db: fakeDb() as never,
        stackApp: {
          getUser: async () => user,
          sendMagicLinkEmail,
        } as never,
      });
    } finally {
      globalThis.fetch = previousFetch;
    }

    expect(fetchMock).not.toHaveBeenCalled();
    expect(update).toHaveBeenCalledWith({
      primaryEmail: "buyer@example.com",
      primaryEmailAuthEnabled: true,
      primaryEmailVerified: false,
    });
    expect(sendMagicLinkEmail).toHaveBeenCalledWith("buyer@example.com", {
      callbackUrl: "https://cmux.com/handler/after-sign-in",
    });
  });

  test("does not remap an anonymous checkout to an unverified email owner", async () => {
    const sourceUpdate = mock(async (options: unknown) => {
      if (
        options &&
        typeof options === "object" &&
        "primaryEmail" in options
      ) {
        throw new Error("CONTACT_CHANNEL_ALREADY_USED_FOR_AUTH_BY_SOMEONE_ELSE");
      }
    });
    const source = {
      id: "anonymous_source_unverified_owner",
      isAnonymous: true,
      isRestricted: true,
      primaryEmail: null,
      primaryEmailVerified: false,
      clientReadOnlyMetadata: {},
      update: sourceUpdate,
    };
    const unverifiedOwner = {
      id: "unverified_email_owner",
      isAnonymous: false,
      isRestricted: true,
      primaryEmail: "buyer@example.com",
      primaryEmailVerified: false,
      clientReadOnlyMetadata: {},
      update: mock(async () => undefined),
    };
    const getUser = mock(async (...args: unknown[]) =>
      (args[0] as string) === source.id ? source : unverifiedOwner,
    );
    const listUsers = mock(async () => [
      {
        id: unverifiedOwner.id,
        primaryEmail: unverifiedOwner.primaryEmail,
        primaryEmailVerified: false,
        isAnonymous: false,
        isRestricted: true,
      },
    ]);

    await recordCheckoutCompletion(
      {
        ...checkoutInput("cus_unverified_email_owner"),
        session: {
          ...checkoutInput("cus_unverified_email_owner").session,
          client_reference_id: source.id,
        },
        subscription: {
          ...checkoutInput("cus_unverified_email_owner").subscription,
          metadata: { app: "cmux", plan: "pro", stackUserId: source.id },
        },
      } as never,
      {
        db: fakeDb() as never,
        stackApp: { getUser, listUsers } as never,
      },
    );

    expect(getUser).toHaveBeenCalledWith(source.id);
    expect(sourceUpdate).toHaveBeenCalled();
    expect(
      updates.some(
        (entry) =>
          entry.table === stripeCustomers &&
          entry.values.stackUserId === unverifiedOwner.id,
      ),
    ).toBe(false);
  });

  test("blocks checkout completion while account deletion is in progress", async () => {
    const update = mock(async () => undefined);
    const cancelSubscription = mock(async () => undefined);
    const deleteCustomer = mock(async () => undefined);
    const user = {
      id: "user_123",
      primaryEmail: null,
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
      update,
    };

    await expect(
      recordCheckoutCompletion(checkoutInput() as never, {
        db: fakeDb() as never,
        stackApp: { getUser: async () => user } as never,
        stripeClient: () => ({
          subscriptions: { cancel: cancelSubscription },
          customers: { del: deleteCustomer },
        }) as never,
      }),
    ).resolves.toEqual({
      skipped: "account_deletion_in_progress",
      stackUserId: "user_123",
      subscriptionId: "sub_123",
    });

    expect(cancelSubscription).toHaveBeenCalledWith("sub_123");
    expect(deleteCustomer).toHaveBeenCalledWith("cus_123");
    expect(inserts).toHaveLength(0);
    expect(updates).toHaveLength(0);
    expect(update).not.toHaveBeenCalled();
  });

  test("does not recreate checkout billing rows after tombstoned Stack user is gone", async () => {
    const cancelSubscription = mock(async () => {
      throw { statusCode: 404, message: "No such subscription" };
    });
    const deleteCustomer = mock(async () => undefined);
    tombstoneSelectResults = [[{ status: "completed" }]];

    await expect(
      recordCheckoutCompletion(checkoutInput() as never, {
        db: fakeDb() as never,
        stackApp: { getUser: async () => null } as never,
        stripeClient: () => ({
          subscriptions: { cancel: cancelSubscription },
          customers: { del: deleteCustomer },
        }) as never,
      }),
    ).resolves.toEqual({
      skipped: "account_deletion_in_progress",
      stackUserId: "user_123",
      subscriptionId: "sub_123",
    });

    expect(cancelSubscription).toHaveBeenCalledWith("sub_123");
    expect(deleteCustomer).toHaveBeenCalledWith("cus_123");
    expect(inserts).toHaveLength(0);
    expect(updates).toHaveLength(0);
  });

  test("fails closed when checkout metadata points at a missing Stack user without a deletion tombstone", async () => {
    const cancelSubscription = mock(async () => undefined);
    const deleteCustomer = mock(async () => undefined);

    await expect(
      recordCheckoutCompletion(checkoutInput() as never, {
        db: fakeDb() as never,
        stackApp: { getUser: async () => null } as never,
        stripeClient: () => ({
          subscriptions: { cancel: cancelSubscription },
          customers: { del: deleteCustomer },
        }) as never,
      }),
    ).rejects.toThrow("Stack user not found for checkout completion: user_123");

    expect(cancelSubscription).not.toHaveBeenCalled();
    expect(deleteCustomer).not.toHaveBeenCalled();
    expect(inserts).toHaveLength(0);
    expect(updates).toHaveLength(0);
  });

  test("releases the database transaction before syncing checkout metadata", async () => {
    let transactionOpen = false;
    let lockCount = 0;
    const baseDb = fakeDb();
    const db = {
      ...baseDb,
      transaction: async <T>(
        callback: (tx: typeof baseDb & { execute: (_query?: unknown) => Promise<void> }) => Promise<T>,
      ) => {
        transactionOpen = true;
        try {
          return await callback({
            ...baseDb,
            execute: async (_query?: unknown) => {
              void _query;
              lockCount += 1;
            },
          });
        } finally {
          transactionOpen = false;
        }
      },
    };
    const update = mock(async () => {
      expect(transactionOpen).toBe(false);
      expect(lockCount).toBeGreaterThanOrEqual(2);
    });
    const user = {
      id: "user_123",
      primaryEmail: "buyer@example.com",
      clientReadOnlyMetadata: {},
      update,
    };

    await recordCheckoutCompletion(checkoutInput() as never, {
      db: db as never,
      stackApp: { getUser: async () => user } as never,
    });

    expect(update).toHaveBeenCalledWith({
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
    });
    expect(lockCount).toBeGreaterThanOrEqual(2);
  });

  test("skips checkout metadata sync when deletion starts after checkout rows commit", async () => {
    const staleUpdate = mock(async () => undefined);
    const deletingUpdate = mock(async () => undefined);
    const staleUser = {
      id: "user_123",
      primaryEmail: "buyer@example.com",
      clientReadOnlyMetadata: {},
      update: staleUpdate,
    };
    const deletingUser = {
      id: "user_123",
      primaryEmail: "buyer@example.com",
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
      update: deletingUpdate,
    };
    let getUserCalls = 0;
    const getUser = mock(async () => {
      getUserCalls += 1;
      return getUserCalls === 1 ? staleUser : deletingUser;
    });

    await recordCheckoutCompletion(checkoutInput() as never, {
      db: fakeDb() as never,
      stackApp: { getUser } as never,
    });

    expect(getUser).toHaveBeenCalledTimes(2);
    expect(inserts.some((insert) => insert.table === stripeSubscriptions)).toBe(true);
    expect(staleUpdate).not.toHaveBeenCalled();
    expect(deletingUpdate).not.toHaveBeenCalled();
  });

  test("records an email claim instead of attaching an email owned by a different Stack user", async () => {
    const update = mock(async () => undefined);
    const listUsers = mock(async () => [
      { id: "other_user", primaryEmail: "BUYER@example.com" },
    ]);
    const user = { id: "user_123", primaryEmail: null, clientReadOnlyMetadata: {}, update };

    await recordCheckoutCompletion(checkoutInput() as never, {
      db: fakeDb() as never,
      stackApp: { getUser: async () => user, listUsers } as never,
    });

    expect(listUsers).toHaveBeenCalledWith({
      query: "buyer@example.com",
      limit: 20,
      includeAnonymous: true,
      includeRestricted: true,
    });
    expect(update).not.toHaveBeenCalledWith({
      primaryEmail: "buyer@example.com",
      primaryEmailAuthEnabled: true,
    });
    expect(
      inserts.some(
        (insert) =>
          insert.table === billingEmailClaims &&
          insert.values.email === "buyer@example.com" &&
          insert.values.stripeCustomerId === "cus_123" &&
          insert.values.stackUserId === "user_123" &&
          insert.values.plan === "pro",
      ),
    ).toBe(true);
    expect(
      inserts.some(
        (insert) =>
          insert.table === stripeSubscriptions &&
          insert.values.stackUserId === "user_123" &&
          insert.values.plan === "pro",
      ),
    ).toBe(true);
    expect(update).toHaveBeenCalledWith({
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
    });
  });

  test("attaches Stripe email when the ownership lookup finds no exact owner", async () => {
    const update = mock(async () => undefined);
    const listUsers = mock(async () => [
      { id: "fuzzy_user", primaryEmail: "not-buyer@example.com" },
    ]);
    const user = { id: "user_123", primaryEmail: null, clientReadOnlyMetadata: {}, update };

    await recordCheckoutCompletion(checkoutInput() as never, {
      db: fakeDb() as never,
      stackApp: { getUser: async () => user, listUsers } as never,
    });

    expect(update).toHaveBeenCalledWith({
      primaryEmail: "buyer@example.com",
      primaryEmailAuthEnabled: true,
      primaryEmailVerified: false,
    });
    expect(inserts.some((insert) => insert.table === billingEmailClaims)).toBe(false);
  });

  test("does not record an email claim when the email is owned by the purchaser", async () => {
    const update = mock(async () => undefined);
    const listUsers = mock(async () => [
      { id: "user_123", primaryEmail: "buyer@example.com" },
    ]);
    const user = { id: "user_123", primaryEmail: null, clientReadOnlyMetadata: {}, update };

    await recordCheckoutCompletion(checkoutInput() as never, {
      db: fakeDb() as never,
      stackApp: { getUser: async () => user, listUsers } as never,
    });

    expect(update).toHaveBeenCalledWith({
      primaryEmail: "buyer@example.com",
      primaryEmailAuthEnabled: true,
      primaryEmailVerified: false,
    });
    expect(inserts.some((insert) => insert.table === billingEmailClaims)).toBe(false);
  });

  test("records an email claim when Stack reports the email is already used", async () => {
    const update = mock(async (options: unknown) => {
      if ("primaryEmail" in (options as Record<string, unknown>)) {
        throw new Error("CONTACT_CHANNEL_ALREADY_USED_FOR_AUTH_BY_SOMEONE_ELSE");
      }
    });
    const user = { id: "user_123", primaryEmail: null, clientReadOnlyMetadata: {}, update };

    await recordCheckoutCompletion(checkoutInput() as never, {
      db: fakeDb() as never,
      stackApp: { getUser: async () => user } as never,
    });

    expect(
      inserts.some(
        (insert) =>
          insert.table === billingEmailClaims &&
          insert.values.email === "buyer@example.com" &&
          insert.values.stackUserId === "user_123",
      ),
    ).toBe(true);
    expect(update).toHaveBeenCalledWith({
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
    });
  });

  test("falls back to update/catch when the ownership lookup throws", async () => {
    const update = mock(async (options: unknown) => {
      if ("primaryEmail" in (options as Record<string, unknown>)) {
        throw new Error("CONTACT_CHANNEL_ALREADY_USED_FOR_AUTH_BY_SOMEONE_ELSE");
      }
    });
    const listUsers = mock(async () => {
      throw new Error("Stack lookup failed");
    });
    const user = { id: "user_123", primaryEmail: null, clientReadOnlyMetadata: {}, update };

    await recordCheckoutCompletion(checkoutInput() as never, {
      db: fakeDb() as never,
      stackApp: { getUser: async () => user, listUsers } as never,
    });

    expect(update).toHaveBeenCalledWith({
      primaryEmail: "buyer@example.com",
      primaryEmailAuthEnabled: true,
      primaryEmailVerified: false,
    });
    expect(
      inserts.some(
        (insert) =>
          insert.table === billingEmailClaims &&
          insert.values.email === "buyer@example.com" &&
          insert.values.stackUserId === "user_123",
      ),
    ).toBe(true);
    expect(update).toHaveBeenCalledWith({
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
    });
  });

  test("does not duplicate an existing email claim on retry", async () => {
    const update = mock(async () => undefined);
    const listUsers = mock(async () => [
      { id: "other_user", primaryEmail: "buyer@example.com" },
    ]);
    const user = { id: "user_123", primaryEmail: null, clientReadOnlyMetadata: {}, update };
    selectResults = [[], [], [], [], [], [{ id: "claim_1" }]];

    await recordCheckoutCompletion(checkoutInput() as never, {
      db: fakeDb() as never,
      stackApp: { getUser: async () => user, listUsers } as never,
    });
    await recordCheckoutCompletion(checkoutInput() as never, {
      db: fakeDb() as never,
      stackApp: { getUser: async () => user, listUsers } as never,
    });

    expect(inserts.filter((insert) => insert.table === billingEmailClaims)).toHaveLength(1);
    expect(update).not.toHaveBeenCalledWith({
      primaryEmail: "buyer@example.com",
      primaryEmailAuthEnabled: true,
    });
  });

  test("rejects an ordinary checkout when Stripe customer ownership differs", async () => {
    const requestedUser = {
      id: "user_123",
      isAnonymous: false,
      isRestricted: false,
      primaryEmail: "buyer@example.com",
      primaryEmailVerified: true,
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
      update: mock(async () => undefined),
    };
    const mappedOwner = {
      id: "mapped_owner",
      isAnonymous: false,
      isRestricted: false,
      primaryEmail: "different@example.com",
      primaryEmailVerified: true,
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
      update: mock(async () => undefined),
    };
    const getUser = mock(async (rawID: unknown) =>
      (rawID as string) === mappedOwner.id ? mappedOwner : requestedUser,
    );
    selectResults = [[{ stackUserId: mappedOwner.id, stackTeamId: null }]];

    await expect(
      recordCheckoutCompletion(checkoutInput() as never, {
        db: fakeDb() as never,
        stackApp: { getUser } as never,
      }),
    ).rejects.toThrow("ownership conflict");
    expect(inserts).toHaveLength(0);
    expect(updates).toHaveLength(0);
    expect(getUser).toHaveBeenCalledWith(mappedOwner.id);
  });

  test("recovery can remap a parked historical customer before recording Pro", async () => {
    const source = {
      id: "parked_source",
      isAnonymous: true,
      primaryEmail: "billing.fixture@gmail.com",
      primaryEmailVerified: false,
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
      update: mock(async () => undefined),
    };
    const target = {
      id: "recovery_target",
      isAnonymous: false,
      isRestricted: false,
      primaryEmail: "billingfixture@gmail.com",
      primaryEmailVerified: true,
      clientReadOnlyMetadata: {},
      update: mock(async () => undefined),
    };
    const getUser = mock(async (rawID: unknown) =>
      (rawID as string) === source.id ? source : target,
    );
    selectResults = [
      [{ stackUserId: source.id, stackTeamId: null }],
      [{ stackUserId: source.id, stackTeamId: null }],
      [],
      ...Array.from({ length: 20 }, () => []),
    ];

    const result = await recordProCheckoutCompletionByEmail(
      {
        session: {
          id: "cs_recovery",
          client_reference_id: source.id,
          customer: "cus_recovery",
          customer_details: { email: "billing.fixture@gmail.com" },
          metadata: { app: "cmux", plan: "pro" },
          subscription: "sub_recovery",
        } as never,
        subscription: {
          id: "sub_recovery",
          customer: "cus_recovery",
          status: "active",
          metadata: { app: "cmux", plan: "pro", stackUserId: source.id },
          cancel_at_period_end: false,
          items: { data: [] },
        } as never,
        customer: {
          id: "cus_recovery",
          deleted: false,
          email: "billing.fixture@gmail.com",
        } as never,
      },
      {
        db: fakeDb() as never,
        stackApp: {
          getUser,
          listUsers: async () => [
            {
              id: target.id,
              primaryEmail: target.primaryEmail,
              primaryEmailVerified: true,
              update: target.update,
            },
          ],
        } as never,
        stripeClient: () => ({
          customers: {
            retrieve: async () => { throw new Error("offline"); },
            update: async () => undefined,
          },
          subscriptions: {
            retrieve: async () => { throw new Error("offline"); },
            update: async () => undefined,
          },
        }) as never,
      },
    );

    expect(result).toMatchObject({
      scope: "user",
      stackUserId: target.id,
      subscriptionId: "sub_recovery",
    });
    expect(
      updates.some(
        (entry) =>
          entry.table === stripeCustomers &&
          entry.values.stackUserId === target.id,
      ),
    ).toBe(true);
  });

  test("defers recovery ownership until an unverified destination confirms email", async () => {
    const source = {
      id: "deferred_source",
      isAnonymous: true,
      primaryEmail: null,
      primaryEmailVerified: false,
      clientReadOnlyMetadata: {},
      update: mock(async (options: unknown) => {
        if ("primaryEmail" in (options as Record<string, unknown>)) {
          throw new Error("CONTACT_CHANNEL_ALREADY_USED_FOR_AUTH_BY_SOMEONE_ELSE");
        }
      }),
    };
    const target = {
      id: "deferred_target",
      isAnonymous: false,
      isRestricted: true,
      primaryEmail: "billingfixture@gmail.com",
      primaryEmailVerified: false,
      clientReadOnlyMetadata: {},
      update: mock(async () => undefined),
    };
    const getUser = mock(async (rawID: unknown) =>
      (rawID as string) === source.id ? source : target,
    );
    const sendMagicLinkEmail = mock(async () => undefined);
    const magicLinkDelivery = {
      deliverOnce: async (
        _input: unknown,
        deliver: () => Promise<void>,
      ) => {
        await deliver();
        return "sent" as const;
      },
    };
    selectResults = [
      [{ stackUserId: source.id, stackTeamId: null }],
      [{ stackUserId: source.id, stackTeamId: null }],
      [],
      [],
    ];
    tombstoneSelectResults = [[], []];

    const result = await recordProCheckoutCompletionByEmail(
      {
        session: {
          id: "cs_deferred_recovery",
          client_reference_id: source.id,
          customer: "cus_deferred_recovery",
          customer_details: { email: "billing.fixture@gmail.com" },
          metadata: { app: "cmux", plan: "pro" },
          subscription: "sub_deferred_recovery",
        } as never,
        subscription: {
          id: "sub_deferred_recovery",
          customer: "cus_deferred_recovery",
          status: "active",
          metadata: { app: "cmux", plan: "pro", stackUserId: source.id },
          cancel_at_period_end: false,
          items: { data: [] },
        } as never,
        customer: {
          id: "cus_deferred_recovery",
          deleted: false,
          email: "billing.fixture@gmail.com",
        } as never,
      },
      {
        db: fakeDb() as never,
        magicLinkDelivery: magicLinkDelivery as never,
        stackApp: {
          getUser,
          listUsers: async () => [
            {
              id: target.id,
              primaryEmail: target.primaryEmail,
              primaryEmailVerified: target.primaryEmailVerified,
              isAnonymous: target.isAnonymous,
              isRestricted: target.isRestricted,
              update: target.update,
            },
          ],
          sendMagicLinkEmail,
        } as never,
      },
    );

    expect(result).toEqual({
      deferred: "email_verification",
      stackUserId: source.id,
      subscriptionId: "sub_deferred_recovery",
      deliveryEmail: "billing.fixture@gmail.com",
    });
    expect(sendMagicLinkEmail).toHaveBeenCalledWith(
      "billing.fixture@gmail.com",
      { callbackUrl: "https://cmux.com/handler/after-sign-in" },
    );
    expect(
      inserts.some(
        (insert) =>
          insert.table === billingEmailClaims &&
          insert.values.stackUserId === source.id &&
          insert.values.email === "billingfixture@gmail.com",
      ),
    ).toBe(true);
    expect(
      updates.some(
        (update) =>
          update.table === stripeCustomers &&
          update.values.stackUserId === target.id,
      ),
    ).toBe(false);
    expect(target.update).not.toHaveBeenCalled();
  });

  test("does not grant Pro metadata when recovery creates an unverified account", async () => {
    const targetUpdate = mock(async () => undefined);
    const target = {
      id: "new_unverified_recovery_target",
      isAnonymous: false,
      isRestricted: true,
      primaryEmail: "buyer@example.com",
      primaryEmailVerified: false,
      clientReadOnlyMetadata: {},
      update: targetUpdate,
    };
    const sendMagicLinkEmail = mock(async () => undefined);
    const result = await recordProCheckoutCompletionByEmail(
      {
        session: {
          id: "cs_new_unverified_recovery",
          customer: "cus_new_unverified_recovery",
          customer_details: { email: "buyer@example.com" },
          metadata: { app: "cmux", plan: "pro" },
          subscription: "sub_new_unverified_recovery",
        } as never,
        subscription: {
          id: "sub_new_unverified_recovery",
          customer: "cus_new_unverified_recovery",
          status: "active",
          metadata: { app: "cmux", plan: "pro" },
          cancel_at_period_end: false,
          items: { data: [] },
        } as never,
        customer: {
          id: "cus_new_unverified_recovery",
          deleted: false,
          email: "buyer@example.com",
        } as never,
      },
      {
        db: fakeDb() as never,
        magicLinkDelivery: {
          deliverOnce: async (_input: unknown, deliver: () => Promise<void>) => {
            await deliver();
            return "sent";
          },
        } as never,
        stackApp: {
          getUser: async () => target,
          listUsers: async () => [
            {
              id: target.id,
              primaryEmail: target.primaryEmail,
              primaryEmailVerified: false,
              isAnonymous: false,
              isRestricted: true,
              update: targetUpdate,
            },
          ],
          sendMagicLinkEmail,
        } as never,
      },
    );

    expect(result).toEqual({
      deferred: "email_verification",
      stackUserId: target.id,
      subscriptionId: "sub_new_unverified_recovery",
      deliveryEmail: "buyer@example.com",
    });
    expect(targetUpdate).not.toHaveBeenCalledWith({
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
    });
    expect(
      inserts.some(
        (insert) =>
          insert.table === billingEmailClaims &&
          insert.values.stackUserId === target.id &&
          insert.values.stripeCustomerId === "cus_new_unverified_recovery",
      ),
    ).toBe(true);
  });

  test("does not remap a parked customer to an unverified target", async () => {
    const source = {
      id: "parked_unverified_source",
      isAnonymous: true,
      primaryEmail: null,
      primaryEmailVerified: false,
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
      update: mock(async () => undefined),
    };
    const target = {
      id: "unverified_recovery_target",
      isAnonymous: false,
      isRestricted: false,
      primaryEmail: "billingfixture@gmail.com",
      primaryEmailVerified: false,
      clientReadOnlyMetadata: {},
      update: mock(async () => undefined),
    };
    const getUser = mock(async (rawID: unknown) =>
      (rawID as string) === source.id ? source : target,
    );
    selectResults = [
      [{ stackUserId: source.id, stackTeamId: null }],
      [{ stackUserId: source.id, stackTeamId: null }],
    ];

    const result = await recordCheckoutCompletion(
        {
          ...checkoutInput("cus_unverified_recovery"),
          session: {
            ...checkoutInput("cus_unverified_recovery").session,
            client_reference_id: source.id,
            customer: "cus_unverified_recovery",
            customer_details: { email: "billing.fixture@gmail.com" },
            metadata: { app: "cmux", plan: "pro" },
          },
          subscription: {
            ...checkoutInput("cus_unverified_recovery").subscription,
            customer: "cus_unverified_recovery",
            metadata: { app: "cmux", plan: "pro", stackUserId: source.id },
          },
          customer: {
            id: "cus_unverified_recovery",
            deleted: false,
            email: "billing.fixture@gmail.com",
          },
          allowCanonicalOwnershipRecovery: true,
        } as never,
        {
          db: fakeDb() as never,
          stackApp: {
            getUser,
            listUsers: async () => [
              {
                id: target.id,
                primaryEmail: target.primaryEmail,
                primaryEmailVerified: false,
                update: target.update,
              },
            ],
          } as never,
        },
      );
    expect(result).toEqual({
      scope: "user",
      stackUserId: source.id,
      subscriptionId: "sub_123",
    });
    expect(
      inserts.some(
        (insert) => insert.table === stripeCustomers && insert.values.stackUserId === target.id,
      ),
    ).toBe(false);
    expect(target.update).not.toHaveBeenCalled();
  });

  test("updates the Stripe customer id when the same Stack user repurchases", async () => {
    const update = mock(async () => undefined);
    const user = {
      id: "user_123",
      primaryEmail: "buyer@example.com",
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
      update,
    };
    selectResults = [[], [{ id: "cus_old" }]];

    await recordCheckoutCompletion(checkoutInput("cus_new") as never, {
      db: fakeDb() as never,
      stackApp: { getUser: async () => user } as never,
    });

    expect(
      updates.some(
        (entry) => entry.table === stripeCustomers && entry.values.id === "cus_new",
      ),
    ).toBe(true);
    expect(inserts.some((insert) => insert.table === stripeCustomers)).toBe(false);
  });

  test("updates the existing Stack user customer row when Drizzle wraps a unique violation", async () => {
    const update = mock(async () => undefined);
    const user = {
      id: "user_123",
      primaryEmail: "buyer@example.com",
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
      update,
    };
    selectResults = [[]];
    insertErrorsByTable.set(
      stripeCustomers,
      Object.assign(new Error("Failed query: insert into stripe_customers"), {
        cause: {
          code: "23505",
          constraint: "stripe_customers_stack_user_id_unique",
        },
      }),
    );

    await recordCheckoutCompletion(checkoutInput("cus_race") as never, {
      db: fakeDb() as never,
      stackApp: { getUser: async () => user } as never,
    });

    expect(
      updates.some(
        (entry) => entry.table === stripeCustomers && entry.values.id === "cus_race",
      ),
    ).toBe(true);
  });

  test("records Team checkout rows and syncs the Stack team entitlement", async () => {
    const updateTeam = mock(async () => undefined);
    const team = {
      id: "team_123",
      clientReadOnlyMetadata: {},
      update: updateTeam,
    };
    selectResults = [[{ stackUserId: "owner_123" }], []];

    const result = await recordCheckoutCompletion(teamCheckoutInput() as never, {
      db: fakeDb() as never,
      stackApp: {
        getUser: async () => ({
          id: "owner_123",
          primaryEmail: "owner@example.com",
          clientReadOnlyMetadata: {},
          update: mock(async () => undefined),
        }),
        getTeam: async () => team,
      } as never,
    });

    expect(result).toEqual({
      scope: "team",
      stackTeamId: "team_123",
      subscriptionId: "sub_team",
    });
    expect(
      inserts.some(
        (insert) =>
          insert.table === stripeCustomers &&
          insert.values.id === "cus_team" &&
          insert.values.stackUserId === "owner_123" &&
          insert.values.stackTeamId === "team_123",
      ),
    ).toBe(true);
    expect(
      inserts.some(
        (insert) =>
          insert.table === stripeSubscriptions &&
          insert.values.scope === "team" &&
          insert.values.plan === "team" &&
          insert.values.stackTeamId === "team_123" &&
          insert.values.seats === 4,
      ),
    ).toBe(true);
    expect(updateTeam).toHaveBeenCalledWith({
      clientReadOnlyMetadata: { cmuxPlan: "team" },
    });
  });

  test("preserves legacy Team checkout rows owned by the team id", async () => {
    const getUser = mock(async () => {
      throw new Error("should not load Stack user for legacy team-owned checkout");
    });
    const updateTeam = mock(async () => undefined);
    const cancelSubscription = mock(async () => undefined);
    const deleteCustomer = mock(async () => undefined);
    const team = {
      id: "team_123",
      clientReadOnlyMetadata: {},
      update: updateTeam,
    };
    selectResults = [
      [{ id: "cus_team", stackUserId: "team_123" }],
      [{ id: "cus_team", stackUserId: "team_123" }],
    ];

    const result = await recordCheckoutCompletion(teamCheckoutInput() as never, {
      db: fakeDb() as never,
      stackApp: {
        getUser,
        getTeam: async () => team,
      } as never,
      stripeClient: () => ({
        subscriptions: { cancel: cancelSubscription },
        customers: { del: deleteCustomer },
      }) as never,
    });

    expect(result).toEqual({
      scope: "team",
      stackTeamId: "team_123",
      subscriptionId: "sub_team",
    });
    expect(getUser).not.toHaveBeenCalled();
    expect(cancelSubscription).not.toHaveBeenCalled();
    expect(deleteCustomer).not.toHaveBeenCalled();
    expect(
      inserts.some(
        (insert) =>
          insert.table === stripeCustomers &&
          insert.values.id === "cus_team" &&
          insert.values.stackUserId === "team_123" &&
          insert.values.stackTeamId === "team_123",
      ),
    ).toBe(true);
    expect(updateTeam).toHaveBeenCalledWith({
      clientReadOnlyMetadata: { cmuxPlan: "team" },
    });
  });

  test("blocks Team checkout completion while the billing owner is deleting without deleting the team customer", async () => {
    const cancelSubscription = mock(async () => undefined);
    const deleteCustomer = mock(async () => undefined);
    const owner = {
      id: "owner_123",
      primaryEmail: "owner@example.com",
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
      update: mock(async () => undefined),
    };
    selectResults = [[{ id: "cus_team", stackUserId: "owner_123" }], []];

    await expect(
      recordCheckoutCompletion(teamCheckoutInput() as never, {
        db: fakeDb() as never,
        stackApp: {
          getUser: async () => owner,
          getTeam: async () => {
            throw new Error("should not load Stack team for blocked Team checkout");
          },
        } as never,
        stripeClient: () => ({
          subscriptions: { cancel: cancelSubscription },
          customers: { del: deleteCustomer },
        }) as never,
      }),
    ).resolves.toEqual({
      skipped: "account_deletion_in_progress",
      stackUserId: "owner_123",
      subscriptionId: "sub_team",
    });

    expect(cancelSubscription).toHaveBeenCalledWith("sub_team");
    expect(deleteCustomer).not.toHaveBeenCalled();
    expect(inserts).toHaveLength(0);
    expect(updates).toHaveLength(0);
    expect(owner.update).not.toHaveBeenCalled();
  });

  test("deletes a new Team checkout customer when account deletion wins before a customer row exists", async () => {
    const cancelSubscription = mock(async () => undefined);
    const deleteCustomer = mock(async () => undefined);
    const owner = {
      id: "owner_123",
      primaryEmail: "owner@example.com",
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
      update: mock(async () => undefined),
    };

    await expect(
      recordCheckoutCompletion(teamCheckoutInput("cus_team_new", "owner_123") as never, {
        db: fakeDb() as never,
        stackApp: {
          getUser: async () => owner,
          getTeam: async () => {
            throw new Error("should not load Stack team for blocked Team checkout");
          },
        } as never,
        stripeClient: () => ({
          subscriptions: { cancel: cancelSubscription },
          customers: { del: deleteCustomer },
        }) as never,
      }),
    ).resolves.toEqual({
      skipped: "account_deletion_in_progress",
      stackUserId: "owner_123",
      subscriptionId: "sub_team",
    });

    expect(cancelSubscription).toHaveBeenCalledWith("sub_team");
    expect(deleteCustomer).toHaveBeenCalledWith("cus_team_new");
    expect(inserts).toHaveLength(0);
    expect(updates).toHaveLength(0);
    expect(owner.update).not.toHaveBeenCalled();
  });

  test("cancels Team checkout completion when buyer ownership is missing", async () => {
    const cancelSubscription = mock(async () => undefined);
    const deleteCustomer = mock(async () => undefined);
    selectResults = [[], []];

    await expect(
      recordCheckoutCompletion(teamCheckoutInput("cus_team_new") as never, {
        db: fakeDb() as never,
        stackApp: {
          getUser: async () => {
            throw new Error("should not load a Stack user without a checkout owner");
          },
          getTeam: async () => {
            throw new Error("should not sync Stack team without a checkout owner");
          },
        } as never,
        stripeClient: () => ({
          subscriptions: { cancel: cancelSubscription },
          customers: { del: deleteCustomer },
        }) as never,
      }),
    ).resolves.toEqual({
      skipped: "account_deletion_in_progress",
      stackUserId: "team_123",
      subscriptionId: "sub_team",
    });

    expect(cancelSubscription).toHaveBeenCalledWith("sub_team");
    expect(deleteCustomer).toHaveBeenCalledWith("cus_team_new");
    expect(inserts).toHaveLength(0);
    expect(updates).toHaveLength(0);
  });

  test("preserves an existing Team checkout customer when account deletion blocks a metadata-owned checkout", async () => {
    const cancelSubscription = mock(async () => undefined);
    const deleteCustomer = mock(async () => undefined);
    const owner = {
      id: "owner_123",
      primaryEmail: "owner@example.com",
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
      update: mock(async () => undefined),
    };
    selectResults = [[{ id: "cus_team_existing", stackUserId: "owner_123" }], []];

    await expect(
      recordCheckoutCompletion(teamCheckoutInput("cus_team_existing", "owner_123") as never, {
        db: fakeDb() as never,
        stackApp: {
          getUser: async () => owner,
          getTeam: async () => {
            throw new Error("should not load Stack team for blocked Team checkout");
          },
        } as never,
        stripeClient: () => ({
          subscriptions: { cancel: cancelSubscription },
          customers: { del: deleteCustomer },
        }) as never,
      }),
    ).resolves.toEqual({
      skipped: "account_deletion_in_progress",
      stackUserId: "owner_123",
      subscriptionId: "sub_team",
    });

    expect(cancelSubscription).toHaveBeenCalledWith("sub_team");
    expect(deleteCustomer).not.toHaveBeenCalled();
    expect(inserts).toHaveLength(0);
    expect(updates).toHaveLength(0);
    expect(owner.update).not.toHaveBeenCalled();
  });

  test("deletes a new Team checkout customer when the existing team customer is different", async () => {
    const cancelSubscription = mock(async () => undefined);
    const deleteCustomer = mock(async () => undefined);
    const owner = {
      id: "owner_123",
      primaryEmail: "owner@example.com",
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
      update: mock(async () => undefined),
    };
    selectResults = [[{ id: "cus_team_old", stackUserId: "owner_123" }], []];

    await expect(
      recordCheckoutCompletion(teamCheckoutInput("cus_team_new", "owner_123") as never, {
        db: fakeDb() as never,
        stackApp: {
          getUser: async () => owner,
          getTeam: async () => {
            throw new Error("should not load Stack team for blocked Team checkout");
          },
        } as never,
        stripeClient: () => ({
          subscriptions: { cancel: cancelSubscription },
          customers: { del: deleteCustomer },
        }) as never,
      }),
    ).resolves.toEqual({
      skipped: "account_deletion_in_progress",
      stackUserId: "owner_123",
      subscriptionId: "sub_team",
    });

    expect(cancelSubscription).toHaveBeenCalledWith("sub_team");
    expect(deleteCustomer).toHaveBeenCalledWith("cus_team_new");
    expect(inserts).toHaveLength(0);
    expect(updates).toHaveLength(0);
    expect(owner.update).not.toHaveBeenCalled();
  });

  test("clears Team metadata when a Team subscription lapses", async () => {
    const updateTeam = mock(async () => undefined);
    const team = {
      id: "team_123",
      clientReadOnlyMetadata: { cmuxPlan: "team", cmuxVmPlan: "pro" },
      update: updateTeam,
    };
    selectResults = [[{ stackUserId: "owner_123" }], [{ stackUserId: "owner_123" }], []];

    const result = await applySubscriptionUpdate(
      {
        id: "sub_team",
        customer: "cus_team",
        status: "canceled",
        metadata: { stackTeamId: "team_123", plan: "team", app: "cmux" },
        cancel_at_period_end: false,
        items: {
          data: [
            {
              quantity: 7,
              current_period_end: 1_800_000_000,
              price: { id: "price_team" },
            },
          ],
        },
      } as never,
      {
        db: fakeDb() as never,
        stackApp: {
          getUser: async () => ({
            id: "owner_123",
            primaryEmail: "owner@example.com",
            clientReadOnlyMetadata: {},
            update: mock(async () => undefined),
          }),
          getTeam: async () => team,
        } as never,
      },
    );

    expect(result).toEqual({ scope: "team", stackTeamId: "team_123", isActive: false });
    expect(
      inserts.some(
        (insert) =>
          insert.table === stripeSubscriptions &&
          insert.values.scope === "team" &&
          insert.values.seats === 7,
      ),
    ).toBe(true);
    expect(updateTeam).toHaveBeenCalledWith({
      clientReadOnlyMetadata: { cmuxVmPlan: "pro" },
    });
  });

  test("syncs legacy Team subscription webhooks whose customer owner is the team id", async () => {
    const getUser = mock(async () => {
      throw new Error("should not load Stack user for legacy Team-owned billing rows");
    });
    const updateTeam = mock(async () => undefined);
    const team = {
      id: "team_123",
      clientReadOnlyMetadata: { cmuxPlan: "team", cmuxVmPlan: "pro" },
      update: updateTeam,
    };
    selectResults = [[{ stackUserId: "team_123" }], [{ stackUserId: "team_123" }]];

    const result = await applySubscriptionUpdate(
      {
        id: "sub_team",
        customer: "cus_team",
        status: "canceled",
        metadata: { stackTeamId: "team_123", plan: "team", app: "cmux" },
        cancel_at_period_end: false,
        items: {
          data: [
            {
              quantity: 7,
              current_period_end: 1_800_000_000,
              price: { id: "price_team" },
            },
          ],
        },
      } as never,
      {
        db: fakeDb() as never,
        stackApp: {
          getUser,
          getTeam: async () => team,
        } as never,
      },
    );

    expect(result).toEqual({ scope: "team", stackTeamId: "team_123", isActive: false });
    expect(getUser).not.toHaveBeenCalled();
    expect(
      inserts.some(
        (insert) =>
          insert.table === stripeSubscriptions &&
          insert.values.scope === "team" &&
          insert.values.stackUserId === "team_123",
      ),
    ).toBe(true);
    expect(updateTeam).toHaveBeenCalledWith({
      clientReadOnlyMetadata: { cmuxVmPlan: "pro" },
    });
  });

  test("skips Team subscription webhooks for deleted-account owner rows", async () => {
    const getTeam = mock(async () => {
      throw new Error("should not load Stack team for deleted account owner");
    });
    selectResults = [[{ stackUserId: "deleted-account" }]];

    const result = await applySubscriptionUpdate(
      {
        id: "sub_team",
        customer: "cus_team",
        status: "canceled",
        metadata: { stackTeamId: "team_123", plan: "team", app: "cmux" },
        cancel_at_period_end: false,
        items: {
          data: [
            {
              quantity: 7,
              current_period_end: 1_800_000_000,
              price: { id: "price_team" },
            },
          ],
        },
      } as never,
      {
        db: fakeDb() as never,
        stackApp: {
          getTeam,
        } as never,
      },
    );

    expect(result).toEqual({ skipped: true });
    expect(getTeam).not.toHaveBeenCalled();
    expect(inserts.some((insert) => insert.table === stripeSubscriptions)).toBe(false);
    expect(updates.some((update) => update.table === stripeSubscriptions)).toBe(false);
  });

  test("skips ownerless legacy Team subscription webhooks before writing rows", async () => {
    const getUser = mock(async () => {
      throw new Error("should not load Stack user for ownerless Team subscription");
    });
    const getTeam = mock(async () => {
      throw new Error("should not load Stack team for ownerless Team subscription");
    });
    selectResults = [[], []];

    const result = await applySubscriptionUpdate(
      {
        id: "sub_team",
        customer: "cus_team",
        status: "active",
        metadata: { stackTeamId: "team_123", plan: "team", app: "cmux" },
        cancel_at_period_end: false,
        items: {
          data: [
            {
              quantity: 7,
              current_period_end: 1_800_000_000,
              price: { id: "price_team" },
            },
          ],
        },
      } as never,
      {
        db: fakeDb() as never,
        stackApp: { getUser, getTeam } as never,
      },
    );

    expect(result).toEqual({ skipped: true });
    expect(getUser).not.toHaveBeenCalled();
    expect(getTeam).not.toHaveBeenCalled();
    expect(inserts.some((insert) => insert.table === stripeSubscriptions)).toBe(false);
    expect(updates.some((update) => update.table === stripeSubscriptions)).toBe(false);
  });

  test("skips Team subscription webhooks for tombstoned metadata owners before writing rows", async () => {
    const getUser = mock(async () => {
      throw new Error("should not load Stack user after tombstone blocks Team subscription");
    });
    const getTeam = mock(async () => {
      throw new Error("should not load Stack team after tombstone blocks Team subscription");
    });
    selectResults = [[], [], [], []];
    tombstoneSelectResults = [[{ status: "pending", updatedAt: new Date() }]];

    const result = await applySubscriptionUpdate(
      {
        id: "sub_team",
        customer: "cus_team",
        status: "active",
        metadata: {
          stackTeamId: "team_123",
          stackUserId: "owner_123",
          plan: "team",
          app: "cmux",
        },
        cancel_at_period_end: false,
        items: {
          data: [
            {
              quantity: 7,
              current_period_end: 1_800_000_000,
              price: { id: "price_team" },
            },
          ],
        },
      } as never,
      {
        db: fakeDb() as never,
        stackApp: {
          getUser,
          getTeam,
        } as never,
      },
    );

    expect(result).toEqual({ skipped: true });
    expect(getUser).not.toHaveBeenCalled();
    expect(getTeam).not.toHaveBeenCalled();
    expect(inserts.some((insert) => insert.table === stripeCustomers)).toBe(false);
    expect(inserts.some((insert) => insert.table === stripeSubscriptions)).toBe(false);
    expect(updates.some((update) => update.table === stripeCustomers)).toBe(false);
    expect(updates.some((update) => update.table === stripeSubscriptions)).toBe(false);
  });

  test("removes a user from TestFlight when a user Pro subscription lapses", async () => {
    const update = mock(async () => undefined);
    let transactionDepth = 0;
    const baseDb = fakeDb();
    const trackedDb = {
      ...baseDb,
      transaction: async <T>(
        callback: (tx: typeof baseDb) => Promise<T>,
      ) => {
        transactionDepth += 1;
        try {
          return await callback(baseDb);
        } finally {
          transactionDepth -= 1;
        }
      },
    };
    const removeTester = mock(async () => {
      expect(transactionDepth).toBe(0);
    });
    const user = {
      id: "user_123",
      primaryEmail: "buyer@example.com",
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
      update,
    };
    selectResults = [[{ stackUserId: "user_123" }], [{ id: "sub_user" }]];

    const result = await applySubscriptionUpdate(
      userSubscriptionUpdate({ status: "canceled" }) as never,
      {
        db: trackedDb as never,
        stackApp: { getUser: async () => user } as never,
        testflight: {
          isAscConfigured: () => true,
          removeTester,
        },
      },
    );

    expect(result).toEqual({ scope: "user", stackUserId: "user_123", isActive: false });
    expect(removeTester).toHaveBeenCalledWith("buyer@example.com", {
      ownedLegacyGroupIDs: [],
    });
    expect(updates.find((entry) => entry.table === stripeSubscriptions)?.values).not.toHaveProperty(
      "id",
    );
    expect(update).toHaveBeenCalledWith({ clientReadOnlyMetadata: {} });
  });

  test("does not restore Pro metadata while removing recorded TestFlight ownership after a lapse", async () => {
    const metadataWrites: unknown[] = [];
    const update = mock(async (...args: unknown[]) => {
      const [options] = args as [{ readonly clientReadOnlyMetadata: unknown }];
      metadataWrites.push(options.clientReadOnlyMetadata);
    });
    const removeTester = mock(async () => undefined);
    const user = {
      id: "user_123",
      primaryEmail: "buyer@example.com",
      clientReadOnlyMetadata: {
        cmuxPlan: "pro",
        cmuxProTestflightEnrollmentEmails: ["buyer@example.com"],
        cmuxProTestflightGrants: [
          { email: "buyer@example.com", source: "user" },
        ],
      },
      update,
    };
    selectResults = [[{ stackUserId: "user_123" }], [{ id: "sub_user" }]];

    await applySubscriptionUpdate(
      userSubscriptionUpdate({ status: "canceled" }) as never,
      {
        db: fakeDb() as never,
        stackApp: { getUser: async () => user } as never,
        testflight: {
          isAscConfigured: () => true,
          removeTester,
        },
      },
    );

    expect(metadataWrites).toHaveLength(2);
    expect(metadataWrites[0]).not.toHaveProperty("cmuxPlan");
    expect(metadataWrites[1]).toEqual({});
  });

  test("removes an explicitly recorded legacy Pro membership when Pro lapses", async () => {
    const removeTester = mock(async () => undefined);
    const user = {
      id: "user_123",
      primaryEmail: "current@example.com",
      clientReadOnlyMetadata: {
        cmuxPlan: "pro",
        cmuxProTestflightOwnedLegacyGroupIDs: [
          FOUNDER_TESTFLIGHT_GROUP_ID,
        ],
        cmuxProTestflightOwnedLegacyEmails: ["legacy@example.com"],
      },
      update: mock(async () => undefined),
    };
    selectResults = [[{ stackUserId: "user_123" }], [{ id: "sub_user" }]];

    const result = await applySubscriptionUpdate(
      userSubscriptionUpdate({ status: "canceled" }) as never,
      {
        db: fakeDb() as never,
        stackApp: { getUser: async () => user } as never,
        testflight: {
          isAscConfigured: () => true,
          removeTester,
        },
      },
    );

    expect(result).toEqual({
      scope: "user",
      stackUserId: "user_123",
      isActive: false,
    });
    expect(removeTester).toHaveBeenNthCalledWith(1, "current@example.com", {
      ownedLegacyGroupIDs: [],
    });
    expect(removeTester).toHaveBeenNthCalledWith(2, "legacy@example.com", {
      ownedLegacyGroupIDs: [
        FOUNDER_TESTFLIGHT_GROUP_ID,
      ],
    });
  });

  test("keeps the webhook retryable when TestFlight removal fails", async () => {
    const captureAscError = mock(() => undefined);
    const user = {
      id: "user_123",
      primaryEmail: "buyer@example.com",
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
      update: mock(async () => undefined),
    };
    selectResults = [[{ stackUserId: "user_123" }], [{ id: "sub_user" }]];

    await expect(
      applySubscriptionUpdate(
        userSubscriptionUpdate({ status: "canceled" }) as never,
        {
          db: fakeDb() as never,
          stackApp: { getUser: async () => user } as never,
          testflight: {
            isAscConfigured: () => true,
            removeTester: async () => {
              throw new Error("ASC down");
            },
            captureAscError,
          },
        },
      ),
    ).rejects.toThrow("ASC down");

    expect(captureAscError).toHaveBeenCalledWith(
      expect.objectContaining({ message: "ASC down" }),
      expect.objectContaining({
        route: "/api/stripe/webhook",
        stackUserId: "user_123",
        email: "buyer@example.com",
      }),
    );
  });

  test("does not remove TestFlight access when ASC is unconfigured", async () => {
    const removeTester = mock(async () => undefined);
    const user = {
      id: "user_123",
      primaryEmail: "buyer@example.com",
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
      update: mock(async () => undefined),
    };
    selectResults = [[{ stackUserId: "user_123" }], [{ id: "sub_user" }]];

    await applySubscriptionUpdate(
      userSubscriptionUpdate({ status: "canceled" }) as never,
      {
        db: fakeDb() as never,
        stackApp: { getUser: async () => user } as never,
        testflight: {
          isAscConfigured: () => false,
          removeTester,
        },
      },
    );

    expect(removeTester).not.toHaveBeenCalled();
  });

  test("skips user subscription webhooks while account deletion is in progress", async () => {
    const getUser = mock(async () => ({
      id: "user_123",
      primaryEmail: "buyer@example.com",
      clientReadOnlyMetadata: { cmuxAccountDeleting: true, cmuxPlan: "pro" },
      update: mock(async () => undefined),
    }));
    selectResults = [[], []];

    const result = await applySubscriptionUpdate(
      userSubscriptionUpdate({ status: "canceled" }) as never,
      {
        db: fakeDb() as never,
        stackApp: { getUser } as never,
      },
    );

    expect(result).toEqual({ skipped: true });
    expect(getUser).toHaveBeenCalledWith("user_123");
    expect(inserts.some((insert) => insert.table === stripeSubscriptions)).toBe(false);
    expect(updates.some((update) => update.table === stripeSubscriptions)).toBe(false);
  });

  test("skips known subscription webhooks before writing rows while account deletion is in progress", async () => {
    const update = mock(async () => undefined);
    const getUser = mock(async () => ({
      id: "user_123",
      primaryEmail: "buyer@example.com",
      clientReadOnlyMetadata: { cmuxAccountDeleting: true, cmuxPlan: "pro" },
      update,
    }));
    selectResults = [[{ stackUserId: "user_123" }], [{ id: "sub_user" }]];

    const result = await applySubscriptionUpdate(
      userSubscriptionUpdate({ status: "canceled" }) as never,
      {
        db: fakeDb() as never,
        stackApp: { getUser } as never,
      },
    );

    expect(result).toEqual({ skipped: true });
    expect(getUser).toHaveBeenCalledWith("user_123");
    expect(update).not.toHaveBeenCalled();
    expect(updates.some((entry) => entry.table === stripeSubscriptions)).toBe(false);
    expect(inserts.some((insert) => insert.table === stripeSubscriptions)).toBe(false);
  });

  test("skips user subscription webhooks when deletion starts before the locked write", async () => {
    const getUser = mock(async () => {
      throw new Error("should not load Stack user after tombstone blocks subscription write");
    });
    selectResults = [[{ stackUserId: "user_123" }], [{ id: "sub_user" }]];
    tombstoneSelectResults = [[{ status: "pending", updatedAt: new Date() }]];

    const result = await applySubscriptionUpdate(
      userSubscriptionUpdate({ status: "canceled" }) as never,
      {
        db: fakeDb() as never,
        stackApp: { getUser } as never,
      },
    );

    expect(result).toEqual({ skipped: true });
    expect(getUser).not.toHaveBeenCalled();
    expect(updates.some((entry) => entry.table === stripeSubscriptions)).toBe(false);
    expect(inserts.some((insert) => insert.table === stripeSubscriptions)).toBe(false);
  });

  test("skips subscription metadata sync when deletion starts after webhook rows update", async () => {
    const staleUpdate = mock(async () => undefined);
    const deletingUpdate = mock(async () => undefined);
    const staleUser = {
      id: "user_123",
      primaryEmail: "buyer@example.com",
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
      update: staleUpdate,
    };
    const deletingUser = {
      id: "user_123",
      primaryEmail: "buyer@example.com",
      clientReadOnlyMetadata: { cmuxAccountDeleting: true, cmuxPlan: "pro" },
      update: deletingUpdate,
    };
    let getUserCalls = 0;
    const getUser = mock(async () => {
      getUserCalls += 1;
      return getUserCalls === 1 ? staleUser : deletingUser;
    });
    selectResults = [[], []];

    const result = await applySubscriptionUpdate(
      userSubscriptionUpdate({ status: "canceled" }) as never,
      {
        db: fakeDb() as never,
        stackApp: { getUser } as never,
      },
    );

    expect(result).toEqual({ scope: "user", stackUserId: "user_123", isActive: false });
    expect(getUser).toHaveBeenCalledTimes(2);
    expect(inserts.some((insert) => insert.table === stripeSubscriptions)).toBe(true);
    expect(staleUpdate).not.toHaveBeenCalled();
    expect(deletingUpdate).not.toHaveBeenCalled();
  });

  test("fails known subscription webhooks when the Stack user is missing", async () => {
    const getUser = mock(async () => null);
    selectResults = [[{ stackUserId: "user_123" }], [{ id: "sub_user" }]];

    await expect(
      applySubscriptionUpdate(
        userSubscriptionUpdate({ status: "canceled" }) as never,
        {
          db: fakeDb() as never,
          stackApp: { getUser } as never,
        },
      ),
    ).rejects.toThrow("Stack user not found for Stripe subscription update: user_123");

    expect(getUser).toHaveBeenCalledWith("user_123");
    expect(updates.some((entry) => entry.table === stripeSubscriptions)).toBe(false);
    expect(inserts.some((insert) => insert.table === stripeSubscriptions)).toBe(false);
  });

  test("skips metadata-only user subscription webhooks after local account rows are gone", async () => {
    const getUser = mock(async () => null);
    selectResults = [[], []];

    const result = await applySubscriptionUpdate(
      userSubscriptionUpdate({ status: "canceled" }) as never,
      {
        db: fakeDb() as never,
        stackApp: { getUser } as never,
      },
    );

    expect(result).toEqual({ skipped: true });
    expect(getUser).toHaveBeenCalledWith("user_123");
    expect(inserts.some((insert) => insert.table === stripeSubscriptions)).toBe(false);
    expect(updates.some((update) => update.table === stripeSubscriptions)).toBe(false);
  });

  test("skips user subscription webhooks for anonymized local customer rows", async () => {
    const getUser = mock(async () => {
      throw new Error("should not load Stack user for anonymized local customer");
    });
    selectResults = [[{ stackUserId: "deleted-account" }]];

    const result = await applySubscriptionUpdate(
      userSubscriptionUpdate({ status: "active" }) as never,
      {
        db: fakeDb() as never,
        stackApp: { getUser } as never,
      },
    );

    expect(result).toEqual({ skipped: true });
    expect(getUser).not.toHaveBeenCalled();
    expect(inserts.some((insert) => insert.table === stripeSubscriptions)).toBe(false);
    expect(updates.some((update) => update.table === stripeSubscriptions)).toBe(false);
  });

  test("skips user subscription webhooks when Stripe metadata conflicts with the local customer mapping", async () => {
    const getUser = mock(async () => {
      throw new Error("should not load Stack user for conflicting Stripe identity");
    });
    selectResults = [[{ stackUserId: "user_local" }]];

    const result = await applySubscriptionUpdate(
      userSubscriptionUpdate({ status: "active" }) as never,
      {
        db: fakeDb() as never,
        stackApp: { getUser } as never,
      },
    );

    expect(result).toEqual({ skipped: true });
    expect(getUser).not.toHaveBeenCalled();
    expect(inserts.some((insert) => insert.table === stripeSubscriptions)).toBe(false);
    expect(updates.some((update) => update.table === stripeSubscriptions)).toBe(false);
  });

  test("creates a missing user subscription row from Stripe metadata", async () => {
    const update = mock(async () => undefined);
    const user = {
      id: "user_123",
      primaryEmail: "buyer@example.com",
      clientReadOnlyMetadata: {},
      update,
    };
    selectResults = [[], []];

    const result = await applySubscriptionUpdate(
      userSubscriptionUpdate({ status: "active" }) as never,
      {
        db: fakeDb() as never,
        stackApp: { getUser: async () => user } as never,
      },
    );

    expect(result).toEqual({ scope: "user", stackUserId: "user_123", isActive: true });
    expect(
      inserts.some(
        (insert) =>
          insert.table === stripeSubscriptions &&
          insert.values.id === "sub_user" &&
          insert.values.scope === "user" &&
          insert.values.stackUserId === "user_123",
      ),
    ).toBe(true);
    expect(update).toHaveBeenCalledWith({
      clientReadOnlyMetadata: { cmuxPlan: "pro" },
    });
  });

  test("creates a missing user subscription row when the customer mapping already exists", async () => {
    const user = {
      id: "user_123",
      primaryEmail: "buyer@example.com",
      clientReadOnlyMetadata: {},
      update: mock(async () => undefined),
    };
    selectResults = [[{ stackUserId: "user_123" }], []];

    const result = await applySubscriptionUpdate(
      userSubscriptionUpdate({ status: "active" }) as never,
      {
        db: fakeDb() as never,
        stackApp: { getUser: async () => user } as never,
      },
    );

    expect(result).toEqual({ scope: "user", stackUserId: "user_123", isActive: true });
    expect(
      inserts.some(
        (insert) =>
          insert.table === stripeSubscriptions &&
          insert.values.id === "sub_user" &&
          insert.values.scope === "user" &&
          insert.values.stackUserId === "user_123",
      ),
    ).toBe(true);
    expect(
      upsertUpdates.find((entry) => entry.table === stripeSubscriptions)?.values,
    ).not.toHaveProperty("id");
    expect(updates.some((update) => update.table === stripeSubscriptions)).toBe(false);
  });

  test("does not remove TestFlight access when a Team subscription lapses", async () => {
    const removeTester = mock(async () => undefined);
    const team = {
      id: "team_123",
      clientReadOnlyMetadata: { cmuxPlan: "team" },
      update: mock(async () => undefined),
    };
    selectResults = [[{ stackUserId: "owner_123" }], [{ stackUserId: "owner_123" }], []];

    const result = await applySubscriptionUpdate(
      {
        id: "sub_team",
        customer: "cus_team",
        status: "canceled",
        metadata: { stackTeamId: "team_123", plan: "team", app: "cmux" },
        cancel_at_period_end: false,
        items: {
          data: [
            {
              quantity: 7,
              current_period_end: 1_800_000_000,
              price: { id: "price_team" },
            },
          ],
        },
      } as never,
      {
        db: fakeDb() as never,
        stackApp: {
          getUser: async () => ({
            id: "owner_123",
            primaryEmail: "owner@example.com",
            clientReadOnlyMetadata: {},
            update: mock(async () => undefined),
          }),
          getTeam: async () => team,
        } as never,
        testflight: {
          isAscConfigured: () => true,
          removeTester,
        },
      },
    );

    expect(result).toEqual({ scope: "team", stackTeamId: "team_123", isActive: false });
    expect(removeTester).not.toHaveBeenCalled();
  });

  test("skips foreign subscription updates even when they carry a stackUserId", async () => {
    const result = await applySubscriptionUpdate(
      {
        id: "sub_foreign",
        customer: "cus_foreign",
        status: "active",
        metadata: { stackUserId: "user_123", app: "other" },
        cancel_at_period_end: false,
        items: { data: [{ current_period_end: 1_800_000_000, price: { id: "price_123" } }] },
      } as never,
      {
        db: fakeDb() as never,
        stackApp: { getUser: async () => {
          throw new Error("should not load Stack user");
        } } as never,
      },
    );

    expect(result).toEqual({ skipped: true });
    expect(inserts).toHaveLength(0);
    expect(updates).toHaveLength(0);
  });
});

function userSubscriptionUpdate({ status }: { status: string }) {
  return {
    id: "sub_user",
    customer: "cus_user",
    status,
    metadata: { stackUserId: "user_123", plan: "pro", app: "cmux" },
    cancel_at_period_end: false,
    items: {
      data: [
        {
          current_period_end: 1_800_000_000,
          price: { id: "price_123" },
        },
      ],
    },
  };
}
