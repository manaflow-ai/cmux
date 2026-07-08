import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";

import { cloudVmBillingGrants } from "../db/schema";

process.env.RESEND_API_KEY ??= "test-resend-key";
process.env.CMUX_FEEDBACK_FROM_EMAIL ??= "feedback@example.com";
process.env.CMUX_FEEDBACK_RATE_LIMIT_ID ??= "test-feedback-rate-limit";
process.env.STACK_SECRET_SERVER_KEY ??= "test-stack-secret";
process.env.NEXT_PUBLIC_STACK_PROJECT_ID ??= "test-stack-project";
process.env.NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY ??= "test-stack-publishable";

const ACCOUNT_USER_ID = "account-user-1";
const stackModule = await import("../app/lib/stack");
const realGetStackServerApp = stackModule.getStackServerApp;
const realIsStackConfigured = stackModule.isStackConfigured;
const dbClientModule = await import("../db/client");
const realCloudDb = dbClientModule.cloudDb;
const realCloseCloudDbForTests = dbClientModule.closeCloudDbForTests;
const stripeModule = await import("../services/billing/stripe");
const realIsStripeBillingConfigured = stripeModule.isStripeBillingConfigured;
const realStripe = stripeModule.stripe;
const storageModule = await import("../services/vault/storage");
const realDeleteObject = storageModule.deleteObject;
const workflowsModule = await import("../services/vms/workflows");
const realDestroyVm = workflowsModule.destroyVm;
const realListUserVms = workflowsModule.listUserVms;
const realRunVmWorkflow = workflowsModule.runVmWorkflow as (...args: unknown[]) => unknown;

const deleteStackUser = mock(async () => {
  routeEvents.push("stack-delete");
  if (stackDeleteError) throw stackDeleteError;
});
const updateStackUser = mock(async () => {
  routeEvents.push("metadata-update");
});
const getUser = mock(async () => stackUser(stackUserIds.shift()));
const transaction = mock(async (...args: unknown[]) => {
  const [callback] = args as [(tx: MockTransaction) => Promise<void>];
  routeEvents.push("transaction");
  await callback(mockTransaction);
});
const listUserVms = mock((...args: unknown[]) => {
  const [userId] = args as [string];
  return { kind: "listUserVms" as const, userId };
});
const destroyVm = mock((...args: unknown[]) => {
  const [input] = args as [{ readonly userId: string; readonly providerVmId: string }];
  return {
    kind: "destroyVm" as const,
    input,
  };
});
const runVmWorkflow = mock(async (...args: unknown[]) => {
  const [program] = args as [WorkflowProgram];
  if (program.kind === "listUserVms") {
    return [
      { providerVmId: "personal-vm-1" },
      { providerVmId: "personal-vm-2" },
    ];
  }
  return undefined;
});
const deleteObject = mock(async (...args: unknown[]) => {
  const [objectKey] = args as [string];
  deletedVaultObjects.push(objectKey);
  if (vaultDeleteError) throw vaultDeleteError;
});
const cancelSubscription = mock(async (...args: unknown[]) => {
  const [subscriptionId] = args as [string];
  cancelledStripeSubscriptions.push(subscriptionId);
  if (stripeCancelError) throw stripeCancelError;
});
const deleteCustomer = mock(async (...args: unknown[]) => {
  const [customerId] = args as [string];
  deletedStripeCustomers.push(customerId);
  if (stripeDeleteCustomerError) throw stripeDeleteCustomerError;
});

let deletedTableCount = 0;
let deletedTables: unknown[] = [];
let routeEvents: string[] = [];
let stackDeleteError: unknown = null;
let stackUserIds: Array<string | undefined> = [];
let selectResults: unknown[][] = [];
let deletedVaultObjects: string[] = [];
let vaultDeleteError: unknown = null;
let stripeConfigured = true;
let cancelledStripeSubscriptions: string[] = [];
let deletedStripeCustomers: string[] = [];
let stripeCancelError: unknown = null;
let stripeDeleteCustomerError: unknown = null;
let useAccountRouteStubs = false;
const originalConsoleError = console.error;
const consoleError = mock(() => {});

type WorkflowProgram =
  | { readonly kind: "listUserVms"; readonly userId: string }
  | { readonly kind: "destroyVm"; readonly input: { readonly userId: string; readonly providerVmId: string } };

type MockTransaction = {
  readonly delete: (table: unknown) => { readonly where: (condition: unknown) => Promise<void> };
};

const mockTransaction: MockTransaction = {
  delete: (table: unknown) => {
    deletedTables.push(table);
    deletedTableCount += 1;
    return { where: async () => {} };
  },
};

function nextSelectResult(): unknown[] {
  return selectResults.shift() ?? [];
}

const mockDb = {
  select: mock(() => ({
    from: () => ({
      where: async () => nextSelectResult(),
      innerJoin: () => ({
        where: async () => nextSelectResult(),
      }),
    }),
  })),
  transaction,
};

