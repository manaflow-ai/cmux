import { beforeEach, describe, expect, mock, test } from "bun:test";

const calls: string[] = [];
let providerBackedVmBatches: Array<Array<{ providerVmId: string | null }>> = [];

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
  calls.push(`destroy:${vmWorkflow.input.userId}:${vmWorkflow.input.providerVmId}`);
});
const deleteObject = mock(async () => {});

mock.module("../services/vms/workflows", () => ({
  destroyAccountOwnedVm,
  runVmWorkflow,
}));

mock.module("../vault/storage", () => ({
  deleteObject,
}));

mock.module("../db/client", () => ({
  cloudDb: () => fakeDb(),
}));

const { deleteCmuxAccountData } = await import("../services/account/deletion");

beforeEach(() => {
  calls.length = 0;
  providerBackedVmBatches = [];
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
      teamIds: [],
    });

    expect(calls.slice(0, 4)).toEqual([
      "claim-providerless-vms",
      "select-provider-backed-vms",
      "destroy:user-1:provider-vm-1",
      "select-provider-backed-vms",
    ]);
    expect(destroyAccountOwnedVm).toHaveBeenCalledWith({
      userId: "user-1",
      providerVmId: "provider-vm-1",
    });
    expect(runVmWorkflow).toHaveBeenCalledTimes(1);
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
      teamIds: [],
    })).rejects.toThrow("Cloud VM account deletion cleanup did not settle");

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

function fakeTransaction() {
  return {
    update: () => updateBuilder(),
    delete: () => writeBuilder(),
  };
}

function selectBuilder(rows: () => unknown[]) {
  const builder = {
    from: () => builder,
    innerJoin: () => builder,
    where: async () => rows(),
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

function writeBuilder() {
  return {
    where: async () => [],
  };
}
