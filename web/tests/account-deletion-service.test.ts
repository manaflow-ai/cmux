import { beforeEach, describe, expect, mock, test } from "bun:test";
import { cloudDb } from "../db/client";
import { cloudVmLeases, cloudVmSessions, cloudVmUsageEvents, cloudVms, subrouterTenants } from "../db/schema";
import type { ProviderId } from "../services/vms/drivers";
import {
  claimAccountDeletionProcessing,
  deleteCmuxAccountData,
  hasAccountDeletionTombstone,
} from "../services/account/deletion";
import { accountDeletionUserHash } from "../services/account/deletionLock";

const calls: string[] = [];
let providerBackedVmBatches: Array<Array<{ providerVmId: string | null }>> = [];
let providerlessProvisioningRows: Array<{ id: string }> = [];
let providerlessProvisioningSelectsRemaining = 0;
let providerlessCloudVmUpdateCount = 0;
let workflowErrorsByProviderId = new Map<string, unknown>();
let snapshotRows: Array<{ id: string; provider: ProviderId; snapshotId: string }> = [];
let snapshotDeleteError: unknown = null;
let subrouterTenantRows: Array<{ tenantId: string }> = [];
let subrouterRevokeError: unknown = null;

type DestroyAccountOwnedVmInput = { userId: string; providerVmId: string };
type DestroyAccountOwnedVmWorkflow = {
  kind: "destroy-account-owned-vm";
  input: DestroyAccountOwnedVmInput;
};
type DeleteVmSnapshotInput = { provider: ProviderId; snapshotId: string };
type DeleteVmSnapshotWorkflow = {
  kind: "delete-vm-snapshot";
  input: DeleteVmSnapshotInput;
};
type AccountDeletionTestWorkflow = DestroyAccountOwnedVmWorkflow | DeleteVmSnapshotWorkflow;

const destroyAccountOwnedVm = mock((input: unknown): DestroyAccountOwnedVmWorkflow => ({
  kind: "destroy-account-owned-vm",
  input: input as DestroyAccountOwnedVmInput,
}));
const deleteVmSnapshot = mock((input: unknown): DeleteVmSnapshotWorkflow => ({
  kind: "delete-vm-snapshot",
  input: input as DeleteVmSnapshotInput,
}));
const runVmWorkflow = mock(async (workflow: unknown) => {
  const vmWorkflow = workflow as AccountDeletionTestWorkflow;
  if (vmWorkflow.kind === "delete-vm-snapshot") {
    calls.push(`delete-snapshot:${vmWorkflow.input.provider}:${vmWorkflow.input.snapshotId}`);
    if (snapshotDeleteError) throw snapshotDeleteError;
    return;
  }
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
  providerlessProvisioningRows = [];
  providerlessProvisioningSelectsRemaining = 1;
  providerlessCloudVmUpdateCount = 0;
  workflowErrorsByProviderId = new Map();
  snapshotRows = [];
  snapshotDeleteError = null;
  subrouterTenantRows = [];
  subrouterRevokeError = null;
  destroyAccountOwnedVm.mockClear();
  deleteVmSnapshot.mockClear();
  runVmWorkflow.mockClear();
  deleteObject.mockClear();
});

