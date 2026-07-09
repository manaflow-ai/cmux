import { beforeEach, describe, expect, mock, test } from "bun:test";
import { PgDialect } from "drizzle-orm/pg-core";
import { cloudDb } from "../db/client";
import {
  accountDeletionTombstones,
  cloudVmLeases,
  cloudVmSessions,
  cloudVmUsageEvents,
  cloudVms,
  devices,
  stripeCustomers,
  stripeSubscriptions,
  subrouterTenants,
  vaultSessions,
  vaultSnapshots,
  vaultUploadGrants,
  vaultUploadTombstones,
} from "../db/schema";
import type { ProviderId } from "../services/vms/drivers";
import {
  AccountDeletionMutationBlockedError,
  assertAccountDeletionCanStart,
  claimAccountDeletionProcessing,
  deleteCmuxAccountData,
  hasAccountDeletionTombstone,
  isStackAccountDeletionBlocked,
  withAccountDeletionUserMutationLock,
} from "../services/account/deletion";
import { PRO_PLAN_ID, TEAM_PLAN_ID } from "../services/billing/pro";
import { accountDeletionUserHash } from "../services/account/deletionLock";

type StripeClient = ReturnType<typeof import("../services/billing/stripe").stripe>;
type StripeCustomerRow = {
  readonly id: string;
  readonly stackTeamId: string | null;
  readonly stackUserId: string | null;
};
type StripeSubscriptionRow = {
  readonly id: string;
  readonly plan: string | null;
  readonly scope: string;
  readonly stackTeamId: string | null;
  readonly stackUserId: string | null;
  readonly status: string;
};
type StripeUpdateParams = {
  readonly address?: string;
  readonly email?: string;
  readonly metadata?: Record<string, string>;
  readonly name?: string;
  readonly phone?: string;
  readonly shipping?: string;
};

const calls: string[] = [];
let providerBackedVmBatches: Array<Array<{
  userId: string;
  provider: ProviderId;
  providerVmId: string | null;
}>> = [];
let providerlessProvisioningRows: Array<{ id: string }> = [];
let providerlessProvisioningSelectsRemaining = 0;
let providerlessCloudVmUpdateCount = 0;
let workflowErrorsByProviderId = new Map<string, unknown>();
let snapshotRows: Array<{
  id: string;
  eventType?: string;
  provider: ProviderId;
  snapshotId: string | null;
  createdAt?: Date;
}> = [];
let execPendingRows: Array<{ id: string }> = [];
let snapshotDeleteError: unknown = null;
let identityLeaseRows: Array<{ id: string; provider: ProviderId; providerIdentityHandle: string | null }> = [];
let identityLeaseRevokeError: unknown = null;
let subrouterTenantRows: Array<{ tenantId: string }> = [];
let subrouterRevokeError: unknown = null;
let updateSets: Array<{ readonly label: string; readonly values: Record<string, unknown> }> = [];
let stripeCustomerRows: StripeCustomerRow[] = [];
let stripeSubscriptionRows: StripeSubscriptionRow[] = [];
let stripeRemoteSubscriptionStatuses = new Map<string, string>();
let stripeCustomerUpdates: Array<{ readonly id: string; readonly params: StripeUpdateParams }> = [];
let stripeSubscriptionUpdates: Array<{ readonly id: string; readonly params: StripeUpdateParams }> = [];
let stripeSubscriptionCancels: string[] = [];
let stripeBillingConfigured = true;
let vaultSnapshotRows: Array<{ id: string; objectKey: string }> = [];
let vaultUploadGrantRows: Array<{ id: string; objectKey: string; uploadObjectKey: string }> = [];
let vaultUploadTombstoneRows: Array<{ id: string; objectKey: string; uploadObjectKey: string }> = [];
let deviceDeleteConditions: unknown[] = [];
let cloudVmUsageEventDeleteConditions: unknown[] = [];
let accountDeletionTombstoneRows: Array<{ status: string }> = [];

type DestroyAccountOwnedVmInput = { userId: string; provider: ProviderId; providerVmId: string };
type DestroyAccountOwnedVmWorkflow = {
  kind: "destroy-account-owned-vm";
  input: DestroyAccountOwnedVmInput;
};
type DeleteVmSnapshotInput = { provider: ProviderId; snapshotId: string };
type DeleteVmSnapshotWorkflow = {
  kind: "delete-vm-snapshot";
  input: DeleteVmSnapshotInput;
};
type RevokeVmIdentityLeaseInput = { provider: ProviderId; identityHandle: string };
type RevokeVmIdentityLeaseWorkflow = {
  kind: "revoke-vm-identity-lease";
  input: RevokeVmIdentityLeaseInput;
};
type AccountDeletionTestWorkflow =
  | DestroyAccountOwnedVmWorkflow
  | DeleteVmSnapshotWorkflow
  | RevokeVmIdentityLeaseWorkflow;

function providerBackedVm(
  providerVmId: string,
  provider: ProviderId = "freestyle",
  userId = "user-1",
) {
  return { userId, provider, providerVmId };
}

