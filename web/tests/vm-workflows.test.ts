import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import {
  FREE_INITIAL_CREATE_CREDITS_REASON,
  VmBillingGateway,
  noOpVmBillingGateway,
  type VmBillingGatewayShape,
} from "../services/vms/billingGateway";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import {
  VmRepository,
  VmRepositoryLive,
  type CloudVmRow,
  type VmRepositoryShape,
} from "../services/vms/repository";
import {
  VmCreateCreditsInsufficientError,
  VmCreateInProgressError,
  VmDatabaseError,
  VmLimitExceededError,
  VmNotFoundError,
  VmProviderOperationError,
} from "../services/vms/errors";
import {
  createVm,
  destroyVm,
  execVm,
  listUserVms,
  openAttachEndpoint,
  openSshEndpoint,
} from "../services/vms/workflows";
import { ProviderError } from "../services/vms/drivers";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;

let sql: Sql | null = null;

function databaseURL() {
  const url = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!url) {
    throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  }
  return url;
}

function providerLayer(
  provider: VmProviderGatewayShape,
  billing: VmBillingGatewayShape = noOpVmBillingGateway(),
) {
  return Layer.mergeAll(
    VmRepositoryLive,
    Layer.succeed(VmProviderGateway, provider),
    Layer.succeed(VmBillingGateway, billing),
  );
}

beforeAll(() => {
  if (!runDbTests) return;
  sql = postgres(databaseURL(), { max: 1 });
});

afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end();
});