describe("account deletion cleanup", () => {
  test("detects durable tombstones by hashed Stack user id", async () => {
    const runtime = {
      cloudDb: () => ({
        select: () => selectBuilder(() => [{
          userIdHash: accountDeletionUserHash("user-1"),
          status: "in_progress",
        }]),
      }) as unknown as ReturnType<typeof cloudDb>,
      deleteObject,
      destroyAccountOwnedVm,
      runVmWorkflow,
    };

    await expect(hasAccountDeletionTombstone({ userId: "user-1" }, runtime)).resolves.toBe(true);
    await expect(hasAccountDeletionTombstone({ userId: "other-user" }, runtime)).resolves.toBe(false);
  });

  test("blocks auth on retryable failed tombstones", async () => {
    const runtime = {
      cloudDb: () => ({
        select: () => selectBuilder(() => [{
          userIdHash: accountDeletionUserHash("user-1"),
          status: "failed",
        }]),
      }) as unknown as ReturnType<typeof cloudDb>,
      deleteObject,
      destroyAccountOwnedVm,
      runVmWorkflow,
    };

    await expect(hasAccountDeletionTombstone({ userId: "user-1" }, runtime)).resolves.toBe(true);
  });

  test("does not block auth on completed tombstones", async () => {
    const runtime = {
      cloudDb: () => ({
        select: () => selectBuilder(() => [{
          userIdHash: accountDeletionUserHash("user-1"),
          status: "completed",
        }]),
      }) as unknown as ReturnType<typeof cloudDb>,
      deleteObject,
      destroyAccountOwnedVm,
      runVmWorkflow,
    };

    await expect(hasAccountDeletionTombstone({ userId: "user-1" }, runtime)).resolves.toBe(false);
  });

  test("claims Stack-delete retries as in-progress work", async () => {
    let capturedStatus: unknown = null;
    const runtime = {
      cloudDb: () => ({
        transaction: async <T>(callback: (tx: ReturnType<typeof fakeClaimTransaction>) => Promise<T>) =>
          await callback(fakeClaimTransaction({
            rows: [{
              status: "stack_delete_pending",
              updatedAt: new Date(),
            }],
            onSet: (values) => {
              capturedStatus = values.status;
            },
          })),
      }) as unknown as ReturnType<typeof cloudDb>,
      deleteObject,
      destroyAccountOwnedVm,
      runVmWorkflow,
    };

    await expect(claimAccountDeletionProcessing({ userId: "user-1" }, runtime)).resolves.toBe("stack_delete_pending");

    expect(capturedStatus).toBe("stack_delete_in_progress");
  });

  test("does not claim fresh Stack-delete work already owned by another worker", async () => {
    let updateCalled = false;
    const runtime = {
      cloudDb: () => ({
        transaction: async <T>(callback: (tx: ReturnType<typeof fakeClaimTransaction>) => Promise<T>) =>
          await callback(fakeClaimTransaction({
            rows: [{
              status: "stack_delete_in_progress",
              updatedAt: new Date(),
            }],
            onSet: () => {
              updateCalled = true;
            },
          })),
      }) as unknown as ReturnType<typeof cloudDb>,
      deleteObject,
      destroyAccountOwnedVm,
      runVmWorkflow,
    };

    await expect(claimAccountDeletionProcessing({ userId: "user-1" }, runtime)).resolves.toBe(null);

    expect(updateCalled).toBe(false);
  });

  test("claims providerless VMs before destroying provider-backed account VMs", async () => {
    providerBackedVmBatches = [
      [{ providerVmId: "provider-vm-1" }],
      [],
    ];

    await deleteCmuxAccountData({
      userId: "user-1",
    }, fakeRuntime());

    expect(calls.slice(0, 3)).toEqual([
      "expire-stale-providerless-vms",
      "select-providerless-provisioning-vms",
      "claim-providerless-vms",
    ]);
    expect(calls.slice(3, 6)).toEqual([
      "select-provider-backed-vms",
      "destroy:user-1:provider-vm-1",
      "select-provider-backed-vms",
    ]);
    expect(destroyAccountOwnedVm).toHaveBeenCalledWith({
      userId: "user-1",
      providerVmId: "provider-vm-1",
    });
    expect(runVmWorkflow).toHaveBeenCalledTimes(1);
    expect(calls).toContain("delete-cloud-vm-sessions");
    expect(calls).toContain("delete-cloud-vm-leases");
    expect(calls).toContain("delete-personal-cloud-vms");
    expect(calls).toContain("anonymize-team-cloud-vms");
    expect(calls).toContain("anonymize-team-cloud-vm-usage-events");
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
      "expire-stale-providerless-vms",
      "select-providerless-provisioning-vms",
      "claim-providerless-vms",
      "select-provider-backed-vms",
    ]);
    expect(calls.slice(3, 5)).toEqual([
      "select-provider-backed-vms",
      "destroy-error:user-1:provider-vm-1",
    ]);
    expect(runVmWorkflow).toHaveBeenCalledTimes(1);
    expect(calls).toContain("delete-cloud-vm-sessions");
  });

  test("revokes and deletes the personal Subrouter tenant before local data deletion", async () => {
    subrouterTenantRows = [{ tenantId: "tenant-user-1" }];

    await deleteCmuxAccountData({
      userId: "user-1",
    }, fakeRuntime());

    expect(calls).toContain("select-subrouter-tenant");
    expect(calls).toContain("revoke-subrouter-tenant:tenant-user-1");
    expect(calls).toContain("delete-subrouter-tenant");
    expect(calls.indexOf("revoke-subrouter-tenant:tenant-user-1")).toBeLessThan(
      calls.indexOf("delete-subrouter-tenant"),
    );
    expect(calls.indexOf("delete-subrouter-tenant")).toBeLessThan(calls.indexOf("transaction"));
  });

  test("fails closed when personal Subrouter tenant revoke fails", async () => {
    subrouterTenantRows = [{ tenantId: "tenant-user-1" }];
    subrouterRevokeError = new Error("subrouter revoke failed");

    await expect(deleteCmuxAccountData({
      userId: "user-1",
    }, fakeRuntime())).rejects.toThrow("subrouter revoke failed");

    expect(calls).toContain("revoke-subrouter-tenant:tenant-user-1");
    expect(calls).not.toContain("delete-subrouter-tenant");
    expect(calls).not.toContain("transaction");
  });

  test("deletes personal Cloud VM snapshots before local usage rows", async () => {
    snapshotRows = [{
      id: "00000000-0000-4000-8000-000000000201",
      provider: "freestyle",
      snapshotId: "snapshot-user-1",
    }];

    await deleteCmuxAccountData({
      userId: "user-1",
    }, fakeRuntime());

    expect(calls).toContain("select-snapshot-usage-events");
    expect(calls).toContain("delete-snapshot:freestyle:snapshot-user-1");
    expect(calls).toContain("delete-snapshot-usage-events");
    expect(calls.indexOf("delete-snapshot:freestyle:snapshot-user-1")).toBeLessThan(
      calls.indexOf("delete-snapshot-usage-events"),
    );
    expect(calls.indexOf("delete-snapshot-usage-events")).toBeLessThan(calls.indexOf("transaction"));
  });

  test("fails closed when provider snapshot deletion fails", async () => {
    snapshotRows = [{
      id: "00000000-0000-4000-8000-000000000202",
      provider: "freestyle",
      snapshotId: "snapshot-user-1",
    }];
    snapshotDeleteError = new Error("provider snapshot delete failed");

    await expect(deleteCmuxAccountData({
      userId: "user-1",
    }, fakeRuntime())).rejects.toThrow("provider snapshot delete failed");

    expect(calls).toContain("delete-snapshot:freestyle:snapshot-user-1");
    expect(calls).not.toContain("delete-snapshot-usage-events");
    expect(calls).not.toContain("transaction");
  });

  test("marks stale providerless provisioning VMs before claiming providerless rows", async () => {
    await deleteCmuxAccountData({
      userId: "user-1",
    }, fakeRuntime());

    expect(calls.slice(0, 3)).toEqual([
      "expire-stale-providerless-vms",
      "select-providerless-provisioning-vms",
      "claim-providerless-vms",
    ]);
  });

  test("fails closed when provider-backed VM destruction fails", async () => {
    providerBackedVmBatches = [
      [{ providerVmId: "provider-vm-1" }],
      [{ providerVmId: "provider-vm-1" }],
      [{ providerVmId: "provider-vm-1" }],
      [{ providerVmId: "provider-vm-1" }],
    ];
    workflowErrorsByProviderId.set("provider-vm-1", new Error("provider destroy failed"));

    await expect(deleteCmuxAccountData({
      userId: "user-1",
    }, fakeRuntime())).rejects.toThrow("provider destroy failed");

    expect(runVmWorkflow).toHaveBeenCalledTimes(3);
    expect(calls).toContain("destroy-error:user-1:provider-vm-1");
    expect(calls).not.toContain("delete-cloud-vm-sessions");
  });

  test("continues a cleanup pass after one provider-backed VM fails", async () => {
    providerBackedVmBatches = [
      [{ providerVmId: "provider-vm-1" }, { providerVmId: "provider-vm-2" }],
      [{ providerVmId: "provider-vm-1" }],
      [{ providerVmId: "provider-vm-1" }],
      [{ providerVmId: "provider-vm-1" }],
    ];
    workflowErrorsByProviderId.set("provider-vm-1", new Error("provider destroy failed"));

    await expect(deleteCmuxAccountData({
      userId: "user-1",
    }, fakeRuntime())).rejects.toThrow("provider destroy failed");

    expect(calls).toContain("destroy-error:user-1:provider-vm-1");
    expect(calls).toContain("destroy:user-1:provider-vm-2");
    expect(calls).not.toContain("delete-cloud-vm-sessions");
  });

  test("retries later when a providerless VM is still provisioning", async () => {
    providerlessProvisioningRows = [{ id: "00000000-0000-4000-8000-000000000151" }];

    await expect(deleteCmuxAccountData({
      userId: "user-1",
    }, fakeRuntime())).rejects.toThrow("waiting for provisioning VMs to settle");

    expect(calls).toEqual(["expire-stale-providerless-vms", "select-providerless-provisioning-vms"]);
    expect(runVmWorkflow).not.toHaveBeenCalled();
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
    select: () => fakeDbSelectBuilder(),
    update: (table: unknown) => {
      if (table === cloudVms) {
        providerlessCloudVmUpdateCount += 1;
        return updateBuilder(
          providerlessCloudVmUpdateCount === 1
            ? "expire-stale-providerless-vms"
            : "claim-providerless-vms",
        );
      }
      return updateBuilder();
    },
    delete: (table: unknown) => {
      if (table === cloudVmUsageEvents) return writeBuilder("delete-snapshot-usage-events");
      if (table === subrouterTenants) return writeBuilder("delete-subrouter-tenant");
      return writeBuilder();
    },
    transaction: async (callback: (tx: ReturnType<typeof fakeTransaction>) => Promise<void>) => {
      calls.push("transaction");
      await callback(fakeTransaction());
    },
  };
}