mock.module("../app/lib/stack", () => ({
  ...stackModule,
  getStackServerApp: () => useAccountRouteStubs ? { getUser } : realGetStackServerApp(),
  isStackConfigured: () => useAccountRouteStubs ? true : realIsStackConfigured(),
}));

mock.module("../db/client", () => ({
  ...dbClientModule,
  cloudDb: () => useAccountRouteStubs ? mockDb : realCloudDb(),
  closeCloudDbForTests: () => useAccountRouteStubs ? Promise.resolve() : realCloseCloudDbForTests(),
}));

mock.module("../services/vault/storage", () => ({
  ...storageModule,
  deleteObject: ((...args: Parameters<typeof realDeleteObject>) => {
    const [objectKey] = args;
    if (isAccountDeletionVaultObject(objectKey)) return deleteObject(...args);
    return realDeleteObject(...args);
  }) as typeof realDeleteObject,
}));

mock.module("../services/billing/stripe", () => ({
  ...stripeModule,
  isStripeBillingConfigured: () => useAccountRouteStubs
    ? stripeConfigured
    : realIsStripeBillingConfigured(),
  stripe: () => useAccountRouteStubs
    ? {
        subscriptions: { cancel: cancelSubscription },
        customers: { del: deleteCustomer },
      }
    : realStripe(),
}));

mock.module("../services/vms/workflows", () => ({
  ...workflowsModule,
  destroyVm: ((...args: Parameters<typeof realDestroyVm>) => {
    const [input] = args;
    if (input.userId === ACCOUNT_USER_ID) return destroyVm(...args);
    return realDestroyVm(...args);
  }) as typeof realDestroyVm,
  listUserVms: ((...args: Parameters<typeof realListUserVms>) => {
    const [userId] = args;
    if (userId === ACCOUNT_USER_ID) return listUserVms(...args);
    return realListUserVms(...args);
  }) as typeof realListUserVms,
  runVmWorkflow: ((...args: unknown[]) => {
    const [program] = args;
    if (isAccountDeletionWorkflowProgram(program)) return runVmWorkflow(...args);
    return realRunVmWorkflow(...args);
  }) as typeof workflowsModule.runVmWorkflow,
}));

const { DELETE } = await import("../app/api/account/route");

beforeAll(() => {
  useAccountRouteStubs = true;
});

afterAll(() => {
  useAccountRouteStubs = false;
});

beforeEach(() => {
  console.error = consoleError as typeof console.error;
  consoleError.mockClear();
  deleteStackUser.mockClear();
  updateStackUser.mockClear();
  getUser.mockClear();
  transaction.mockClear();
  mockDb.select.mockClear();
  listUserVms.mockClear();
  destroyVm.mockClear();
  runVmWorkflow.mockClear();
  deleteObject.mockClear();
  cancelSubscription.mockClear();
  deleteCustomer.mockClear();
  deletedTableCount = 0;
  deletedTables = [];
  routeEvents = [];
  stackDeleteError = null;
  stackUserIds = [];
  selectResults = [[], [], [], [], [], []];
  deletedVaultObjects = [];
  vaultDeleteError = null;
  stripeConfigured = true;
  cancelledStripeSubscriptions = [];
  deletedStripeCustomers = [];
  stripeCancelError = null;
  stripeDeleteCustomerError = null;
});

afterEach(() => {
  console.error = originalConsoleError;
});