const destroyAccountOwnedVm = mock((input: unknown): DestroyAccountOwnedVmWorkflow => ({
  kind: "destroy-account-owned-vm",
  input: input as DestroyAccountOwnedVmInput,
}));
const deleteVmSnapshot = mock((input: unknown): DeleteVmSnapshotWorkflow => ({
  kind: "delete-vm-snapshot",
  input: input as DeleteVmSnapshotInput,
}));
const revokeVmIdentityLease = mock((input: unknown): RevokeVmIdentityLeaseWorkflow => ({
  kind: "revoke-vm-identity-lease",
  input: input as RevokeVmIdentityLeaseInput,
}));
const runVmWorkflow = mock(async (workflow: unknown) => {
  const vmWorkflow = workflow as AccountDeletionTestWorkflow;
  if (vmWorkflow.kind === "delete-vm-snapshot") {
    calls.push(`delete-snapshot:${vmWorkflow.input.provider}:${vmWorkflow.input.snapshotId}`);
    if (snapshotDeleteError) throw snapshotDeleteError;
    return;
  }
  if (vmWorkflow.kind === "revoke-vm-identity-lease") {
    calls.push(`revoke-identity:${vmWorkflow.input.provider}:${vmWorkflow.input.identityHandle}`);
    if (identityLeaseRevokeError) throw identityLeaseRevokeError;
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
const updateStripeCustomer = mock(async (...args: unknown[]) => {
  const [id, params] = args as [string, StripeUpdateParams];
  stripeCustomerUpdates.push({ id, params });
});
const retrieveStripeSubscription = mock(async (...args: unknown[]) => {
  const [id] = args as [string];
  return {
    id,
    status: stripeRemoteSubscriptionStatuses.get(id) ?? "active",
  };
});
const updateStripeSubscription = mock(async (...args: unknown[]) => {
  const [id, params] = args as [string, StripeUpdateParams];
  stripeSubscriptionUpdates.push({ id, params });
});
const cancelStripeSubscription = mock(async (...args: unknown[]) => {
  const [id] = args as [string];
  stripeSubscriptionCancels.push(id);
});

beforeEach(() => {
  calls.length = 0;
  providerBackedVmBatches = [];
  providerlessProvisioningRows = [];
  providerlessProvisioningSelectsRemaining = 1;
  providerlessCloudVmUpdateCount = 0;
  workflowErrorsByProviderId = new Map();
  snapshotRows = [];
  execPendingRows = [];
  snapshotDeleteError = null;
  identityLeaseRows = [];
  identityLeaseRevokeError = null;
  subrouterTenantRows = [];
  subrouterRevokeError = null;
  updateSets = [];
  stripeCustomerRows = [];
  stripeSubscriptionRows = [];
  stripeRemoteSubscriptionStatuses = new Map();
  stripeCustomerUpdates = [];
  stripeSubscriptionUpdates = [];
  stripeSubscriptionCancels = [];
  stripeBillingConfigured = true;
  vaultSnapshotRows = [];
  vaultUploadGrantRows = [];
  vaultUploadTombstoneRows = [];
  deviceDeleteConditions = [];
  cloudVmUsageEventDeleteConditions = [];
  accountDeletionTombstoneRows = [];
  destroyAccountOwnedVm.mockClear();
  deleteVmSnapshot.mockClear();
  revokeVmIdentityLease.mockClear();
  runVmWorkflow.mockClear();
  deleteObject.mockClear();
  updateStripeCustomer.mockClear();
  retrieveStripeSubscription.mockClear();
  updateStripeSubscription.mockClear();
  cancelStripeSubscription.mockClear();
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

  test("does not block auth on retryable failed tombstones", async () => {
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

    await expect(hasAccountDeletionTombstone({ userId: "user-1" }, runtime)).resolves.toBe(false);
  });

  test("does not block auth on stale Stack metadata after a failed tombstone", async () => {
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

    await expect(isStackAccountDeletionBlocked({
      id: "user-1",
      clientReadOnlyMetadata: { cmuxAccountDeletionInProgress: true },
    }, runtime)).resolves.toBe(false);
  });

  test("blocks auth on completed tombstones", async () => {
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

    await expect(hasAccountDeletionTombstone({ userId: "user-1" }, runtime)).resolves.toBe(true);
  });

  test("blocks user mutations under the deletion lock when a tombstone appears", async () => {
    const db = fakeAccountDeletionMutationDb([{
      userIdHash: accountDeletionUserHash("user-1"),
      status: "pending",
    }]);

    await expect(withAccountDeletionUserMutationLock(db, "user-1", async () => {
      calls.push("write-user-data");
    })).rejects.toBeInstanceOf(AccountDeletionMutationBlockedError);

    expect(calls).toEqual(["transaction", "lock-account-deletion"]);
  });

  test("blocks user mutations after account deletion completed", async () => {
    const db = fakeAccountDeletionMutationDb([{
      userIdHash: accountDeletionUserHash("user-1"),
      status: "completed",
    }]);

    await expect(withAccountDeletionUserMutationLock(db, "user-1", async () => {
      calls.push("write-user-data");
    })).rejects.toBeInstanceOf(AccountDeletionMutationBlockedError);

    expect(calls).toEqual(["transaction", "lock-account-deletion"]);
  });

  test("runs user mutations under the deletion lock without a blocking tombstone", async () => {
    const db = fakeAccountDeletionMutationDb([{
      userIdHash: accountDeletionUserHash("user-1"),
      status: "failed",
    }]);

    await withAccountDeletionUserMutationLock(db, "user-1", async () => {
      calls.push("write-user-data");
    });

    expect(calls).toEqual(["transaction", "lock-account-deletion", "write-user-data"]);
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

    await expect(claimAccountDeletionProcessing({ userId: "user-1" }, runtime)).resolves.toMatchObject({
      status: "stack_delete_pending",
      teamScopeStored: false,
    });

    expect(capturedStatus).toBe("stack_delete_in_progress");
  });

  test("returns the persisted team scope when claiming deletion work", async () => {
    const runtime = {
      cloudDb: () => ({
        transaction: async <T>(callback: (tx: ReturnType<typeof fakeClaimTransaction>) => Promise<T>) =>
          await callback(fakeClaimTransaction({
            rows: [{
              userId: "user-1",
              userIdHash: accountDeletionUserHash("user-1"),
              status: "pending",
              updatedAt: new Date(),
              scope: {
                ownedTeamIds: ["team-owned", "team-owned", " "],
                retainedTeamBillingOwners: [
                  { stackTeamId: "team-shared", stackUserId: "user-2" },
                  { stackTeamId: "team-owned", stackUserId: "user-3" },
                  { stackTeamId: "team-self", stackUserId: "user-1" },
                ],
              },
            }],
            onSet: () => {},
          })),
      }) as unknown as ReturnType<typeof cloudDb>,
      deleteObject,
      destroyAccountOwnedVm,
      runVmWorkflow,
    };

    await expect(claimAccountDeletionProcessing({ userId: "user-1" }, runtime)).resolves.toMatchObject({
      status: "pending",
      teamScopeStored: true,
      ownedTeamIds: ["team-owned"],
      retainedTeamBillingOwners: [{ stackTeamId: "team-shared", stackUserId: "user-2" }],
    });
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
      [providerBackedVm("provider-vm-1")],
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
      provider: "freestyle",
      providerVmId: "provider-vm-1",
    });
    expect(runVmWorkflow).toHaveBeenCalledTimes(1);
    expect(calls).toContain("delete-cloud-vm-sessions");
    expect(calls).toContain("delete-cloud-vm-leases");
    expect(calls).toContain("delete-personal-cloud-vms");
    expect(calls).toContain("anonymize-team-cloud-vms");
    expect(calls).toContain("anonymize-team-cloud-vm-usage-events");
  });

  test("destroys owned-team Cloud VMs created by another user", async () => {
    providerBackedVmBatches = [
      [providerBackedVm("provider-team-vm-1", "freestyle", "former-member")],
      [],
    ];

    await deleteCmuxAccountData({
      userId: "user-1",
      ownedTeamIds: ["team-owned-1"],
    }, fakeRuntime());

    expect(destroyAccountOwnedVm).toHaveBeenCalledWith({
      userId: "former-member",
      provider: "freestyle",
      providerVmId: "provider-team-vm-1",
    });
    expect(calls).toContain("destroy:former-member:provider-team-vm-1");
  });

  test("deletes owned team and retained user device registry rows", async () => {
    await deleteCmuxAccountData({
      userId: "user-1",
      ownedTeamIds: ["team-owned-1"],
      retainedTeamBillingOwners: [{
        stackTeamId: "team-shared",
        stackUserId: "user-2",
      }],
    }, fakeRuntime());

    expect(calls).toContain("delete-user-devices");
    expect(calls).not.toContain("anonymize-retained-team-devices");
    const deletedDeviceColumns = conditionColumnNames(deviceDeleteConditions[0]);
    expect(deletedDeviceColumns).toContain("user_id");
    expect(deletedDeviceColumns).toContain("team_id");
  });

  test("deletes active vault upload grant rows after their objects are removed", async () => {
    vaultUploadGrantRows = [{
      id: "grant-row-1",
      objectKey: "vault/u/user-1/grant.jsonl.zst",
      uploadObjectKey: "vault/uploads/grant",
    }];

    await expect(deleteCmuxAccountData({
      userId: "user-1",
    }, fakeRuntime())).rejects.toThrow("vault cleanup has more objects to delete");

    expect(deleteObject).toHaveBeenCalledWith("vault/u/user-1/grant.jsonl.zst");
    expect(deleteObject).toHaveBeenCalledWith("vault/uploads/grant");
    expect(calls).toContain("delete-vault-upload-grants");
    expect(calls).not.toContain("delete-vault-upload-tombstones");
    expect(calls).not.toContain("delete-vault-sessions");
  });

  test("deletes active vault upload tombstone rows after their objects are removed", async () => {
    vaultUploadTombstoneRows = [{
      id: "tombstone-row-1",
      objectKey: "vault/u/user-1/tombstone.jsonl.zst",
      uploadObjectKey: "vault/uploads/tombstone",
    }];

    await expect(deleteCmuxAccountData({
      userId: "user-1",
    }, fakeRuntime())).rejects.toThrow("vault cleanup has more objects to delete");

    expect(deleteObject).toHaveBeenCalledWith("vault/u/user-1/tombstone.jsonl.zst");
    expect(deleteObject).toHaveBeenCalledWith("vault/uploads/tombstone");
    expect(calls).toContain("delete-vault-upload-tombstones");
    expect(calls).not.toContain("delete-vault-sessions");
  });

  test("rechecks when a provider-backed VM disappears during account deletion", async () => {
    providerBackedVmBatches = [
      [providerBackedVm("provider-vm-1")],
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

  test("revokes singleton Stack team Subrouter tenants during account deletion", async () => {
    subrouterTenantRows = [
      { tenantId: "tenant-user-1" },
      { tenantId: "tenant-team-personal" },
    ];

    await deleteCmuxAccountData({
      userId: "user-1",
      ownedTeamIds: ["team-personal"],
    }, fakeRuntime());

    expect(calls).toContain("revoke-subrouter-tenant:tenant-user-1");
    expect(calls).toContain("revoke-subrouter-tenant:tenant-team-personal");
    expect(calls.indexOf("revoke-subrouter-tenant:tenant-team-personal")).toBeLessThan(
      calls.indexOf("transaction"),
    );
  });

  test("bounds vault object cleanup to one committed batch before local row purge", async () => {
    vaultSnapshotRows = [{ id: "snapshot-row-1", objectKey: "vault/snapshot-1.zst" }];

    await expect(deleteCmuxAccountData({
      userId: "user-1",
    }, fakeRuntime())).rejects.toThrow("vault cleanup has more objects to delete");

    expect(deleteObject).toHaveBeenCalledWith("vault/snapshot-1.zst");
    expect(calls).toContain("delete-vault-snapshots");
    expect(calls).not.toContain("delete-vault-sessions");
    expect(calls).not.toContain("delete-user-devices");

    calls.length = 0;
    await expect(deleteCmuxAccountData({
      userId: "user-1",
    }, fakeRuntime())).resolves.toBeUndefined();
    expect(calls).toContain("delete-vault-sessions");
    expect(calls).toContain("delete-user-devices");
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
      eventType: "vm.snapshot.created",
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

  test("revokes active VM identity leases before deleting local lease rows", async () => {
    identityLeaseRows = [{
      id: "00000000-0000-4000-8000-000000000301",
      provider: "freestyle",
      providerIdentityHandle: "identity-shared-1",
    }];

    await deleteCmuxAccountData({
      userId: "user-1",
    }, fakeRuntime());

    expect(calls).toContain("select-identity-leases");
    expect(calls).toContain("revoke-identity:freestyle:identity-shared-1");
    expect(calls).toContain("mark-identity-leases-revoked");
    expect(calls.indexOf("mark-identity-leases-revoked")).toBeLessThan(
      calls.indexOf("transaction"),
    );
    expect(calls.indexOf("transaction")).toBeLessThan(calls.indexOf("delete-cloud-vm-leases"));
  });

  test("revokes active VM identity leases before destroying provider-backed VMs", async () => {
    identityLeaseRows = [{
      id: "00000000-0000-4000-8000-000000000304",
      provider: "freestyle",
      providerIdentityHandle: "identity-before-destroy",
    }];
    providerBackedVmBatches = [
      [providerBackedVm("provider-vm-with-many-leases")],
      [],
    ];

    await deleteCmuxAccountData({
      userId: "user-1",
    }, fakeRuntime());

    expect(calls).toContain("revoke-identity:freestyle:identity-before-destroy");
    expect(calls).toContain("destroy:user-1:provider-vm-with-many-leases");
    expect(calls.indexOf("mark-identity-leases-revoked")).toBeLessThan(
      calls.indexOf("destroy:user-1:provider-vm-with-many-leases"),
    );
  });

  test("waits for in-flight VM exec reservations before destroying provider-backed VMs", async () => {
    execPendingRows = [{ id: "exec-pending" }];
    providerBackedVmBatches = [
      [providerBackedVm("provider-vm-with-exec")],
    ];

    await expect(deleteCmuxAccountData({
      userId: "user-1",
    }, fakeRuntime())).rejects.toThrow("Cloud VM account deletion cleanup is waiting for an in-flight exec to settle");

    expect(calls).toContain("select-exec-usage-events");
    expect(calls).not.toContain("destroy:user-1:provider-vm-with-exec");
  });

  test("keeps other users' usage events on owned billing teams while cleaning the deleted user's usage", async () => {
    await deleteCmuxAccountData({
      userId: "user-1",
      ownedTeamIds: ["team-owned-1"],
    }, fakeRuntime());

    expect(calls).toContain("delete-account-owned-cloud-vm-usage-events");
    expect(calls).toContain("anonymize-team-cloud-vm-usage-events");

    const deleteCondition = cloudVmUsageEventDeleteConditions.at(0);
    expect(deleteCondition).toBeDefined();
    const renderedDeleteCondition = renderConditionSql(deleteCondition);
    expect(renderedDeleteCondition.sql).toContain(`"cloud_vm_usage_events"."user_id" = $1`);
    expect(renderedDeleteCondition.sql).toContain(`"cloud_vm_usage_events"."billing_team_id" in ($2, $3)`);
    expect(renderedDeleteCondition.params).toEqual(["user-1", "user-1", "team-owned-1"]);

    const anonymizeUsageUpdate = updateSets.find((entry) =>
      entry.label === "anonymize-team-cloud-vm-usage-events"
    );
    expect(anonymizeUsageUpdate?.values.userId).toMatch(/^deleted_[0-9a-f]{24}$/);
  });

  test("marks blank VM identity lease handles without retrying forever", async () => {
    identityLeaseRows = [{
      id: "00000000-0000-4000-8000-000000000303",
      provider: "freestyle",
      providerIdentityHandle: "   ",
    }];

    await deleteCmuxAccountData({
      userId: "user-1",
    }, fakeRuntime());

    expect(calls).toContain("select-identity-leases");
    expect(calls).not.toContain("revoke-identity:freestyle:");
    expect(calls).toContain("mark-identity-leases-revoked");
    expect(calls).toContain("delete-cloud-vm-leases");
  });

  test("fails closed when VM identity lease revocation fails", async () => {
    identityLeaseRows = [{
      id: "00000000-0000-4000-8000-000000000302",
      provider: "freestyle",
      providerIdentityHandle: "identity-shared-2",
    }];
    identityLeaseRevokeError = new Error("identity revoke failed");

    await expect(deleteCmuxAccountData({
      userId: "user-1",
    }, fakeRuntime())).rejects.toThrow("identity revoke failed");

    expect(calls).toContain("revoke-identity:freestyle:identity-shared-2");
    expect(calls).not.toContain("mark-identity-leases-revoked");
    expect(calls).not.toContain("delete-cloud-vm-leases");
  });

  test("fails closed when provider snapshot deletion fails", async () => {
    snapshotRows = [{
      id: "00000000-0000-4000-8000-000000000202",
      eventType: "vm.snapshot.created",
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

  test("fails closed while provider snapshot creation is still finalizing", async () => {
    snapshotRows = [{
      id: "00000000-0000-4000-8000-000000000203",
      eventType: "vm.snapshot.pending",
      provider: "freestyle",
      snapshotId: null,
      createdAt: new Date(),
    }];

    await expect(deleteCmuxAccountData({
      userId: "user-1",
    }, fakeRuntime())).rejects.toThrow("in-flight snapshot");

    expect(calls).toContain("select-snapshot-usage-events");
    expect(calls).not.toContain("delete-snapshot-usage-events");
    expect(calls).not.toContain("transaction");
  });

  test("deletes pending provider snapshots once their provider id is durable", async () => {
    snapshotRows = [{
      id: "00000000-0000-4000-8000-000000000205",
      eventType: "vm.snapshot.pending",
      provider: "freestyle",
      snapshotId: "snapshot-finalizing-user-1",
      createdAt: new Date(),
    }];

    await deleteCmuxAccountData({
      userId: "user-1",
    }, fakeRuntime());

    expect(calls).toContain("select-snapshot-usage-events");
    expect(calls).toContain("delete-snapshot:freestyle:snapshot-finalizing-user-1");
    expect(calls).toContain("delete-snapshot-usage-events");
    expect(calls.indexOf("delete-snapshot:freestyle:snapshot-finalizing-user-1")).toBeLessThan(
      calls.indexOf("delete-snapshot-usage-events"),
    );
  });

  test("drops stale pending provider snapshot reservations during account deletion", async () => {
    snapshotRows = [{
      id: "00000000-0000-4000-8000-000000000204",
      eventType: "vm.snapshot.pending",
      provider: "freestyle",
      snapshotId: null,
      createdAt: new Date(Date.now() - 2 * 60 * 60 * 1000),
    }];

    await deleteCmuxAccountData({
      userId: "user-1",
    }, fakeRuntime());

    expect(calls).toContain("select-snapshot-usage-events");
    expect(calls).toContain("delete-snapshot-usage-events");
    expect(calls).not.toContain("delete-snapshot:freestyle:null");
    expect(calls.indexOf("delete-snapshot-usage-events")).toBeLessThan(calls.indexOf("transaction"));
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
      [providerBackedVm("provider-vm-1")],
      [providerBackedVm("provider-vm-1")],
      [providerBackedVm("provider-vm-1")],
      [providerBackedVm("provider-vm-1")],
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
      [providerBackedVm("provider-vm-1"), providerBackedVm("provider-vm-2", "daytona")],
      [providerBackedVm("provider-vm-1")],
      [providerBackedVm("provider-vm-1")],
      [providerBackedVm("provider-vm-1")],
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
      [providerBackedVm("provider-vm-1")],
      [providerBackedVm("provider-vm-2", "daytona")],
      [providerBackedVm("provider-vm-3", "e2b")],
      [providerBackedVm("provider-vm-4")],
    ];

    await expect(deleteCmuxAccountData({
      userId: "user-1",
    }, fakeRuntime())).rejects.toThrow("Cloud VM account deletion cleanup did not settle");

    expect(runVmWorkflow).toHaveBeenCalledTimes(3);
    expect(calls).toContain("destroy:user-1:provider-vm-1");
    expect(calls).toContain("destroy:user-1:provider-vm-2");
    expect(calls).toContain("destroy:user-1:provider-vm-3");
  });

  test("clears owned team Stripe identifiers during local cleanup", async () => {
    stripeCustomerRows = [
      { id: "cus_owned_team", stackUserId: "user-1", stackTeamId: "team-owned-1" },
    ];
    stripeSubscriptionRows = [
      {
        id: "sub_owned_team",
        stackUserId: "user-1",
        stackTeamId: "team-owned-1",
        status: "active",
        scope: "team",
        plan: TEAM_PLAN_ID,
      },
    ];

    await deleteCmuxAccountData({
      userId: "user-1",
      ownedTeamIds: ["team-owned-1"],
    }, fakeRuntime());

    const customerUpdate = updateSets.find((entry) => entry.label === "anonymize-owned-team-stripe-customers");
    const subscriptionUpdate = updateSets.find((entry) => entry.label === "anonymize-owned-team-stripe-subscriptions");

    expect(customerUpdate?.values.stackTeamId).toMatch(/^deleted_team_[0-9a-f]{24}$/);
    expect(customerUpdate?.values.stackTeamId).not.toBe("team-owned-1");
    expect(subscriptionUpdate?.values.stackTeamId).toBe(customerUpdate?.values.stackTeamId);
    const remoteCustomerUpdate = stripeCustomerUpdates.find((entry) => entry.id === "cus_owned_team");
    expect(remoteCustomerUpdate?.params).toEqual(expect.objectContaining({
      address: "",
      email: `deleted+${accountDeletionUserHash("user-1").slice(0, 24)}@cmux.com`,
      name: "Deleted cmux account",
      phone: "",
      shipping: "",
    }));
  });

  test("reassigns retained shared-team Stripe billing without canceling it", async () => {
    stripeCustomerRows = [
      { id: "cus_personal", stackUserId: "user-1", stackTeamId: null },
      { id: "cus_shared", stackUserId: "user-1", stackTeamId: "team-shared" },
    ];
    stripeSubscriptionRows = [
      {
        id: "sub_personal",
        stackUserId: "user-1",
        stackTeamId: null,
        status: "active",
        scope: "user",
        plan: PRO_PLAN_ID,
      },
      {
        id: "sub_shared",
        stackUserId: "user-1",
        stackTeamId: "team-shared",
        status: "active",
        scope: "team",
        plan: TEAM_PLAN_ID,
      },
    ];

    await deleteCmuxAccountData({
      userId: "user-1",
      retainedTeamBillingOwners: [{
        stackTeamId: "team-shared",
        stackUserId: "user-2",
      }],
    }, fakeRuntime());

    const sharedCustomerUpdate = stripeCustomerUpdates.find((entry) => entry.id === "cus_shared");
    expect(sharedCustomerUpdate?.params.email).toBe(
      `deleted+${accountDeletionUserHash("user-1").slice(0, 24)}@cmux.com`,
    );
    expect(sharedCustomerUpdate?.params.metadata?.stackUserId).toBe("user-2");
    expect(sharedCustomerUpdate?.params.metadata?.stackTeamId).toBeUndefined();
    expect(sharedCustomerUpdate?.params.metadata?.deletedAccountId).toMatch(/^deleted_[0-9a-f]{24}$/);

    const sharedSubscriptionUpdate = stripeSubscriptionUpdates.find((entry) => entry.id === "sub_shared");
    expect(sharedSubscriptionUpdate?.params.metadata?.stackUserId).toBe("user-2");
    expect(sharedSubscriptionUpdate?.params.metadata?.stackTeamId).toBe("team-shared");
    expect(sharedSubscriptionUpdate?.params.metadata?.app).toBe("cmux");
    expect(sharedSubscriptionUpdate?.params.metadata?.plan).toBe(TEAM_PLAN_ID);
    expect(sharedSubscriptionUpdate?.params.metadata?.deletedAccountId).toMatch(/^deleted_[0-9a-f]{24}$/);
    expect(stripeSubscriptionCancels).not.toContain("sub_shared");

    const sharedCustomerLocalUpdate = updateSets.find((entry) =>
      entry.label === "reassign-retained-team-stripe-customers"
    );
    expect(sharedCustomerLocalUpdate?.values.stackUserId).toBe("user-2");
    expect(sharedCustomerLocalUpdate?.values.email).toBeNull();
    const sharedSubscriptionLocalUpdate = updateSets.find((entry) =>
      entry.label === "reassign-retained-team-stripe-subscriptions"
    );
    expect(sharedSubscriptionLocalUpdate?.values.stackUserId).toBe("user-2");
    expect(sharedSubscriptionLocalUpdate?.values.raw).toBeNull();

    const personalSubscriptionUpdate = stripeSubscriptionUpdates.find((entry) => entry.id === "sub_personal");
    expect(personalSubscriptionUpdate?.params.metadata?.stackUserId).toBe("");
    expect(stripeSubscriptionCancels).toContain("sub_personal");
  });

  test("fails closed before canceling shared-team Stripe billing when no retained owner is available", async () => {
    stripeCustomerRows = [
      { id: "cus_shared", stackUserId: "user-1", stackTeamId: "team-shared" },
    ];
    stripeSubscriptionRows = [
      {
        id: "sub_shared",
        stackUserId: "user-1",
        stackTeamId: "team-shared",
        status: "active",
        scope: "team",
        plan: TEAM_PLAN_ID,
      },
    ];

    await expect(deleteCmuxAccountData({
      userId: "user-1",
    }, fakeRuntime())).rejects.toThrow(
      "Shared team Stripe billing requires retained owner for account deletion: team-shared",
    );

    expect(stripeCustomerUpdates).toHaveLength(0);
    expect(stripeSubscriptionUpdates).toHaveLength(0);
    expect(stripeSubscriptionCancels).toHaveLength(0);
    expect(updateSets.filter((entry) => entry.label.includes("stripe"))).toHaveLength(0);
  });

  test("does not allow account deletion to start with shared-team billing and no retained owner", async () => {
    stripeCustomerRows = [
      { id: "cus_shared", stackUserId: "user-1", stackTeamId: "team-shared" },
    ];
    stripeSubscriptionRows = [
      {
        id: "sub_shared",
        stackUserId: "user-1",
        stackTeamId: "team-shared",
        status: "active",
        scope: "team",
        plan: TEAM_PLAN_ID,
      },
    ];

    await expect(assertAccountDeletionCanStart({
      userId: "user-1",
    }, fakeRuntime())).rejects.toThrow(
      "Shared team Stripe billing requires retained owner for account deletion: team-shared",
    );

    expect(calls).toEqual([]);
    expect(stripeCustomerUpdates).toHaveLength(0);
    expect(stripeSubscriptionUpdates).toHaveLength(0);
    expect(updateSets.filter((entry) => entry.label.includes("stripe"))).toHaveLength(0);
  });

  test("allows account deletion to start when shared-team billing has a retained owner", async () => {
    stripeCustomerRows = [
      { id: "cus_shared", stackUserId: "user-1", stackTeamId: "team-shared" },
    ];
    stripeSubscriptionRows = [
      {
        id: "sub_shared",
        stackUserId: "user-1",
        stackTeamId: "team-shared",
        status: "active",
        scope: "team",
        plan: TEAM_PLAN_ID,
      },
    ];

    await expect(assertAccountDeletionCanStart({
      userId: "user-1",
      retainedTeamBillingOwners: [{
        stackTeamId: "team-shared",
        stackUserId: "user-2",
      }],
    }, fakeRuntime())).resolves.toBeUndefined();

    expect(calls).toEqual([]);
    expect(stripeCustomerUpdates).toHaveLength(0);
    expect(stripeSubscriptionUpdates).toHaveLength(0);
    expect(updateSets.filter((entry) => entry.label.includes("stripe"))).toHaveLength(0);
  });

  test("does not allow account deletion to start with a deleting retained shared-team owner", async () => {
    stripeCustomerRows = [
      { id: "cus_shared", stackUserId: "user-1", stackTeamId: "team-shared" },
    ];
    stripeSubscriptionRows = [
      {
        id: "sub_shared",
        stackUserId: "user-1",
        stackTeamId: "team-shared",
        status: "active",
        scope: "team",
        plan: TEAM_PLAN_ID,
      },
    ];
    accountDeletionTombstoneRows = [{ status: "pending" }];

    await expect(assertAccountDeletionCanStart({
      userId: "user-1",
      retainedTeamBillingOwners: [{
        stackTeamId: "team-shared",
        stackUserId: "user-2",
      }],
    }, fakeRuntime())).rejects.toThrow(
      "Retained team Stripe billing owner is deleting for account deletion: team-shared",
    );

    expect(calls).toEqual([]);
    expect(stripeCustomerUpdates).toHaveLength(0);
    expect(stripeSubscriptionUpdates).toHaveLength(0);
    expect(updateSets.filter((entry) => entry.label.includes("stripe"))).toHaveLength(0);
  });

  test("preflights Stripe configuration before account deletion starts", async () => {
    stripeBillingConfigured = false;
    stripeSubscriptionRows = [{
      id: "sub_user",
      stackUserId: "user-1",
      stackTeamId: null,
      status: "active",
      scope: "user",
      plan: PRO_PLAN_ID,
    }];

    await expect(assertAccountDeletionCanStart({
      userId: "user-1",
    }, fakeRuntime())).rejects.toThrow("Stripe account deletion is not configured");

    expect(calls).toEqual([]);
    expect(stripeCustomerUpdates).toHaveLength(0);
    expect(stripeSubscriptionUpdates).toHaveLength(0);
    expect(updateSets.filter((entry) => entry.label.includes("stripe"))).toHaveLength(0);
  });

  test("cancels personal Stripe subscriptions even when the local row status is stale", async () => {
    stripeSubscriptionRows = [{
      id: "sub_stale_local",
      stackUserId: "user-1",
      stackTeamId: null,
      status: "canceled",
      scope: "user",
      plan: PRO_PLAN_ID,
    }];
    stripeRemoteSubscriptionStatuses.set("sub_stale_local", "active");

    await deleteCmuxAccountData({
      userId: "user-1",
    }, fakeRuntime());

    expect(retrieveStripeSubscription).toHaveBeenCalledWith("sub_stale_local");
    expect(stripeSubscriptionCancels).toContain("sub_stale_local");
    const subscriptionUpdate = stripeSubscriptionUpdates.find((entry) => entry.id === "sub_stale_local");
    expect(subscriptionUpdate?.params.metadata?.stackUserId).toBe("");
    expect(subscriptionUpdate?.params.metadata?.deletedAccountId).toMatch(/^deleted_[0-9a-f]{24}$/);
  });
});

function fakeAccountDeletionMutationDb(rows: Array<{ userIdHash: string; status: string }>): ReturnType<typeof cloudDb> {
  return {
    transaction: async <T>(callback: (tx: {
      execute: () => Promise<unknown[]>;
      select: () => ReturnType<typeof selectBuilder>;
    }) => Promise<T>) => {
      calls.push("transaction");
      return await callback({
        execute: async () => {
          calls.push("lock-account-deletion");
          return [];
        },
        select: () => selectBuilder(() => rows),
      });
    },
  } as unknown as ReturnType<typeof cloudDb>;
}

function fakeDb() {
  return {
    select: (selection?: unknown) => fakeDbSelectBuilder(selection),
    update: (table: unknown) => {
      if (table === cloudVms) {
        providerlessCloudVmUpdateCount += 1;
        return updateBuilder(
          providerlessCloudVmUpdateCount === 1
            ? "expire-stale-providerless-vms"
            : "claim-providerless-vms",
        );
      }
      if (table === cloudVmLeases) return updateBuilder("mark-identity-leases-revoked");
      return updateBuilder();
    },
    delete: (table: unknown) => {
      if (table === cloudVmUsageEvents) return writeBuilder("delete-snapshot-usage-events");
      if (table === subrouterTenants) return writeBuilder("delete-subrouter-tenant");
      return writeBuilder();
    },
    transaction: async <T>(callback: (tx: ReturnType<typeof fakeTransaction>) => Promise<T>) => {
      calls.push("transaction");
      return await callback(fakeTransaction());
    },
  };
}

function fakeDbSelectBuilder(selection?: unknown) {
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
      return subrouterTenantRows.splice(0, 1);
    }
    if (table === cloudVmUsageEvents) {
      if (isExecPendingUsageEventSelection(selection)) {
        if (execPendingRows.length > 0) calls.push("select-exec-usage-events");
        return execPendingRows.splice(0, 1);
      }
      if (snapshotRows.length > 0) {
        calls.push("select-snapshot-usage-events");
        return snapshotRows.splice(0, 50);
      }
    }
    if (table === cloudVmLeases && identityLeaseRows.length > 0) {
      calls.push("select-identity-leases");
      return identityLeaseRows.splice(0, 50);
    }
    if (table === vaultSnapshots) return vaultSnapshotRows.splice(0, 50);
    if (table === vaultUploadGrants) return vaultUploadGrantRows.splice(0, 50);
    if (table === vaultUploadTombstones) return vaultUploadTombstoneRows.splice(0, 50);
    if (table === accountDeletionTombstones) return accountDeletionTombstoneRows;
    if (table === stripeCustomers) return stripeCustomerRows;
    if (table === stripeSubscriptions) return stripeSubscriptionRows;
    return [];
  };
  const builder = {
    from: (fromTable: unknown) => {
      table = fromTable;
      return builder;
    },
    innerJoin: () => builder,
    where: () => builder,
    limit: () => builder,
    offset: () => builder,
    then: (
      resolve: (value: unknown[]) => unknown,
      reject: (reason: unknown) => unknown,
    ) => Promise.resolve(rows()).then(resolve, reject),
  };
  return builder;
}

function isExecPendingUsageEventSelection(selection: unknown): boolean {
  return !!selection &&
    typeof selection === "object" &&
    !Array.isArray(selection) &&
    !("eventType" in selection);
}

function fakeRuntime() {
  return {
    cloudDb: () => fakeDb() as unknown as ReturnType<typeof cloudDb>,
    deleteObject,
    destroyAccountOwnedVm,
    deleteVmSnapshot,
    revokeVmIdentityLease,
    runVmWorkflow,
    revokeSubrouterTenant: async (tenantId: string) => {
      calls.push(`revoke-subrouter-tenant:${tenantId}`);
      if (subrouterRevokeError) throw subrouterRevokeError;
    },
    isStripeBillingConfigured: () => stripeBillingConfigured,
    stripeClient: fakeStripeClient,
  };
}

function fakeStripeClient(): StripeClient {
  return {
    customers: {
      update: updateStripeCustomer,
    },
    subscriptions: {
      retrieve: retrieveStripeSubscription,
      update: updateStripeSubscription,
      cancel: cancelStripeSubscription,
    },
  } as unknown as StripeClient;
}

function fakeTransaction() {
  return {
    execute: async () => {
      calls.push("lock-account-deletion");
      return [];
    },
    select: () => fakeDbSelectBuilder(),
    update: (table: unknown) => {
      if (table === cloudVms) return updateBuilder("anonymize-team-cloud-vms");
      if (table === cloudVmUsageEvents) return updateBuilder("anonymize-team-cloud-vm-usage-events");
      if (table === stripeCustomers) {
        return updateBuilder(stripeCustomerUpdateLabel);
      }
      if (table === stripeSubscriptions) {
        return updateBuilder(stripeSubscriptionUpdateLabel);
      }
      return updateBuilder();
    },
    delete: (table: unknown) => {
      if (table === devices) return writeBuilder("delete-user-devices", deviceDeleteConditions);
      if (table === cloudVmSessions) return writeBuilder("delete-cloud-vm-sessions");
      if (table === cloudVmLeases) return writeBuilder("delete-cloud-vm-leases");
      if (table === cloudVmUsageEvents) {
        return writeBuilder("delete-account-owned-cloud-vm-usage-events", cloudVmUsageEventDeleteConditions);
      }
      if (table === cloudVms) return writeBuilder("delete-personal-cloud-vms");
      if (table === vaultSnapshots) return writeBuilder("delete-vault-snapshots");
      if (table === vaultUploadGrants) return writeBuilder("delete-vault-upload-grants");
      if (table === vaultUploadTombstones) return writeBuilder("delete-vault-upload-tombstones");
      if (table === vaultSessions) return writeBuilder("delete-vault-sessions");
      return writeBuilder();
    },
  };
}

function fakeClaimTransaction(input: {
  rows: Array<{
    userId?: string | null;
    userIdHash?: string;
    status: string;
    scope?: unknown;
    updatedAt: Date;
  }>;
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

function updateBuilder(label?: string | ((values: Record<string, unknown>) => string | undefined)) {
  let resolvedLabel: string | undefined;
  const builder = {
    set: (values: Record<string, unknown>) => {
      resolvedLabel = typeof label === "function" ? label(values) : label;
      if (resolvedLabel) updateSets.push({ label: resolvedLabel, values });
      return builder;
    },
    where: async () => {
      if (resolvedLabel) calls.push(resolvedLabel);
      return [];
    },
  };
  return builder;
}

function renderConditionSql(condition: unknown) {
  type SqlCondition = Parameters<PgDialect["sqlToQuery"]>[0];
  return new PgDialect().sqlToQuery(condition as SqlCondition);
}

function stripeCustomerUpdateLabel(values: Record<string, unknown>): string | undefined {
  const stackUserId = typeof values.stackUserId === "string" ? values.stackUserId : null;
  const stackTeamId = typeof values.stackTeamId === "string" ? values.stackTeamId : null;
  if (stackTeamId?.startsWith("deleted_team_")) return "anonymize-owned-team-stripe-customers";
  if (stackUserId?.startsWith("deleted_")) return "anonymize-user-stripe-customers";
  if (stackUserId) return "reassign-retained-team-stripe-customers";
  return undefined;
}

function stripeSubscriptionUpdateLabel(values: Record<string, unknown>): string | undefined {
  const stackUserId = typeof values.stackUserId === "string" ? values.stackUserId : null;
  const stackTeamId = typeof values.stackTeamId === "string" ? values.stackTeamId : null;
  if (values.status === "canceled") return "cancel-stripe-subscriptions";
  if (stackTeamId?.startsWith("deleted_team_")) return "anonymize-owned-team-stripe-subscriptions";
  if (stackUserId?.startsWith("deleted_")) return "anonymize-user-stripe-subscriptions";
  if (stackUserId) return "reassign-retained-team-stripe-subscriptions";
  return undefined;
}

function writeBuilder(label?: string, conditions?: unknown[]) {
  return {
    where: async (condition?: unknown) => {
      if (conditions) conditions.push(condition);
      if (label) calls.push(label);
      return [];
    },
  };
}

function conditionColumnNames(condition: unknown): string[] {
  const names: string[] = [];
  const visit = (value: unknown) => {
    if (!value || typeof value !== "object") return;
    const candidate = value as {
      readonly name?: unknown;
      readonly table?: unknown;
      readonly queryChunks?: readonly unknown[];
    };
    if (typeof candidate.name === "string" && candidate.table) {
      names.push(candidate.name);
    }
    if (Array.isArray(candidate.queryChunks)) {
      for (const chunk of candidate.queryChunks) visit(chunk);
    }
  };
  visit(condition);
  return names;
}