function fakeDbSelectBuilder() {
  let table: unknown = null;
  const rows = () => {
    if (table === cloudVms) {
      if (providerlessProvisioningSelectsRemaining > 0) {
        providerlessProvisioningSelectsRemaining -= 1;
        calls.push("select-providerless-provisioning-vms");
        return providerlessProvisioningRows;
      }
      if (providerBackedVmBatches.length > 0) {
        calls.push("select-provider-backed-vms");
        return providerBackedVmBatches.shift() ?? [];
      }
    }
    if (table === subrouterTenants && subrouterTenantRows.length > 0) {
      calls.push("select-subrouter-tenant");
      const selected = subrouterTenantRows;
      subrouterTenantRows = [];
      return selected;
    }
    if (table === cloudVmUsageEvents && snapshotRows.length > 0) {
      calls.push("select-snapshot-usage-events");
      return snapshotRows.splice(0, 50);
    }
    return [];
  };
  const builder = {
    from: (fromTable: unknown) => {
      table = fromTable;
      return builder;
    },
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

function fakeRuntime() {
  return {
    cloudDb: () => fakeDb() as unknown as ReturnType<typeof cloudDb>,
    deleteObject,
    destroyAccountOwnedVm,
    deleteVmSnapshot,
    runVmWorkflow,
    revokeSubrouterTenant: async (tenantId: string) => {
      calls.push(`revoke-subrouter-tenant:${tenantId}`);
      if (subrouterRevokeError) throw subrouterRevokeError;
    },
  };
}

function fakeTransaction() {
  return {
    execute: async () => {
      calls.push("lock-account-deletion");
      return [];
    },
    update: (table: unknown) => {
      if (table === cloudVms) return updateBuilder("anonymize-team-cloud-vms");
      if (table === cloudVmUsageEvents) return updateBuilder("anonymize-team-cloud-vm-usage-events");
      return updateBuilder();
    },
    delete: (table: unknown) => {
      if (table === cloudVmSessions) return writeBuilder("delete-cloud-vm-sessions");
      if (table === cloudVmLeases) return writeBuilder("delete-cloud-vm-leases");
      if (table === cloudVms) return writeBuilder("delete-personal-cloud-vms");
      return writeBuilder();
    },
  };
}

function fakeClaimTransaction(input: {
  rows: Array<{ status: string; updatedAt: Date }>;
  onSet: (values: Record<string, unknown>) => void;
}) {
  return {
    execute: async () => [],
    select: () => selectBuilder(() => input.rows),
    update: () => updateReturningBuilder(input.onSet),
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

function updateReturningBuilder(onSet: (values: Record<string, unknown>) => void) {
  const builder = {
    set: (values: Record<string, unknown>) => {
      onSet(values);
      return builder;
    },
    where: () => builder,
    returning: async () => [{ userIdHash: "hash-1" }],
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
