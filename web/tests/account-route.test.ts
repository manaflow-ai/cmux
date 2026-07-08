import { beforeEach, describe, expect, mock, test } from "bun:test";

const deleteStackUser = mock(async () => {});
const getUser = mock(async () => stackUser(stackUserIds.shift()));
const transaction = mock(async (...args: unknown[]) => {
  const [callback] = args as [(tx: MockTransaction) => Promise<void>];
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

let deletedTableCount = 0;
let stackUserIds: Array<string | undefined> = [];

type WorkflowProgram =
  | { readonly kind: "listUserVms"; readonly userId: string }
  | { readonly kind: "destroyVm"; readonly input: { readonly userId: string; readonly providerVmId: string } };

type MockTransaction = {
  readonly delete: (table: unknown) => { readonly where: (condition: unknown) => Promise<void> };
};

const mockTransaction: MockTransaction = {
  delete: () => {
    deletedTableCount += 1;
    return { where: async () => {} };
  },
};

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
  stackServerApp: { getUser },
}));

mock.module("../db/client", () => ({
  cloudDb: () => ({ transaction }),
  closeCloudDbForTests: async () => {},
}));

mock.module("../services/vms/workflows", () => ({
  destroyVm,
  listUserVms,
  runVmWorkflow,
}));

const { DELETE } = await import("../app/api/account/route");

beforeEach(() => {
  deleteStackUser.mockClear();
  getUser.mockClear();
  transaction.mockClear();
  listUserVms.mockClear();
  destroyVm.mockClear();
  runVmWorkflow.mockClear();
  deletedTableCount = 0;
  stackUserIds = [];
});

describe("account deletion route", () => {
  test("requires native auth headers", async () => {
    const response = await DELETE(new Request("https://cmux.test/api/account", { method: "DELETE" }));

    expect(response.status).toBe(401);
    expect(deleteStackUser).not.toHaveBeenCalled();
    expect(transaction).not.toHaveBeenCalled();
  });

  test("destroys personal VMs, deletes cmux rows, then deletes the Stack user", async () => {
    const response = await DELETE(accountDeletionRequest());

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, destroyedVms: 2 });
    expect(listUserVms).toHaveBeenCalledWith("account-user-1");
    expect(destroyVm).toHaveBeenCalledTimes(2);
    expect(destroyVm).toHaveBeenCalledWith({ userId: "account-user-1", providerVmId: "personal-vm-1" });
    expect(destroyVm).toHaveBeenCalledWith({ userId: "account-user-1", providerVmId: "personal-vm-2" });
    expect(transaction).toHaveBeenCalledTimes(1);
    expect(deletedTableCount).toBeGreaterThan(10);
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
    selectedTeam: null,
    listTeams: async () => [],
    delete: deleteStackUser,
  };
}