describe("account deletion route", () => {
  test("requires native auth headers", async () => {
    const response = await DELETE(new Request("https://cmux.test/api/account", { method: "DELETE" }));

    expect(response.status).toBe(401);
    expect(deleteStackUser).not.toHaveBeenCalled();
    expect(transaction).not.toHaveBeenCalled();
  });

  test("destroys personal VMs, deletes cmux rows, then deletes the Stack user", async () => {
    selectResults = [
      [{ latestObjectKey: "vault/u/account-user-1/latest.jsonl.zst" }],
      [{ objectKey: "vault/u/account-user-1/snapshot.jsonl.zst" }],
      [{ objectKey: "vault/u/account-user-1/grant.jsonl.zst", uploadObjectKey: "vault/uploads/grant" }],
      [{ objectKey: "vault/u/account-user-1/tombstone.jsonl.zst", uploadObjectKey: "vault/uploads/tombstone" }],
      [{ id: "sub_user_active" }],
      [{ id: "cus_user" }],
    ];

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, destroyedVms: 2 });
    expect(listUserVms).toHaveBeenCalledWith("account-user-1");
    expect(destroyVm).toHaveBeenCalledTimes(2);
    expect(destroyVm).toHaveBeenCalledWith({ userId: "account-user-1", providerVmId: "personal-vm-1" });
    expect(destroyVm).toHaveBeenCalledWith({ userId: "account-user-1", providerVmId: "personal-vm-2" });
    expect(transaction).toHaveBeenCalledTimes(2);
    expect(deletedTableCount).toBeGreaterThan(10);
    expect(deletedTables).toContain(cloudVmBillingGrants);
    expect(deletedVaultObjects).toEqual([
      "vault/u/account-user-1/latest.jsonl.zst",
      "vault/u/account-user-1/snapshot.jsonl.zst",
      "vault/u/account-user-1/grant.jsonl.zst",
      "vault/uploads/grant",
      "vault/u/account-user-1/tombstone.jsonl.zst",
      "vault/uploads/tombstone",
    ]);
    expect(cancelledStripeSubscriptions).toEqual(["sub_user_active"]);
    expect(deletedStripeCustomers).toEqual(["cus_user"]);
    expect(updateStackUser).toHaveBeenCalledWith({
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
    });
    expect(deleteStackUser).toHaveBeenCalledTimes(1);
    expect(routeEvents).toEqual([
      "metadata-update",
      "transaction",
      "stack-delete",
      "transaction",
    ]);
  });

  test("does not delete rows or Stack user when vault object cleanup fails", async () => {
    selectResults = [
      [{ latestObjectKey: "vault/u/account-user-1/latest.jsonl.zst" }],
      [],
      [],
      [],
      [],
      [],
    ];
    vaultDeleteError = new Error("vault unavailable");

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({ error: "account_delete_failed" });
    expect(transaction).not.toHaveBeenCalled();
    expect(deleteStackUser).not.toHaveBeenCalled();
  });

  test("does not delete rows or Stack user when active billing cleanup cannot run", async () => {
    selectResults = [
      [],
      [],
      [],
      [],
      [{ id: "sub_user_active" }],
      [],
    ];
    stripeConfigured = false;

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({ error: "account_delete_failed" });
    expect(cancelSubscription).not.toHaveBeenCalled();
    expect(transaction).not.toHaveBeenCalled();
    expect(deleteStackUser).not.toHaveBeenCalled();
  });

  test("returns a retryable partial-failure response when Stack deletion fails after cmux data deletion", async () => {
    stackDeleteError = new Error(
      "raw eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhY2NvdW50LXVzZXItMSJ9.signaturePart leaked by upstream",
    );

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({
      error: "account_delete_retryable",
      retryable: true,
      destroyedVms: 2,
    });
    expect(transaction).toHaveBeenCalledTimes(1);
    expect(deletedTableCount).toBeGreaterThan(10);
    expect(updateStackUser).toHaveBeenCalledWith({
      clientReadOnlyMetadata: { cmuxAccountDeleting: true },
    });
    expect(deleteStackUser).toHaveBeenCalledTimes(1);
    expect(routeEvents).toEqual([
      "metadata-update",
      "transaction",
      "stack-delete",
    ]);
    expect(consoleError).toHaveBeenCalledWith(
      "account.delete.stack_user_failed_after_data_delete",
      "Error: raw [redacted] leaked by upstream",
    );
  });

  test("continues when Stripe resources are already in the deletion target state", async () => {
    selectResults = [
      [],
      [],
      [],
      [],
      [{ id: "sub_user_active" }],
      [{ id: "cus_user" }],
    ];
    stripeCancelError = new Error("This subscription has already been canceled");
    stripeDeleteCustomerError = { statusCode: 404, message: "No such customer" };

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, destroyedVms: 2 });
    expect(cancelledStripeSubscriptions).toEqual(["sub_user_active"]);
    expect(deletedStripeCustomers).toEqual(["cus_user"]);
    expect(transaction).toHaveBeenCalledTimes(2);
    expect(deleteStackUser).toHaveBeenCalledTimes(1);
  });

  test("rejects a Stack user mismatch before deleting data", async () => {
    stackUserIds = ["account-user-1", "other-user"];

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(401);
    expect(deleteStackUser).not.toHaveBeenCalled();
    expect(transaction).not.toHaveBeenCalled();
  });
});

function accountDeletionRequest(): Request {
  return new Request("https://cmux.test/api/account", {
    method: "DELETE",
    headers: {
      authorization: "Bearer access-token",
      "x-stack-refresh-token": "refresh-token",
    },
  });
}

function stackUser(id = "account-user-1") {
  return {
    id,
    displayName: null,
    primaryEmail: "account@example.com",
    clientReadOnlyMetadata: { cmuxPlan: "pro" },
    selectedTeam: null,
    listTeams: async () => [],
    update: updateStackUser,
    delete: deleteStackUser,
  };
}

function isAccountDeletionVaultObject(objectKey: string): boolean {
  return objectKey.startsWith(`vault/u/${ACCOUNT_USER_ID}/`) ||
    objectKey === "vault/uploads/grant" ||
    objectKey === "vault/uploads/tombstone";
}

function isAccountDeletionWorkflowProgram(program: unknown): boolean {
  if (!program || typeof program !== "object") return false;
  const candidate = program as {
    readonly kind?: unknown;
    readonly userId?: unknown;
    readonly input?: { readonly userId?: unknown };
  };
  if (candidate.kind === "listUserVms") return candidate.userId === ACCOUNT_USER_ID;
  if (candidate.kind === "destroyVm") return candidate.input?.userId === ACCOUNT_USER_ID;
  return false;
}