describe("VM Effect workflows", () => {
  test("persists allocated provider VM IDs when provider create fails after allocation", async () => {
    const workflows = await actualVmWorkflows();
    const requested = testCloudVmRow({
      status: "provisioning",
      providerVmId: null,
      imageId: "snapshot-orphan",
      imageVersion: "signed-auth-test",
    });
    let failedInput: Parameters<VmRepositoryShape["markCreateFailed"]>[0] | null = null;
    let failureMetadata: Record<string, unknown> | undefined;
    let refundCalls = 0;
    const repo: VmRepositoryShape = {
      listUserVms: () => Effect.succeed([]),
      claimBillingGrant: () => Effect.succeed({ kind: "already_claimed" }),
      markBillingGrantApplied: () => Effect.void,
      deleteBillingGrant: () => Effect.void,
      beginCreate: () => Effect.succeed({ inserted: true, vm: requested }),
      activeLimitCandidates: () => Effect.succeed([]),
      markProviderObservedStatus: () => Effect.succeed(false),
      markCreateRunning: () => Effect.fail(new Error("unused") as never),
      markCreateFailed: (input) =>
        Effect.sync(() => {
          failedInput = input;
        }),
      findUserVm: () => Effect.succeed(null),
      markDestroyed: () => Effect.void,
      recordLease: () => Effect.void,
      activeIdentityLeases: () => Effect.succeed([]),
      markLeasesRevoked: () => Effect.void,
      recordUsageEvent: (input) =>
        Effect.sync(() => {
          failureMetadata = input.metadata;
        }),
      recordUsageEvents: () => Effect.void,
    };
    const provider: VmProviderGatewayShape = {
      create: () => Effect.fail(new VmProviderOperationError({
        provider: "freestyle",
        operation: "create",
        cause: new ProviderError(
          "freestyle",
          "create(snapshot-orphan)",
          new Error("post-create setup failed"),
          "provider-vm-orphan",
        ),
      })),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
    };
    const layer = Layer.mergeAll(
      Layer.succeed(VmRepository, repo),
      Layer.succeed(VmProviderGateway, provider),
      Layer.succeed(VmBillingGateway, {
        ...noOpVmBillingGateway(),
        reserveCreate: () => Effect.succeed({
          kind: "stack_item" as const,
          itemId: "cmux-vm-create-credit",
          customerType: "team" as const,
          customerId: "team-workflow-orphan",
          amount: 1,
        }),
        refundCreate: () =>
          Effect.sync(() => {
            refundCalls += 1;
          }),
      }),
    );

    const error = await Effect.runPromise(
      workflows.createVm({
        userId: "user-workflow-orphan",
        billingCustomerType: "team",
        billingTeamId: "team-workflow-orphan",
        billingPlanId: "free",
        maxActiveVms: 1,
        provider: "freestyle",
        image: "snapshot-orphan",
        imageVersion: "signed-auth-test",
        idempotencyKey: "orphan-create",
      }).pipe(Effect.flip, Effect.provide(layer)),
    );

    expect(error).toBeInstanceOf(VmProviderOperationError);
    expect(failedInput).toMatchObject({
      id: requested.id,
      code: "create",
      message: "Cloud VM setup failed after the provider allocated a VM.",
      providerVmId: "provider-vm-orphan",
      image: "snapshot-orphan",
      imageVersion: "signed-auth-test",
    });
    expect(failureMetadata).toMatchObject({ providerVmId: "provider-vm-orphan" });
    expect(refundCalls).toBe(0);
  });

  test("lists failed allocated provider VM IDs for cleanup but blocks attach", async () => {
    const workflows = await actualVmWorkflows();
    const failedVm = testCloudVmRow({
      userId: "user-workflow-failed-cleanup",
      status: "failed",
      providerVmId: "provider-vm-failed-cleanup",
      failureCode: "create",
      failureMessage: "post-create setup failed",
    });
    let destroyCalls = 0;
    let attachCalls = 0;
    const repo: VmRepositoryShape = {
      listUserVms: () => Effect.succeed([failedVm]),
      claimBillingGrant: () => Effect.succeed({ kind: "already_claimed" }),
      markBillingGrantApplied: () => Effect.void,
      deleteBillingGrant: () => Effect.void,
      beginCreate: () => Effect.fail(new Error("unused") as never),
      activeLimitCandidates: () => Effect.succeed([]),
      markProviderObservedStatus: () => Effect.succeed(false),
      markCreateRunning: () => Effect.fail(new Error("unused") as never),
      markCreateFailed: () => Effect.void,
      findUserVm: () => Effect.succeed(failedVm),
      markDestroyed: () => Effect.void,
      recordLease: () => Effect.void,
      activeIdentityLeases: () => Effect.succeed([]),
      markLeasesRevoked: () => Effect.void,
      recordUsageEvent: () => Effect.void,
      recordUsageEvents: () => Effect.void,
    };
    const provider: VmProviderGatewayShape = {
      create: () => Effect.fail(new Error("unused") as never),
      destroy: () =>
        Effect.sync(() => {
          destroyCalls += 1;
        }),
      exec: () => Effect.fail(new Error("unused") as never),
      openAttach: () =>
        Effect.sync(() => {
          attachCalls += 1;
          throw new Error("failed rows must not be attachable");
        }),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
    };
    const layer = Layer.mergeAll(
      Layer.succeed(VmRepository, repo),
      Layer.succeed(VmProviderGateway, provider),
      Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
    );

    const listed = await Effect.runPromise(
      workflows.listUserVms("user-workflow-failed-cleanup").pipe(Effect.provide(layer)),
    );
    const attachError = await Effect.runPromise(
      workflows.openAttachEndpoint({
        userId: "user-workflow-failed-cleanup",
        providerVmId: "provider-vm-failed-cleanup",
      }).pipe(Effect.flip, Effect.provide(layer)),
    );
    await Effect.runPromise(
      workflows.destroyVm({
        userId: "user-workflow-failed-cleanup",
        providerVmId: "provider-vm-failed-cleanup",
      }).pipe(Effect.provide(layer)),
    );

    expect(listed).toMatchObject([{
      providerVmId: "provider-vm-failed-cleanup",
      status: "failed",
      failureCode: "create",
      failureMessage: "Cloud VM setup failed after the provider allocated a VM.",
    }]);
    expect(attachError).toBeInstanceOf(VmNotFoundError);
    expect(attachCalls).toBe(0);
    expect(destroyCalls).toBe(1);
  });

  dbTest("does not block create when usage event recording fails", async () => {
    const requested = testCloudVmRow({
      status: "provisioning",
      providerVmId: null,
    });
    const running = testCloudVmRow({
      status: "running",
      providerVmId: "provider-vm-usage-events",
      imageVersion: "test-version",
    });
    let providerCreateCalls = 0;
    let usageEventAttempts = 0;
    const repo: VmRepositoryShape = {
      listUserVms: () => Effect.succeed([]),
      claimBillingGrant: () => Effect.succeed({ kind: "already_claimed" }),
      markBillingGrantApplied: () => Effect.void,
      deleteBillingGrant: () => Effect.void,
      beginCreate: () => Effect.succeed({ inserted: true, vm: requested }),
      activeLimitCandidates: () => Effect.succeed([]),
      markProviderObservedStatus: () => Effect.succeed(false),
      markCreateRunning: () => Effect.succeed(running),
      markCreateFailed: () => Effect.void,
      findUserVm: () => Effect.succeed(null),
      markDestroyed: () => Effect.void,
      recordLease: () => Effect.void,
      activeIdentityLeases: () => Effect.succeed([]),
      markLeasesRevoked: () => Effect.void,
      recordUsageEvent: () => Effect.void,
      recordUsageEvents: () => {
        usageEventAttempts += 1;
        return Effect.fail(new VmDatabaseError({
          operation: "recordUsageEvents",
          cause: new Error("usage event table unavailable"),
        }));
      },
    };
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          providerCreateCalls += 1;
          return {
            provider: "freestyle" as const,
            providerVmId: "provider-vm-usage-events",
            status: "running" as const,
            image: "snapshot-test",
            createdAt: Date.now(),
          };
        }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
    };
    const layer = Layer.mergeAll(
      Layer.succeed(VmRepository, repo),
      Layer.succeed(VmProviderGateway, provider),
      Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
    );

    const created = await Effect.runPromise(
      createVm({
        userId: "user-workflow-usage-events",
        billingCustomerType: "team",
        billingTeamId: "team-workflow-usage-events",
        billingPlanId: "free",
        maxActiveVms: 1,
        provider: "freestyle",
        image: "snapshot-test",
        imageVersion: "test-version",
        idempotencyKey: "usage-events",
      }).pipe(Effect.provide(layer)),
    );

    expect(created.providerVmId).toBe("provider-vm-usage-events");
    expect(providerCreateCalls).toBe(1);
    expect(usageEventAttempts).toBe(2);
  });

  dbTest("creates one provider VM per user idempotency key and records usage", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

    let createCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          return {
            provider: "e2b" as const,
            providerVmId: "provider-vm-idem-1",
            status: "running" as const,
            image: "cmuxd-ws:test",
            createdAt: Date.now(),
          };
        }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
    };

    const program = createVm({
      userId: "user-workflow-idem",
      billingCustomerType: "team",
      billingTeamId: "team-workflow-idem",
      billingPlanId: "free",
      maxActiveVms: 1,
      provider: "e2b",
      image: "cmuxd-ws:test",
      imageVersion: "test-version",
      idempotencyKey: "idem-1",
    });
    const layer = providerLayer(provider);
    const first = await Effect.runPromise(program.pipe(Effect.provide(layer)));
    const second = await Effect.runPromise(program.pipe(Effect.provide(layer)));

    expect(first).toEqual(second);
    expect(createCalls).toBe(1);

    const [{ vmCount }] = await sql<{ vmCount: string }[]>`
      select count(*)::text as "vmCount" from cloud_vms where user_id = 'user-workflow-idem'
    `;
    const [{ usageCount }] = await sql<{ usageCount: string }[]>`
      select count(*)::text as "usageCount" from cloud_vm_usage_events
      where user_id = 'user-workflow-idem' and event_type = 'vm.created'
    `;
    const [{ imageVersion }] = await sql<{ imageVersion: string | null }[]>`
      select image_version as "imageVersion" from cloud_vms where user_id = 'user-workflow-idem'
    `;
    expect(vmCount).toBe("1");
    expect(usageCount).toBe("1");
    expect(imageVersion).toBe("test-version");
  });

  dbTest("revokes the previous SSH identity before minting a replacement", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    const [vm] = await sql<{ id: string }[]>`
      insert into cloud_vms (user_id, provider, provider_vm_id, image_id, status)
      values ('user-workflow-ssh', 'freestyle', 'provider-vm-ssh-1', 'snapshot-test', 'running')
      returning id
    `;

    let mintCount = 0;
    const revoked: string[] = [];
    const provider: VmProviderGatewayShape = {
      create: () => Effect.fail(new Error("unused") as never),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () =>
        Effect.sync(() => {
          mintCount += 1;
          return {
            transport: "ssh" as const,
            host: "vm-ssh.freestyle.sh",
            port: 22,
            username: "provider-vm-ssh-1+cmux",
            publicKeyFingerprint: null,
            credential: { kind: "password" as const, value: `token-${mintCount}` },
            identityHandle: `identity-${mintCount}`,
          };
        }),
      revokeSSHIdentity: (_provider, identityHandle) =>
        Effect.sync(() => {
          revoked.push(identityHandle);
        }),
    };
    const layer = providerLayer(provider);

    const endpoint1 = await Effect.runPromise(
      openSshEndpoint({ userId: "user-workflow-ssh", providerVmId: "provider-vm-ssh-1" }).pipe(
        Effect.provide(layer),
      ),
    );
    const endpoint2 = await Effect.runPromise(
      openSshEndpoint({ userId: "user-workflow-ssh", providerVmId: "provider-vm-ssh-1" }).pipe(
        Effect.provide(layer),
      ),
    );

    expect(endpoint1.identityHandle).toBe("identity-1");
    expect(endpoint2.identityHandle).toBe("identity-2");
    expect(revoked).toEqual(["identity-1"]);

    const leases = await sql<{ providerIdentityHandle: string; revokedAt: Date | null }[]>`
      select provider_identity_handle as "providerIdentityHandle", revoked_at as "revokedAt"
      from cloud_vm_leases
      where vm_id = ${vm.id}
      order by provider_identity_handle
    `;
    expect(leases).toHaveLength(2);
    expect(leases[0]).toMatchObject({ providerIdentityHandle: "identity-1" });
    expect(leases[0]?.revokedAt).toBeInstanceOf(Date);
    expect(leases[1]).toMatchObject({ providerIdentityHandle: "identity-2", revokedAt: null });
  });

  dbTest("enforces active VM limits per billing team before provider create", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    await sql`
      insert into cloud_vms (user_id, billing_team_id, billing_plan_id, provider, provider_vm_id, image_id, status)
      values ('user-workflow-limit-owner', 'team-workflow-limit', 'free', 'e2b', 'provider-vm-limit-1', 'cmuxd-ws:test', 'running')
    `;

    let createCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          return {
            provider: "e2b" as const,
            providerVmId: "provider-vm-limit-2",
            status: "running" as const,
            image: "cmuxd-ws:test",
            createdAt: Date.now(),
          };
        }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
    };

    const error = await Effect.runPromise(
      createVm({
        userId: "user-workflow-limit-new",
        billingCustomerType: "team",
        billingTeamId: "team-workflow-limit",
        billingPlanId: "free",
        maxActiveVms: 1,
        provider: "e2b",
        image: "cmuxd-ws:test",
        idempotencyKey: "limit-new-1",
      }).pipe(
        Effect.flip,
        Effect.provide(providerLayer(provider)),
      ),
    );

    expect(error).toBeInstanceOf(VmLimitExceededError);
    expect(createCalls).toBe(0);
  });

  dbTest("does not count paused VMs against the active billing team limit", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    await sql`
      insert into cloud_vms (user_id, billing_team_id, billing_plan_id, provider, provider_vm_id, image_id, status)
      values ('user-workflow-paused-slot-old', 'team-workflow-paused-slot', 'free', 'freestyle', 'provider-vm-paused-old', 'snapshot-test', 'paused')
    `;

    let createCalls = 0;
    let statusCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          return {
            provider: "freestyle" as const,
            providerVmId: "provider-vm-paused-new",
            status: "running" as const,
            image: "snapshot-test",
            createdAt: Date.now(),
          };
        }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
      getStatus: () =>
        Effect.sync(() => {
          statusCalls += 1;
          return "running" as const;
        }),
    };

    const created = await Effect.runPromise(
      createVm({
        userId: "user-workflow-paused-slot-new",
        billingCustomerType: "team",
        billingTeamId: "team-workflow-paused-slot",
        billingPlanId: "free",
        maxActiveVms: 1,
        provider: "freestyle",
        image: "snapshot-test",
        idempotencyKey: "paused-slot-new",
      }).pipe(Effect.provide(providerLayer(provider))),
    );

    expect(created.providerVmId).toBe("provider-vm-paused-new");
    expect(createCalls).toBe(1);
    expect(statusCalls).toBe(0);
  });

  dbTest("skips Freestyle provider refresh when the billing team is below the active limit", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    await sql`
      insert into cloud_vms (user_id, billing_team_id, billing_plan_id, provider, provider_vm_id, image_id, status)
      values ('user-workflow-under-limit-old', 'team-workflow-under-limit', 'free', 'freestyle', 'provider-vm-under-limit-old', 'snapshot-test', 'running')
    `;

    let createCalls = 0;
    let statusCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          return {
            provider: "freestyle" as const,
            providerVmId: "provider-vm-under-limit-new",
            status: "running" as const,
            image: "snapshot-test",
            createdAt: Date.now(),
          };
        }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
      getStatus: () =>
        Effect.sync(() => {
          statusCalls += 1;
          return "running" as const;
        }),
    };

    const created = await Effect.runPromise(
      createVm({
        userId: "user-workflow-under-limit-new",
        billingCustomerType: "team",
        billingTeamId: "team-workflow-under-limit",
        billingPlanId: "free",
        maxActiveVms: 2,
        provider: "freestyle",
        image: "snapshot-test",
        idempotencyKey: "under-limit-new",
      }).pipe(Effect.provide(providerLayer(provider))),
    );

    expect(created.providerVmId).toBe("provider-vm-under-limit-new");
    expect(statusCalls).toBe(0);
    expect(createCalls).toBe(1);
  });

  dbTest("refreshes Freestyle running rows before active limit enforcement", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    await sql`
      insert into cloud_vms (user_id, billing_team_id, billing_plan_id, provider, provider_vm_id, image_id, status)
      values ('user-workflow-provider-paused-old', 'team-workflow-provider-paused', 'free', 'freestyle', 'provider-vm-provider-paused-old', 'snapshot-test', 'running')
    `;

    let createCalls = 0;
    let statusCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          return {
            provider: "freestyle" as const,
            providerVmId: "provider-vm-provider-paused-new",
            status: "running" as const,
            image: "snapshot-test",
            createdAt: Date.now(),
          };
        }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
      getStatus: () =>
        Effect.sync(() => {
          statusCalls += 1;
          return "paused" as const;
        }),
    };

    const created = await Effect.runPromise(
      createVm({
        userId: "user-workflow-provider-paused-new",
        billingCustomerType: "team",
        billingTeamId: "team-workflow-provider-paused",
        billingPlanId: "free",
        maxActiveVms: 1,
        provider: "freestyle",
        image: "snapshot-test",
        idempotencyKey: "provider-paused-new",
      }).pipe(Effect.provide(providerLayer(provider))),
    );

    expect(created.providerVmId).toBe("provider-vm-provider-paused-new");
    expect(statusCalls).toBe(1);
    expect(createCalls).toBe(1);

    const [oldVm] = await sql<{ status: string }[]>`
      select status from cloud_vms
      where provider_vm_id = 'provider-vm-provider-paused-old'
    `;
    expect(oldVm?.status).toBe("paused");
  });

  dbTest("marks provider-deleted Freestyle rows destroyed before active limit enforcement", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    await sql`
      insert into cloud_vms (user_id, billing_team_id, billing_plan_id, provider, provider_vm_id, image_id, status)
      values ('user-workflow-provider-deleted-old', 'team-workflow-provider-deleted', 'free', 'freestyle', 'provider-vm-provider-deleted-old', 'snapshot-test', 'running')
    `;

    let createCalls = 0;
    let statusCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          return {
            provider: "freestyle" as const,
            providerVmId: "provider-vm-provider-deleted-new",
            status: "running" as const,
            image: "snapshot-test",
            createdAt: Date.now(),
          };
        }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
      getStatus: () =>
        Effect.suspend(() => {
          statusCalls += 1;
          const deleted = new Error(
            "VM_DELETED: Vm provider-vm-provider-deleted-old is marked as deleted but still exists in the database",
          );
          deleted.name = "VmDeletedError";
          return Effect.fail(new VmProviderOperationError({
            provider: "freestyle",
            operation: "getStatus",
            cause: deleted,
          }));
        }),
    };

    const created = await Effect.runPromise(
      createVm({
        userId: "user-workflow-provider-deleted-new",
        billingCustomerType: "team",
        billingTeamId: "team-workflow-provider-deleted",
        billingPlanId: "free",
        maxActiveVms: 1,
        provider: "freestyle",
        image: "snapshot-test",
        idempotencyKey: "provider-deleted-new",
      }).pipe(Effect.provide(providerLayer(provider))),
    );

    expect(created.providerVmId).toBe("provider-vm-provider-deleted-new");
    expect(statusCalls).toBe(1);
    expect(createCalls).toBe(1);

    const [oldVm] = await sql<{ status: string; destroyedAt: Date | null }[]>`
      select status, destroyed_at as "destroyedAt" from cloud_vms
      where provider_vm_id = 'provider-vm-provider-deleted-old'
    `;
    expect(oldVm?.status).toBe("destroyed");
    expect(oldVm?.destroyedAt).toBeInstanceOf(Date);

    const [{ destroyedUsageCount }] = await sql<{ destroyedUsageCount: string }[]>`
      select count(*)::text as "destroyedUsageCount"
      from cloud_vm_usage_events
      where provider = 'freestyle'
        and event_type = 'vm.destroyed'
        and vm_id in (
          select id from cloud_vms
          where provider_vm_id = 'provider-vm-provider-deleted-old'
        )
    `;
    expect(destroyedUsageCount).toBe("1");
  });

  dbTest("refreshes Freestyle running rows concurrently before active limit enforcement", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    await sql`
      insert into cloud_vms (user_id, billing_team_id, billing_plan_id, provider, provider_vm_id, image_id, status)
      values
        ('user-workflow-provider-concurrent-old-1', 'team-workflow-provider-concurrent', 'free', 'freestyle', 'provider-vm-provider-concurrent-old-1', 'snapshot-test', 'running'),
        ('user-workflow-provider-concurrent-old-2', 'team-workflow-provider-concurrent', 'free', 'freestyle', 'provider-vm-provider-concurrent-old-2', 'snapshot-test', 'running')
    `;

    let createCalls = 0;
    let statusCalls = 0;
    let inFlight = 0;
    let maxInFlight = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          return {
            provider: "freestyle" as const,
            providerVmId: "provider-vm-provider-concurrent-new",
            status: "running" as const,
            image: "snapshot-test",
            createdAt: Date.now(),
          };
        }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
      getStatus: () =>
        Effect.promise(async () => {
          statusCalls += 1;
          inFlight += 1;
          maxInFlight = Math.max(maxInFlight, inFlight);
          await Promise.resolve();
          inFlight -= 1;
          return "paused" as const;
        }),
    };

    const created = await Effect.runPromise(
      createVm({
        userId: "user-workflow-provider-concurrent-new",
        billingCustomerType: "team",
        billingTeamId: "team-workflow-provider-concurrent",
        billingPlanId: "free",
        maxActiveVms: 1,
        provider: "freestyle",
        image: "snapshot-test",
        idempotencyKey: "provider-concurrent-new",
      }).pipe(Effect.provide(providerLayer(provider))),
    );

    expect(created.providerVmId).toBe("provider-vm-provider-concurrent-new");
    expect(statusCalls).toBe(2);
    expect(maxInFlight).toBe(2);
    expect(createCalls).toBe(1);

    const [{ oldRunningCount }] = await sql<{ oldRunningCount: string }[]>`
      select count(*)::text as "oldRunningCount" from cloud_vms
      where billing_team_id = 'team-workflow-provider-concurrent'
        and provider_vm_id like 'provider-vm-provider-concurrent-old-%'
        and status = 'running'
    `;
    expect(oldRunningCount).toBe("0");
  });

  dbTest("does not regress running rows when Freestyle reports creating", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    await sql`
      insert into cloud_vms (user_id, billing_team_id, billing_plan_id, provider, provider_vm_id, image_id, status)
      values ('user-workflow-provider-creating-old', 'team-workflow-provider-creating', 'free', 'freestyle', 'provider-vm-provider-creating-old', 'snapshot-test', 'running')
    `;

    let createCalls = 0;
    let statusCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          throw new Error("provider create should not be called");
        }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
      getStatus: () =>
        Effect.sync(() => {
          statusCalls += 1;
          return "creating" as const;
        }),
    };

    const error = await Effect.runPromise(
      createVm({
        userId: "user-workflow-provider-creating-new",
        billingCustomerType: "team",
        billingTeamId: "team-workflow-provider-creating",
        billingPlanId: "free",
        maxActiveVms: 1,
        provider: "freestyle",
        image: "snapshot-test",
        idempotencyKey: "provider-creating-new",
      }).pipe(
        Effect.flip,
        Effect.provide(providerLayer(provider)),
      ),
    );

    expect(error).toBeInstanceOf(VmLimitExceededError);
    expect(statusCalls).toBe(1);
    expect(createCalls).toBe(0);

    const [oldVm] = await sql<{ status: string }[]>`
      select status from cloud_vms
      where provider_vm_id = 'provider-vm-provider-creating-old'
    `;
    expect(oldVm?.status).toBe("running");
  });

  dbTest("keeps active limit enforcement when every Freestyle row is still running", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    await sql`
      insert into cloud_vms (user_id, billing_team_id, billing_plan_id, provider, provider_vm_id, image_id, status)
      values ('user-workflow-provider-running-old', 'team-workflow-provider-running', 'free', 'freestyle', 'provider-vm-provider-running-old', 'snapshot-test', 'running')
    `;

    let createCalls = 0;
    let statusCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          throw new Error("provider create should not be called");
        }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
      getStatus: () =>
        Effect.sync(() => {
          statusCalls += 1;
          return "running" as const;
        }),
    };

    const error = await Effect.runPromise(
      createVm({
        userId: "user-workflow-provider-running-new",
        billingCustomerType: "team",
        billingTeamId: "team-workflow-provider-running",
        billingPlanId: "free",
        maxActiveVms: 1,
        provider: "freestyle",
        image: "snapshot-test",
        idempotencyKey: "provider-running-new",
      }).pipe(
        Effect.flip,
        Effect.provide(providerLayer(provider)),
      ),
    );

    expect(error).toBeInstanceOf(VmLimitExceededError);
    expect(statusCalls).toBe(1);
    expect(createCalls).toBe(0);
  });

  dbTest("does not overwrite a VM destroyed during provider status refresh", async () => {
    if (!sql) throw new Error("test database not initialized");
    const testSql = sql;
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    await sql`
      insert into cloud_vms (user_id, billing_team_id, billing_plan_id, provider, provider_vm_id, image_id, status)
      values ('user-workflow-provider-destroy-race-old', 'team-workflow-provider-destroy-race', 'free', 'freestyle', 'provider-vm-provider-destroy-race-old', 'snapshot-test', 'running')
    `;

    let createCalls = 0;
    let statusCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          return {
            provider: "freestyle" as const,
            providerVmId: "provider-vm-provider-destroy-race-new",
            status: "running" as const,
            image: "snapshot-test",
            createdAt: Date.now(),
          };
        }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
      getStatus: () =>
        Effect.promise(async () => {
          statusCalls += 1;
          await testSql`
            update cloud_vms
            set status = 'destroyed', destroyed_at = now(), updated_at = now()
            where provider_vm_id = 'provider-vm-provider-destroy-race-old'
          `;
          return "paused" as const;
        }),
    };

    const created = await Effect.runPromise(
      createVm({
        userId: "user-workflow-provider-destroy-race-new",
        billingCustomerType: "team",
        billingTeamId: "team-workflow-provider-destroy-race",
        billingPlanId: "free",
        maxActiveVms: 1,
        provider: "freestyle",
        image: "snapshot-test",
        idempotencyKey: "provider-destroy-race-new",
      }).pipe(Effect.provide(providerLayer(provider))),
    );

    expect(created.providerVmId).toBe("provider-vm-provider-destroy-race-new");
    expect(statusCalls).toBe(1);
    expect(createCalls).toBe(1);

    const [oldVm] = await sql<{ status: string; destroyedAt: Date | null }[]>`
      select status, destroyed_at as "destroyedAt" from cloud_vms
      where provider_vm_id = 'provider-vm-provider-destroy-race-old'
    `;
    expect(oldVm?.status).toBe("destroyed");
    expect(oldVm?.destroyedAt).toBeInstanceOf(Date);
  });

  dbTest("returns in-progress for concurrent same-key creates before active limit checks", async () => {
    if (!sql) throw new Error("test database not initialized");
    const testSql = sql;
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

    let createCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          return {
            provider: "e2b" as const,
            providerVmId: "provider-vm-concurrent-idem",
            status: "running" as const,
            image: "cmuxd-ws:test",
            createdAt: Date.now(),
          };
        }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
    };
    const layer = providerLayer(provider);
    const input = {
      userId: "user-workflow-concurrent-idem",
      billingCustomerType: "team" as const,
      billingTeamId: "team-workflow-concurrent-idem",
      billingPlanId: "free",
      maxActiveVms: 1,
      provider: "e2b" as const,
      image: "cmuxd-ws:test",
      idempotencyKey: "concurrent-idem-1",
    };
    const locker = postgres(databaseURL(), { max: 1 });
    let retry: Promise<unknown> | null = null;
    try {
      await locker.begin(async (tx) => {
        await tx`select pg_advisory_xact_lock(hashtextextended(${input.billingTeamId}, 0))`;
        await tx`
          insert into cloud_vms (
            user_id,
            billing_team_id,
            billing_plan_id,
            provider,
            image_id,
            status,
            idempotency_key
          )
          values (
            ${input.userId},
            ${input.billingTeamId},
            ${input.billingPlanId},
            ${input.provider},
            ${input.image},
            'provisioning',
            ${input.idempotencyKey}
          )
        `;
        retry = Effect.runPromise(
          createVm(input).pipe(
            Effect.flip,
            Effect.provide(layer),
          ),
        );
        await waitForBlockedAdvisoryLock(testSql, input.billingTeamId);
      });
    } finally {
      await locker.end();
    }
    const secondError = await retry;

    expect(secondError).toBeInstanceOf(VmCreateInProgressError);
    expect(createCalls).toBe(0);

    const [{ vmCount }] = await sql<{ vmCount: string }[]>`
      select count(*)::text as "vmCount" from cloud_vms
      where user_id = 'user-workflow-concurrent-idem'
    `;
    expect(vmCount).toBe("1");
  });

  dbTest("allows a new create after destroy releases the active team slot", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    await sql`
      insert into cloud_vms (user_id, billing_team_id, billing_plan_id, provider, provider_vm_id, image_id, status)
      values ('user-workflow-reuse-slot', 'team-workflow-reuse-slot', 'free', 'e2b', 'provider-vm-reuse-old', 'cmuxd-ws:test', 'running')
    `;

    let createCalls = 0;
    let destroyCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          return {
            provider: "e2b" as const,
            providerVmId: "provider-vm-reuse-new",
            status: "running" as const,
            image: "cmuxd-ws:test",
            createdAt: Date.now(),
          };
        }),
      destroy: () =>
        Effect.sync(() => {
          destroyCalls += 1;
        }),
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
    };
    const layer = providerLayer(provider);

    await Effect.runPromise(
      destroyVm({ userId: "user-workflow-reuse-slot", providerVmId: "provider-vm-reuse-old" }).pipe(
        Effect.provide(layer),
      ),
    );
    const created = await Effect.runPromise(
      createVm({
        userId: "user-workflow-reuse-slot",
        billingCustomerType: "team",
        billingTeamId: "team-workflow-reuse-slot",
        billingPlanId: "free",
        maxActiveVms: 1,
        provider: "e2b",
        image: "cmuxd-ws:test",
        idempotencyKey: "reuse-slot-new",
      }).pipe(Effect.provide(layer)),
    );

    expect(created.providerVmId).toBe("provider-vm-reuse-new");
    expect(destroyCalls).toBe(1);
    expect(createCalls).toBe(1);

    const [{ runningCount }] = await sql<{ runningCount: string }[]>`
      select count(*)::text as "runningCount"
      from cloud_vms
      where billing_team_id = 'team-workflow-reuse-slot' and status = 'running'
    `;
    expect(runningCount).toBe("1");
  });

  dbTest("reserves Stack Auth credits only once per new idempotency key", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

    let createCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          return {
            provider: "freestyle" as const,
            providerVmId: "provider-vm-credit-idem",
            status: "running" as const,
            image: "snapshot-credit",
            createdAt: Date.now(),
          };
        }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
    };

    let reserveCalls = 0;
    const billing: VmBillingGatewayShape = {
      ...noOpVmBillingGateway(),
      reserveCreate: () =>
        Effect.sync(() => {
          reserveCalls += 1;
          return {
            kind: "stack_item" as const,
            itemId: "cmux-vm-create-credit",
            customerType: "team" as const,
            customerId: "team-workflow-credit-idem",
            amount: 1,
          };
        }),
      refundCreate: () => Effect.void,
    };

    const program = createVm({
      userId: "user-workflow-credit-idem",
      billingCustomerType: "team",
      billingTeamId: "team-workflow-credit-idem",
      billingPlanId: "free",
      maxActiveVms: 1,
      provider: "freestyle",
      image: "snapshot-credit",
      idempotencyKey: "credit-idem-1",
    });
    const layer = providerLayer(provider, billing);

    const first = await Effect.runPromise(program.pipe(Effect.provide(layer)));
    const second = await Effect.runPromise(program.pipe(Effect.provide(layer)));

    expect(first).toEqual(second);
    expect(createCalls).toBe(1);
    expect(reserveCalls).toBe(1);

    const usageEvents = await sql<{ eventType: string }[]>`
      select event_type as "eventType" from cloud_vm_usage_events
      where user_id = 'user-workflow-credit-idem'
      order by created_at, event_type
    `;
    expect(usageEvents.map((event) => event.eventType)).toContain("vm.create.credit.reserved");
  });

  dbTest("grants initial free-plan Stack Auth credits once per billing team", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

    let createCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          return {
            provider: "e2b" as const,
            providerVmId: `provider-vm-credit-grant-${createCalls}`,
            status: "running" as const,
            image: "cmuxd-ws:credit-grant",
            createdAt: Date.now(),
          };
        }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
    };

    let grantCalls = 0;
    let reserveCalls = 0;
    const billing: VmBillingGatewayShape = {
      ...noOpVmBillingGateway(),
      resolveInitialCreateCreditGrant: () => ({
        kind: "stack_item" as const,
        itemId: "cmux-vm-create-credit",
        customerType: "team" as const,
        customerId: "team-workflow-credit-grant",
        amount: 20,
        reason: FREE_INITIAL_CREATE_CREDITS_REASON,
      }),
      applyCreateCreditGrant: () =>
        Effect.sync(() => {
          grantCalls += 1;
        }),
      reserveCreate: () =>
        Effect.sync(() => {
          reserveCalls += 1;
          return {
            kind: "stack_item" as const,
            itemId: "cmux-vm-create-credit",
            customerType: "team" as const,
            customerId: "team-workflow-credit-grant",
            amount: 1,
          };
        }),
    };

    const layer = providerLayer(provider, billing);
    for (const idempotencyKey of ["credit-grant-1", "credit-grant-2"]) {
      await Effect.runPromise(
        createVm({
          userId: "user-workflow-credit-grant",
          billingCustomerType: "team",
          billingTeamId: "team-workflow-credit-grant",
          billingPlanId: "free",
          maxActiveVms: 10,
          provider: "e2b",
          image: "cmuxd-ws:credit-grant",
          idempotencyKey,
        }).pipe(Effect.provide(layer)),
      );
    }

    expect(createCalls).toBe(2);
    expect(grantCalls).toBe(1);
    expect(reserveCalls).toBe(2);

    const [grantRow] = await sql<{ total: number; applied: number }[]>`
      select count(*)::int as total, count(applied_at)::int as applied
      from cloud_vm_billing_grants
      where billing_customer_id = 'team-workflow-credit-grant'
        and item_id = 'cmux-vm-create-credit'
    `;
    expect(grantRow).toEqual({ total: 1, applied: 1 });

    const [grantEvents] = await sql<{ total: number }[]>`
      select count(*)::int as total
      from cloud_vm_usage_events
      where billing_team_id = 'team-workflow-credit-grant'
        and event_type = 'vm.create.credit.granted'
    `;
    expect(grantEvents?.total).toBe(1);
  });

  dbTest("does not call the provider when Stack Auth credits are insufficient", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

    let createCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          throw new Error("provider should not be called");
        }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
    };
    const billing: VmBillingGatewayShape = {
      ...noOpVmBillingGateway(),
      reserveCreate: () => Effect.fail(new VmCreateCreditsInsufficientError({
        itemId: "cmux-vm-create-credit",
        billingCustomerId: "team-workflow-credit-empty",
        amount: 1,
      })),
      refundCreate: () => Effect.void,
    };

    const error = await Effect.runPromise(
      createVm({
        userId: "user-workflow-credit-empty",
        billingCustomerType: "team",
        billingTeamId: "team-workflow-credit-empty",
        billingPlanId: "free",
        maxActiveVms: 1,
        provider: "freestyle",
        image: "snapshot-credit-empty",
        idempotencyKey: "credit-empty-1",
      }).pipe(
        Effect.flip,
        Effect.provide(providerLayer(provider, billing)),
      ),
    );

    expect(error).toBeInstanceOf(VmCreateCreditsInsufficientError);
    expect(createCalls).toBe(0);

    const [failedVm] = await sql<{
      status: string;
      failureCode: string | null;
      providerVmId: string | null;
    }[]>`
      select status, failure_code as "failureCode", provider_vm_id as "providerVmId"
      from cloud_vms
      where user_id = 'user-workflow-credit-empty'
    `;
    expect(failedVm).toMatchObject({
      status: "failed",
      failureCode: "billing_reserve_failed",
      providerVmId: null,
    });

    const usageEvents = await sql<{ eventType: string }[]>`
      select event_type as "eventType" from cloud_vm_usage_events
      where user_id = 'user-workflow-credit-empty'
    `;
    expect(usageEvents.map((event) => event.eventType)).toContain("vm.create.billing_failed");

    const [active] = await sql<{ total: number }[]>`
      select count(*)::int as total from cloud_vms
      where billing_team_id = 'team-workflow-credit-empty'
        and status in ('provisioning', 'running', 'paused')
    `;
    expect(active?.total).toBe(0);

    const recoveryProvider: VmProviderGatewayShape = {
      create: () => Effect.succeed({
        provider: "freestyle" as const,
        providerVmId: "provider-vm-credit-recovered",
        status: "running" as const,
        image: "snapshot-credit-recovered",
        createdAt: Date.now(),
      }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
    };

    const recovered = await Effect.runPromise(
      createVm({
        userId: "user-workflow-credit-empty",
        billingCustomerType: "team",
        billingTeamId: "team-workflow-credit-empty",
        billingPlanId: "free",
        maxActiveVms: 1,
        provider: "freestyle",
        image: "snapshot-credit-recovered",
        idempotencyKey: "credit-empty-2",
      }).pipe(Effect.provide(providerLayer(recoveryProvider))),
    );

    expect(recovered.providerVmId).toBe("provider-vm-credit-recovered");
  });

  dbTest("refunds a reserved Stack Auth credit when provider create fails", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.fail(new VmProviderOperationError({
          provider: "freestyle",
          operation: "create",
          cause: new Error("provider unavailable"),
        })),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
    };
    let refundCalls = 0;
    const billing: VmBillingGatewayShape = {
      ...noOpVmBillingGateway(),
      reserveCreate: () => Effect.succeed({
        kind: "stack_item" as const,
        itemId: "cmux-vm-create-credit",
        customerType: "team" as const,
        customerId: "team-workflow-credit-refund",
        amount: 1,
      }),
      refundCreate: () =>
        Effect.sync(() => {
          refundCalls += 1;
        }),
    };

    await expect(
      Effect.runPromise(
        createVm({
          userId: "user-workflow-credit-refund",
          billingCustomerType: "team",
          billingTeamId: "team-workflow-credit-refund",
          billingPlanId: "free",
          maxActiveVms: 1,
          provider: "freestyle",
          image: "snapshot-credit-refund",
          idempotencyKey: "credit-refund-1",
        }).pipe(Effect.provide(providerLayer(provider, billing))),
      ),
    ).rejects.toThrow();

    expect(refundCalls).toBe(1);
    const usageEvents = await sql<{ eventType: string }[]>`
      select event_type as "eventType" from cloud_vm_usage_events
      where user_id = 'user-workflow-credit-refund'
      order by created_at, event_type
    `;
    expect(usageEvents.map((event) => event.eventType).sort()).toEqual([
      "vm.create.credit.refunded",
      "vm.create.credit.reserved",
      "vm.create.failed",
      "vm.create.requested",
    ]);
  });

  dbTest("does not attach another user's VM", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    await sql`
      insert into cloud_vms (user_id, billing_team_id, billing_plan_id, provider, provider_vm_id, image_id, status)
      values ('user-workflow-owner', 'team-workflow-owner', 'free', 'freestyle', 'provider-vm-private-1', 'snapshot-test', 'running')
    `;

    let attachCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () => Effect.fail(new Error("unused") as never),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () =>
        Effect.sync(() => {
          attachCalls += 1;
          return {
            transport: "websocket" as const,
            url: "wss://example.invalid/pty",
            headers: {},
            token: "pty-token",
            sessionId: "pty-session",
            expiresAtUnix: Math.floor(Date.now() / 1000) + 300,
          };
        }),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
    };

    const error = await Effect.runPromise(
      openAttachEndpoint({
        userId: "user-workflow-attacker",
        providerVmId: "provider-vm-private-1",
      }).pipe(
        Effect.flip,
        Effect.provide(providerLayer(provider)),
      ),
    );
    expect(error).toBeInstanceOf(VmNotFoundError);
    expect(attachCalls).toBe(0);
  });

  dbTest("does not destroy, exec, or mint SSH for another user's VM", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    await sql`
      insert into cloud_vms (user_id, billing_team_id, billing_plan_id, provider, provider_vm_id, image_id, status)
      values ('user-workflow-owner', 'team-workflow-owner', 'free', 'freestyle', 'provider-vm-private-2', 'snapshot-test', 'running')
    `;

    let destroyCalls = 0;
    let execCalls = 0;
    let sshCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () => Effect.fail(new Error("unused") as never),
      destroy: () => Effect.sync(() => {
        destroyCalls += 1;
      }),
      exec: () => Effect.sync(() => {
        execCalls += 1;
        return { exitCode: 0, stdout: "", stderr: "" };
      }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.sync(() => {
        sshCalls += 1;
        return {
          transport: "ssh" as const,
          host: "vm-ssh.freestyle.sh",
          port: 22,
          username: "provider-vm-private-2+cmux",
          publicKeyFingerprint: null,
          credential: { kind: "password" as const, value: "token" },
          identityHandle: "identity",
        };
      }),
      revokeSSHIdentity: () => Effect.void,
    };
    const layer = providerLayer(provider);

    const destroyError = await Effect.runPromise(
      destroyVm({ userId: "user-workflow-attacker", providerVmId: "provider-vm-private-2" }).pipe(
        Effect.flip,
        Effect.provide(layer),
      ),
    );
    const execError = await Effect.runPromise(
      execVm({
        userId: "user-workflow-attacker",
        providerVmId: "provider-vm-private-2",
        command: "true",
        timeoutMs: 1000,
      }).pipe(Effect.flip, Effect.provide(layer)),
    );
    const sshError = await Effect.runPromise(
      openSshEndpoint({ userId: "user-workflow-attacker", providerVmId: "provider-vm-private-2" }).pipe(
        Effect.flip,
        Effect.provide(layer),
      ),
    );

    expect(destroyError).toBeInstanceOf(VmNotFoundError);
    expect(execError).toBeInstanceOf(VmNotFoundError);
    expect(sshError).toBeInstanceOf(VmNotFoundError);
    expect(destroyCalls).toBe(0);
    expect(execCalls).toBe(0);
    expect(sshCalls).toBe(0);
  });

  dbTest("records repeated attach RPC leases idempotently when provider returns a stable daemon token", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    const [vm] = await sql<{ id: string }[]>`
      insert into cloud_vms (user_id, provider, provider_vm_id, image_id, status)
      values ('user-workflow-attach', 'freestyle', 'provider-vm-attach-1', 'snapshot-test', 'running')
      returning id
    `;

    let attachCount = 0;
    const provider: VmProviderGatewayShape = {
      create: () => Effect.fail(new Error("unused") as never),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () =>
        Effect.sync(() => {
          attachCount += 1;
          return {
            transport: "websocket" as const,
            url: "wss://example.invalid/pty",
            headers: {},
            token: `pty-token-${attachCount}`,
            sessionId: `pty-session-${attachCount}`,
            expiresAtUnix: Math.floor(Date.now() / 1000) + 300,
            daemon: {
              url: "wss://example.invalid/rpc",
              headers: {},
              token: "stable-rpc-token",
              sessionId: "stable-rpc-session",
              expiresAtUnix: Math.floor(Date.now() / 1000) + 600,
            },
          };
        }),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
    };
    const layer = providerLayer(provider);

    await Effect.runPromise(
      openAttachEndpoint({ userId: "user-workflow-attach", providerVmId: "provider-vm-attach-1" }).pipe(
        Effect.provide(layer),
      ),
    );
    await Effect.runPromise(
      openAttachEndpoint({ userId: "user-workflow-attach", providerVmId: "provider-vm-attach-1" }).pipe(
        Effect.provide(layer),
      ),
    );

    const leases = await sql<{ kind: string; sessionId: string | null }[]>`
      select kind, session_id as "sessionId"
      from cloud_vm_leases
      where vm_id = ${vm.id}
      order by kind, session_id
    `;
    expect(leases).toEqual([
      { kind: "pty", sessionId: "pty-session-1" },
      { kind: "pty", sessionId: "pty-session-2" },
      { kind: "rpc", sessionId: "stable-rpc-session" },
    ]);
  });
});

