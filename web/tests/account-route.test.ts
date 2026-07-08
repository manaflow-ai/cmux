import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";

import { cloudVmBillingGrants } from "../db/schema";

const deleteStackUser = mock(async () => {
  routeEvents.push("stack-delete");
  if (stackDeleteError) throw stackDeleteError;
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
});
const deleteCustomer = mock(async (...args: unknown[]) => {
  const [customerId] = args as [string];
  deletedStripeCustomers.push(customerId);
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
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
  stackServerApp: { getUser },
}));

mock.module("../db/client", () => ({
  cloudDb: () => mockDb,
  closeCloudDbForTests: async () => {},
}));

mock.module("../services/vault/storage", () => ({
  deleteObject,
}));

mock.module("../services/billing/stripe", () => ({
  isStripeBillingConfigured: () => stripeConfigured,
  stripe: () => ({
    subscriptions: { cancel: cancelSubscription },
    customers: { del: deleteCustomer },
  }),
}));

mock.module("../services/vms/workflows", () => ({
  destroyVm,
  listUserVms,
  runVmWorkflow,
}));

const { DELETE } = await import("../app/api/account/route");

beforeEach(() => {
  console.error = consoleError as typeof console.error;
  consoleError.mockClear();
  deleteStackUser.mockClear();
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
    expect(transaction).toHaveBeenCalledTimes(1);
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
    expect(deleteStackUser).toHaveBeenCalledTimes(1);
    expect(routeEvents).toEqual(["transaction", "stack-delete"]);
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
    stackDeleteError = new Error("Bearer access-token leaked by upstream");

    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(500);
    expect(await response.json()).toEqual({
      error: "account_stack_delete_failed_after_data_delete",
      retryable: true,
      destroyedVms: 2,
    });
    expect(transaction).toHaveBeenCalledTimes(1);
    expect(deletedTableCount).toBeGreaterThan(10);
    expect(deleteStackUser).toHaveBeenCalledTimes(1);
    expect(routeEvents).toEqual(["transaction", "stack-delete"]);
    expect(consoleError).toHaveBeenCalledWith(
      "account.delete.stack_user_failed_after_data_delete",
      "Error: [redacted] leaked by upstream",
    );
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
    selectedTeam: null,
    listTeams: async () => [],
    delete: deleteStackUser,
  };
}
