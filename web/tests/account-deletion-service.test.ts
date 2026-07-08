import { beforeEach, describe, expect, mock, test } from "bun:test";
import { cloudDb } from "../db/client";
import { cloudVmLeases, cloudVmSessions } from "../db/schema";
import { deleteCmuxAccountData } from "../services/account/deletion";

const calls: string[] = [];
let providerBackedVmBatches: Array<Array<{ providerVmId: string | null }>> = [];
let workflowErrorsByProviderId = new Map<string, unknown>();

type DestroyAccountOwnedVmInput = { userId: string; providerVmId: string };
type DestroyAccountOwnedVmWorkflow = {
  kind: "destroy-account-owned-vm";
  input: DestroyAccountOwnedVmInput;
};

const destroyAccountOwnedVm = mock((input: unknown): DestroyAccountOwnedVmWorkflow => ({
  kind: "destroy-account-owned-vm",
  input: input as DestroyAccountOwnedVmInput,
}));
const runVmWorkflow = mock(async (workflow: unknown) => {
  const vmWorkflow = workflow as DestroyAccountOwnedVmWorkflow;
  const workflowError = workflowErrorsByProviderId.get(vmWorkflow.input.providerVmId);
  if (workflowError) {
    calls.push(`destroy-error:${vmWorkflow.input.userId}:${vmWorkflow.input.providerVmId}`);
    throw workflowError;
  }
  calls.push(`destroy:${vmWorkflow.input.userId}:${vmWorkflow.input.providerVmId}`);
});
const deleteObject = mock(async () => {});

beforeEach(() => {
  calls.length = 0;
  providerBackedVmBatches = [];
  workflowErrorsByProviderId = new Map();
  destroyAccountOwnedVm.mockClear();
  runVmWorkflow.mockClear();
  deleteObject.mockClear();
});

describe("account deletion cleanup", () => {
  test("claims providerless VMs before destroying provider-backed account VMs", async () => {
    providerBackedVmBatches = [
      [{ providerVmId: "provider-vm-1" }],
      [],
    ];

    await deleteCmuxAccountData({
      userId: "user-1",
    }, fakeRuntime());

    expect(calls.slice(0, 3)).toEqual([
      "claim-providerless-vms",
      "select-provider-backed-vms",
      "destroy:user-1:provider-vm-1",
    ]);
    expect(calls.slice(2, 5)).toEqual([
      "destroy:user-1:provider-vm-1",
      "select-provider-backed-vms",
      "transaction",
    ]);
    expect(destroyAccountOwnedVm).toHaveBeenCalledWith({
      userId: "user-1",
      providerVmId: "provider-vm-1",
    });
    expect(runVmWorkflow).toHaveBeenCalledTimes(1);
    expect(calls).toContain("delete-cloud-vm-sessions");
    expect(calls).toContain("delete-cloud-vm-leases");
  });

  test("rechecks when a provider-backed VM disappears during account deletion", async () => {
    providerBackedVmBatches = [
      [{ providerVmId: "provider-vm-1" }],
      [],
    ];
    workflowErrorsByProviderId.set(
      "provider-vm-1",
      Object.assign(new Error("not found"), { _tag: "VmNotFoundError" }),
    );

    await deleteCmuxAccountData({
      userId: "user-1",
    }, fakeRuntime());

    expect(calls.slice(0, 4)).toEqual([
      "claim-providerless-vms",
      "select-provider-backed-vms",
      "destroy-error:user-1:provider-vm-1",
      "select-provider-backed-vms",
    ]);
    expect(runVmWorkflow).toHaveBeenCalledTimes(1);
    expect(calls).toContain("delete-cloud-vm-sessions");
  });

  test("fails closed when provider-backed VM destruction fails", async () => {
    providerBackedVmBatches = [
      [{ providerVmId: "provider-vm-1" }],
      [],
    ];
    workflowErrorsByProviderId.set("provider-vm-1", new Error("provider destroy failed"));

    await expect(deleteCmuxAccountData({
      userId: "user-1",
    }, fakeRuntime())).rejects.toThrow("provider destroy failed");

    expect(runVmWorkflow).toHaveBeenCalledTimes(1);
    expect(calls).toContain("destroy-error:user-1:provider-vm-1");
    expect(calls).not.toContain("delete-cloud-vm-sessions");
  });

  test("fails closed when provider-backed VMs keep appearing", async () => {
    providerBackedVmBatches = [
      [{ providerVmId: "provider-vm-1" }],
      [{ providerVmId: "provider-vm-2" }],
      [{ providerVmId: "provider-vm-3" }],
      [{ providerVmId: "provider-vm-4" }],
    ];

    await expect(deleteCmuxAccountData({
      userId: "user-1",
    }, fakeRuntime())).rejects.toThrow("Cloud VM account deletion cleanup did not settle");

    expect(runVmWorkflow).toHaveBeenCalledTimes(3);
    expect(calls).toContain("destroy:user-1:provider-vm-1");
    expect(calls).toContain("destroy:user-1:provider-vm-2");
    expect(calls).toContain("destroy:user-1:provider-vm-3");
  });
});

function fakeDb() {
  return {
    select: () => {
      return selectBuilder(() => {
        if (providerBackedVmBatches.length > 0) {
          calls.push("select-provider-backed-vms");
          return providerBackedVmBatches.shift() ?? [];
        }
        return [];
      });
    },
    update: () => updateBuilder("claim-providerless-vms"),
    delete: () => writeBuilder(),
    transaction: async (callback: (tx: ReturnType<typeof fakeTransaction>) => Promise<void>) => {
      calls.push("transaction");
      await callback(fakeTransaction());
    },
  };
}

function fakeRuntime() {
  return {
    cloudDb: () => fakeDb() as unknown as ReturnType<typeof cloudDb>,
    deleteObject,
    destroyAccountOwnedVm,
    runVmWorkflow,
  };
}

function fakeTransaction() {
  return {
    update: () => updateBuilder(),
    delete: (table: unknown) => {
      if (table === cloudVmSessions) return writeBuilder("delete-cloud-vm-sessions");
      if (table === cloudVmLeases) return writeBuilder("delete-cloud-vm-leases");
      return writeBuilder();
    },
  };
}

function selectBuilder(rows: () => unknown[]) {
  const builder = {
    from: () => builder,
    innerJoin: () => builder,
    where: () => builder,
    limit: async () => rows(),
    then: (
      resolve: (value: unknown[]) => unknown,
      reject: (reason: unknown) => unknown,
    ) => Promise.resolve(rows()).then(resolve, reject),
  };
  return builder;
}

function updateBuilder(label?: string) {
  const builder = {
    set: () => builder,
    where: async () => {
      if (label) calls.push(label);
      return [];
    },
  };
  return builder;
}

function writeBuilder(label?: string) {
  return {
    where: async () => {
      if (label) calls.push(label);
      return [];
    },
  };
}