function testCloudVmRow(overrides: Partial<CloudVmRow> = {}): CloudVmRow {
  const now = new Date();
  return {
    id: "00000000-0000-4000-8000-000000000001",
    userId: "user-workflow-usage-events",
    billingTeamId: "team-workflow-usage-events",
    billingPlanId: "free",
    provider: "freestyle",
    providerVmId: null,
    imageId: "snapshot-test",
    imageVersion: null,
    status: "provisioning",
    idempotencyKey: "usage-events",
    createdAt: now,
    updatedAt: now,
    destroyedAt: null,
    failureCode: null,
    failureMessage: null,
    ...overrides,
  };
}

async function actualVmWorkflows(): Promise<typeof import("../services/vms/workflows")> {
  const url = new URL("../services/vms/workflows.ts", import.meta.url);
  url.searchParams.set("actual", "vm-workflows-test");
  return await import(url.href) as typeof import("../services/vms/workflows");
}

async function waitForBlockedAdvisoryLock(sql: Sql, billingTeamId: string): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const [{ blocked }] = await sql<{ blocked: string }[]>`
      with target as (
        select
          (((hashtextextended(${billingTeamId}, 0) >> 32) & 4294967295)::bigint)::oid as classid,
          ((hashtextextended(${billingTeamId}, 0) & 4294967295)::bigint)::oid as objid
      )
      select count(*)::text as "blocked"
      from pg_locks l
      join target t on l.classid = t.classid and l.objid = t.objid
      where l.locktype = 'advisory'
        and l.objsubid = 1
        and not l.granted
    `;
    if (Number(blocked) > 0) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error("timed out waiting for blocked advisory lock");
}
