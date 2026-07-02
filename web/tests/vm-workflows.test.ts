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
  VmSnapshotNotFoundError,
} from "../services/vms/errors";
import {
  createVm,
  destroyVm,
  execVm,
  listUserVms,
  openBaseVm,
  openAttachEndpoint,
  openSshEndpoint,
  resetBaseVm,
  restoreVm,
} from "../services/vms/workflows";

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
      beginBaseOpen: () => Effect.fail(new Error("unused") as never),
      beginBaseReset: () => Effect.fail(new Error("unused") as never),
      markBaseCreateRunning: () => Effect.fail(new Error("unused") as never),
      markBaseCreateFailed: () => Effect.void,
      activeLimitCandidates: () => Effect.succeed([]),
      reservePausedResume: () => Effect.succeed(null),
      markProviderObservedStatus: () => Effect.succeed(false),
      markCreateRunning: () => Effect.succeed(running),
      markCreateFailed: () => Effect.void,
      hasOwnedSnapshot: () => Effect.succeed(false),
      findUserVm: () => Effect.succeed(null),
      markDestroyed: () => Effect.void,
      recordLease: () => Effect.void,
      listVmSessions: () => Effect.succeed([]),
      upsertVmSession: () => Effect.fail(new Error("unused") as never),
      activeIdentityLeases: () => Effect.succeed([]),
      markLeasesRevoked: () => Effect.void,
      getAgentRouting: () => Effect.succeed(null),
      upsertAgentRouting: () => Effect.fail(new Error("unused") as never),
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

  dbTest("creates one provider VM per account-scoped idempotency key and records usage", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

    let createCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          return {
            provider: "e2b" as const,
            providerVmId: `provider-vm-idem-${createCalls}`,
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
    const sameTeamOtherUser = await Effect.runPromise(
      createVm({
        userId: "user-workflow-idem-teammate",
        billingCustomerType: "team",
        billingTeamId: "team-workflow-idem",
        billingPlanId: "free",
        maxActiveVms: 1,
        provider: "e2b",
        image: "cmuxd-ws:test",
        imageVersion: "test-version",
        idempotencyKey: "idem-1",
      }).pipe(Effect.provide(layer)),
    );
    const sameUserDifferentTeam = await Effect.runPromise(
      createVm({
        userId: "user-workflow-idem",
        billingCustomerType: "team",
        billingTeamId: "team-workflow-idem-alt",
        billingPlanId: "free",
        maxActiveVms: 1,
        provider: "e2b",
        image: "cmuxd-ws:test",
        imageVersion: "test-version",
        idempotencyKey: "idem-1",
      }).pipe(Effect.provide(layer)),
    );

    expect(first).toEqual(second);
    expect(sameTeamOtherUser.providerVmId).toBe(first.providerVmId);
    expect(sameUserDifferentTeam.providerVmId).not.toBe(first.providerVmId);
    expect(createCalls).toBe(2);

    const [{ vmCount }] = await sql<{ vmCount: string }[]>`
      select count(*)::text as "vmCount" from cloud_vms where idempotency_key = 'idem-1'
    `;
    const [{ usageCount }] = await sql<{ usageCount: string }[]>`
      select count(*)::text as "usageCount" from cloud_vm_usage_events
      where event_type = 'vm.created' and metadata->>'idempotencyKeySet' = 'true'
    `;
    const [{ imageVersion }] = await sql<{ imageVersion: string | null }[]>`
      select image_version as "imageVersion" from cloud_vms where user_id = 'user-workflow-idem' and billing_team_id = 'team-workflow-idem'
    `;
    expect(vmCount).toBe("2");
    expect(usageCount).toBe("2");
    expect(imageVersion).toBe("test-version");
  });

  dbTest("opens Base as one stable VM per account scope", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

    let createCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          return {
            provider: "e2b" as const,
            providerVmId: `provider-vm-base-open-${createCalls}`,
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
    const first = await Effect.runPromise(openBaseVm({
      userId: "user-base-open",
      billingCustomerType: "team",
      billingTeamId: "team-base-open",
      billingPlanId: "free",
      maxActiveVms: 5,
      provider: "e2b",
      image: "cmuxd-ws:test",
      imageVersion: "test-version",
    }).pipe(Effect.provide(layer)));
    const second = await Effect.runPromise(openBaseVm({
      userId: "user-base-open-teammate",
      billingCustomerType: "team",
      billingTeamId: "team-base-open",
      billingPlanId: "free",
      maxActiveVms: 5,
      provider: "e2b",
      image: "cmuxd-ws:test",
      imageVersion: "test-version",
    }).pipe(Effect.provide(layer)));
    const otherTeam = await Effect.runPromise(openBaseVm({
      userId: "user-base-open",
      billingCustomerType: "team",
      billingTeamId: "team-base-open-alt",
      billingPlanId: "free",
      maxActiveVms: 5,
      provider: "e2b",
      image: "cmuxd-ws:test",
      imageVersion: "test-version",
    }).pipe(Effect.provide(layer)));
    const personal = await Effect.runPromise(openBaseVm({
      userId: "user-base-open",
      billingCustomerType: "user",
      billingTeamId: "user-base-open",
      billingPlanId: "free",
      maxActiveVms: 5,
      provider: "e2b",
      image: "cmuxd-ws:test",
      imageVersion: "test-version",
    }).pipe(Effect.provide(layer)));
    const personalReopen = await Effect.runPromise(openBaseVm({
      userId: "user-base-open",
      billingCustomerType: "user",
      billingTeamId: "user-base-open",
      billingPlanId: "free",
      maxActiveVms: 5,
      provider: "e2b",
      image: "cmuxd-ws:test",
      imageVersion: "test-version",
    }).pipe(Effect.provide(layer)));

    expect(second.providerVmId).toBe(first.providerVmId);
    expect(otherTeam.providerVmId).not.toBe(first.providerVmId);
    expect(personalReopen.providerVmId).toBe(personal.providerVmId);
    expect(personal.providerVmId).not.toBe(first.providerVmId);
    expect(first.generation).toBe(1);
    expect(second.generation).toBe(1);
    expect(personal.generation).toBe(1);
    expect(createCalls).toBe(3);

    const bases = await sql<{ scopeType: string; scopeId: string; activeProviderVmId: string; activeGeneration: number }[]>`
      select scope_type as "scopeType", scope_id as "scopeId", active_provider_vm_id as "activeProviderVmId", active_generation as "activeGeneration"
      from cloud_vm_bases
      order by scope_type, scope_id
    `;
    expect(bases).toEqual([
      { scopeType: "team", scopeId: "team-base-open", activeProviderVmId: first.providerVmId, activeGeneration: 1 },
      { scopeType: "team", scopeId: "team-base-open-alt", activeProviderVmId: otherTeam.providerVmId, activeGeneration: 1 },
      { scopeType: "user", scopeId: "user-base-open", activeProviderVmId: personal.providerVmId, activeGeneration: 1 },
    ]);
  });

  dbTest("resets Base by retaining the previous generation when capacity allows", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

    let createCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          return {
            provider: "freestyle" as const,
            providerVmId: `provider-vm-base-reset-${createCalls}`,
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
    const layer = providerLayer(provider);
    const first = await Effect.runPromise(openBaseVm({
      userId: "user-base-reset",
      billingCustomerType: "team",
      billingTeamId: "team-base-reset",
      billingPlanId: "free",
      maxActiveVms: 2,
      provider: "freestyle",
      image: "snapshot-test",
      imageVersion: "test-version",
    }).pipe(Effect.provide(layer)));
    const reset = await Effect.runPromise(resetBaseVm({
      userId: "user-base-reset",
      billingCustomerType: "team",
      billingTeamId: "team-base-reset",
      billingPlanId: "free",
      maxActiveVms: 2,
      provider: "freestyle",
      image: "snapshot-test",
      imageVersion: "test-version",
      reason: "test reset",
    }).pipe(Effect.provide(layer)));
    const reopened = await Effect.runPromise(openBaseVm({
      userId: "user-base-reset",
      billingCustomerType: "team",
      billingTeamId: "team-base-reset",
      billingPlanId: "free",
      maxActiveVms: 2,
      provider: "freestyle",
      image: "snapshot-test",
      imageVersion: "test-version",
    }).pipe(Effect.provide(layer)));

    expect(first.providerVmId).toBe("provider-vm-base-reset-1");
    expect(reset.providerVmId).toBe("provider-vm-base-reset-2");
    expect(reset.retainedProviderVmId).toBe(first.providerVmId);
    expect(reset.generation).toBe(2);
    expect(reopened.providerVmId).toBe(reset.providerVmId);
    expect(createCalls).toBe(2);

    const generations = await sql<{ generation: number; providerVmId: string; state: string; retained: boolean }[]>`
      select generation, provider_vm_id as "providerVmId", state, retained_at is not null as retained
      from cloud_vm_base_generations
      order by generation
    `;
    expect(generations).toEqual([
      { generation: 1, providerVmId: first.providerVmId, state: "retained", retained: true },
      { generation: 2, providerVmId: reset.providerVmId, state: "active", retained: false },
    ]);

    const [{ vmCount }] = await sql<{ vmCount: string }[]>`
      select count(*)::text as "vmCount"
      from cloud_vms
      where provider_vm_id in (${first.providerVmId}, ${reset.providerVmId})
        and status = 'running'
    `;
    expect(vmCount).toBe("2");
  });

  dbTest("does not reset Base past the active VM limit while retaining the previous generation", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.succeed({
          provider: "freestyle" as const,
          providerVmId: "provider-vm-base-reset-limit",
          status: "running" as const,
          image: "snapshot-test",
          createdAt: Date.now(),
        }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
    };
    const layer = providerLayer(provider);

    await Effect.runPromise(openBaseVm({
      userId: "user-base-reset-limit",
      billingCustomerType: "team",
      billingTeamId: "team-base-reset-limit",
      billingPlanId: "free",
      maxActiveVms: 1,
      provider: "freestyle",
      image: "snapshot-test",
      imageVersion: "test-version",
    }).pipe(Effect.provide(layer)));

    const error = await Effect.runPromise(resetBaseVm({
      userId: "user-base-reset-limit",
      billingCustomerType: "team",
      billingTeamId: "team-base-reset-limit",
      billingPlanId: "free",
      maxActiveVms: 1,
      provider: "freestyle",
      image: "snapshot-test",
      imageVersion: "test-version",
      reason: "limit test",
    }).pipe(Effect.flip, Effect.provide(layer)));

    expect(error).toBeInstanceOf(VmLimitExceededError);
  });

  dbTest("restores the retained Base generation when reset provider create fails", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

    let createCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () => {
        createCalls += 1;
        if (createCalls === 2) {
          return Effect.fail(new VmProviderOperationError({
            provider: "freestyle",
            operation: "create",
            cause: new Error("provider down"),
          }));
        }
        return Effect.succeed({
          provider: "freestyle" as const,
          providerVmId: "provider-vm-base-reset-recover-1",
          status: "running" as const,
          image: "snapshot-test",
          createdAt: Date.now(),
        });
      },
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
    };
    const layer = providerLayer(provider);

    const first = await Effect.runPromise(openBaseVm({
      userId: "user-base-reset-recover",
      billingCustomerType: "team",
      billingTeamId: "team-base-reset-recover",
      billingPlanId: "free",
      maxActiveVms: 2,
      provider: "freestyle",
      image: "snapshot-test",
      imageVersion: "test-version",
    }).pipe(Effect.provide(layer)));

    await Effect.runPromise(resetBaseVm({
      userId: "user-base-reset-recover",
      billingCustomerType: "team",
      billingTeamId: "team-base-reset-recover",
      billingPlanId: "free",
      maxActiveVms: 2,
      provider: "freestyle",
      image: "snapshot-test",
      imageVersion: "test-version",
      reason: "recover test",
    }).pipe(Effect.flip, Effect.provide(layer)));

    const reopened = await Effect.runPromise(openBaseVm({
      userId: "user-base-reset-recover",
      billingCustomerType: "team",
      billingTeamId: "team-base-reset-recover",
      billingPlanId: "free",
      maxActiveVms: 2,
      provider: "freestyle",
      image: "snapshot-test",
      imageVersion: "test-version",
    }).pipe(Effect.provide(layer)));

    expect(reopened.providerVmId).toBe(first.providerVmId);
    expect(createCalls).toBe(2);

    const generations = await sql<{ generation: number; state: string; providerVmId: string | null }[]>`
      select generation, state, provider_vm_id as "providerVmId"
      from cloud_vm_base_generations
      order by generation
    `;
    expect(generations).toEqual([
      { generation: 1, state: "active", providerVmId: first.providerVmId },
      { generation: 2, state: "failed", providerVmId: null },
    ]);
  });

  dbTest("reuses an idempotency key after a terminal failed row", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    await sql`
      insert into cloud_vms (user_id, billing_team_id, billing_plan_id, provider, image_id, status, idempotency_key, failure_code, failure_message)
      values ('user-workflow-idem-retry', 'team-workflow-idem-retry', 'free', 'freestyle', 'snapshot-test', 'failed', 'persistent-slot', 'provider_failed', 'previous create failed')
    `;

    let createCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          return {
            provider: "freestyle" as const,
            providerVmId: "provider-vm-idem-retry",
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

    const created = await Effect.runPromise(
      createVm({
        userId: "user-workflow-idem-retry",
        billingCustomerType: "team",
        billingTeamId: "team-workflow-idem-retry",
        billingPlanId: "free",
        maxActiveVms: 1,
        provider: "freestyle",
        image: "snapshot-test",
        imageVersion: "test-version",
        idempotencyKey: "persistent-slot",
      }).pipe(Effect.provide(providerLayer(provider))),
    );

    expect(created.providerVmId).toBe("provider-vm-idem-retry");
    expect(createCalls).toBe(1);

    const [{ activeSlotCount }] = await sql<{ activeSlotCount: string }[]>`
      select count(*)::text as "activeSlotCount"
      from cloud_vms
      where user_id = 'user-workflow-idem-retry'
        and idempotency_key = 'persistent-slot'
        and status = 'running'
    `;
    expect(activeSlotCount).toBe("1");
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

  dbTest("resumes a paused VM before minting SSH credentials", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    await sql`
      insert into cloud_vms (user_id, billing_team_id, billing_plan_id, provider, provider_vm_id, image_id, status)
      values ('user-workflow-resume-ssh', 'team-workflow-resume-ssh', 'free', 'freestyle', 'provider-vm-resume-ssh', 'snapshot-test', 'paused')
    `;

    let resumeCalls = 0;
    let sshCalls = 0;
    const callOrder: string[] = [];
    const provider: VmProviderGatewayShape = {
      create: () => Effect.fail(new Error("unused") as never),
      destroy: () => Effect.void,
      resume: () =>
        Effect.sync(() => {
          resumeCalls += 1;
          callOrder.push("resume");
          return {
            provider: "freestyle" as const,
            providerVmId: "provider-vm-resume-ssh",
            status: "running" as const,
            image: "snapshot-test",
            createdAt: Date.now(),
          };
        }),
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () =>
        Effect.sync(() => {
          sshCalls += 1;
          callOrder.push("openSSH");
          return {
            transport: "ssh" as const,
            host: "vm-ssh.freestyle.sh",
            port: 22,
            username: "provider-vm-resume-ssh+cmux",
            publicKeyFingerprint: null,
            credential: { kind: "password" as const, value: "token" },
            identityHandle: "identity-resumed",
          };
        }),
      revokeSSHIdentity: () => Effect.void,
    };

    const endpoint = await Effect.runPromise(
      openSshEndpoint({
        userId: "user-workflow-resume-ssh",
        billingTeamId: "team-workflow-resume-ssh",
        providerVmId: "provider-vm-resume-ssh",
      }).pipe(
        Effect.provide(providerLayer(provider)),
      ),
    );

    expect(endpoint.transport).toBe("ssh");
    expect(resumeCalls).toBe(1);
    expect(sshCalls).toBe(1);
    expect(callOrder).toEqual(["resume", "openSSH"]);

    const [vm] = await sql<{ status: string }[]>`
      select status from cloud_vms where provider_vm_id = 'provider-vm-resume-ssh'
    `;
    expect(vm?.status).toBe("running");

    const [{ resumeUsageCount }] = await sql<{ resumeUsageCount: string }[]>`
      select count(*)::text as "resumeUsageCount"
      from cloud_vm_usage_events
      where provider = 'freestyle'
        and event_type = 'vm.resumed'
        and metadata->>'source' = 'ssh'
        and vm_id in (
          select id from cloud_vms
          where provider_vm_id = 'provider-vm-resume-ssh'
        )
    `;
    expect(resumeUsageCount).toBe("1");
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

  dbTest("does not resume a paused VM when the billing team active limit is full", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    await sql`
      insert into cloud_vms (user_id, billing_team_id, billing_plan_id, provider, provider_vm_id, image_id, status)
      values
        ('user-workflow-resume-limit', 'team-workflow-resume-limit', 'resume-limit-one', 'freestyle', 'provider-vm-resume-running', 'snapshot-test', 'running'),
        ('user-workflow-resume-limit', 'team-workflow-resume-limit', 'resume-limit-one', 'freestyle', 'provider-vm-resume-paused', 'snapshot-test', 'paused')
    `;

    const previousLimit = process.env.CMUX_VM_PLAN_RESUME_LIMIT_ONE_MAX_ACTIVE_VMS;
    process.env.CMUX_VM_PLAN_RESUME_LIMIT_ONE_MAX_ACTIVE_VMS = "1";
    let resumeCalls = 0;
    let openAttachCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () => Effect.fail(new Error("unused") as never),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      resume: () =>
        Effect.sync(() => {
          resumeCalls += 1;
          return {
            provider: "freestyle" as const,
            providerVmId: "provider-vm-resume-paused",
            status: "running" as const,
            image: "snapshot-test",
            createdAt: Date.now(),
          };
        }),
      openAttach: () =>
        Effect.sync(() => {
          openAttachCalls += 1;
          return {
            transport: "ssh" as const,
            host: "vm-ssh.example.invalid",
            port: 22,
            username: "cmux",
            publicKeyFingerprint: null,
            credential: { kind: "password" as const, value: "token" },
            identityHandle: "identity-unused",
          };
        }),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
    };

    try {
      const error = await Effect.runPromise(
        openAttachEndpoint({
          userId: "user-workflow-resume-limit",
          billingTeamId: "team-workflow-resume-limit",
          providerVmId: "provider-vm-resume-paused",
        }).pipe(
          Effect.flip,
          Effect.provide(providerLayer(provider)),
        ),
      );

      expect(error).toBeInstanceOf(VmLimitExceededError);
      expect(resumeCalls).toBe(0);
      expect(openAttachCalls).toBe(0);
      const [pausedVm] = await sql<{ status: string }[]>`
        select status from cloud_vms where provider_vm_id = 'provider-vm-resume-paused'
      `;
      expect(pausedVm?.status).toBe("paused");
    } finally {
      if (previousLimit === undefined) {
        delete process.env.CMUX_VM_PLAN_RESUME_LIMIT_ONE_MAX_ACTIVE_VMS;
      } else {
        process.env.CMUX_VM_PLAN_RESUME_LIMIT_ONE_MAX_ACTIVE_VMS = previousLimit;
      }
    }
  });

  dbTest("rejects restore when the snapshot id is not owned by the user and billing team", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

    let createCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: () =>
        Effect.sync(() => {
          createCalls += 1;
          return {
            provider: "freestyle" as const,
            providerVmId: "provider-vm-restore-unowned",
            status: "running" as const,
            image: "snapshot-unowned",
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
      restoreVm({
        userId: "user-workflow-restore",
        billingCustomerType: "team",
        billingTeamId: "team-workflow-restore",
        billingPlanId: "free",
        maxActiveVms: 1,
        provider: "freestyle",
        snapshotId: "snapshot-unowned",
      }).pipe(
        Effect.flip,
        Effect.provide(providerLayer(provider)),
      ),
    );

    expect(error).toBeInstanceOf(VmSnapshotNotFoundError);
    expect(createCalls).toBe(0);
  });

  dbTest("allows restore only from a snapshot event owned by the same user and billing team", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    await sql`
      insert into cloud_vm_usage_events (user_id, billing_team_id, billing_plan_id, event_type, provider, image_id, metadata)
      values
        ('user-workflow-restore', 'team-other-restore', 'free', 'vm.snapshot.created', 'freestyle', 'snapshot-test', '{"snapshotId":"snapshot-owned"}'::jsonb),
        ('user-workflow-restore', 'team-workflow-restore', 'free', 'vm.snapshot.created', 'freestyle', 'snapshot-test', '{"snapshotId":"snapshot-owned"}'::jsonb)
    `;

    let createCalls = 0;
    const provider: VmProviderGatewayShape = {
      create: (_provider, options) =>
        Effect.sync(() => {
          createCalls += 1;
          expect(options.image).toBe("snapshot-owned");
          return {
            provider: "freestyle" as const,
            providerVmId: "provider-vm-restore-owned",
            status: "running" as const,
            image: options.image,
            createdAt: Date.now(),
          };
        }),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
    };

    const restored = await Effect.runPromise(
      restoreVm({
        userId: "user-workflow-restore",
        billingCustomerType: "team",
        billingTeamId: "team-workflow-restore",
        billingPlanId: "free",
        maxActiveVms: 1,
        provider: "freestyle",
        snapshotId: "snapshot-owned",
      }).pipe(Effect.provide(providerLayer(provider))),
    );

    expect(restored.providerVmId).toBe("provider-vm-restore-owned");
    expect(createCalls).toBe(1);
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
      destroyVm({
        userId: "user-workflow-reuse-slot",
        billingTeamId: "team-workflow-reuse-slot",
        providerVmId: "provider-vm-reuse-old",
      }).pipe(
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
            attachmentId: "attachment-private",
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

  dbTest("allows a teammate to list and attach a team-owned VM", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    await sql`
      insert into cloud_vms (user_id, billing_team_id, billing_plan_id, provider, provider_vm_id, image_id, status)
      values ('user-workflow-owner', 'team-workflow-shared', 'free', 'freestyle', 'provider-vm-shared-team', 'snapshot-test', 'running')
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
            token: "pty-token-shared",
            sessionId: "pty-session-shared",
            attachmentId: "attachment-shared",
            expiresAtUnix: Math.floor(Date.now() / 1000) + 300,
          };
        }),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
    };
    const layer = providerLayer(provider);

    const listed = await Effect.runPromise(
      listUserVms("user-workflow-teammate", "team-workflow-shared").pipe(Effect.provide(layer)),
    );
    expect(listed.map((entry) => entry.providerVmId)).toEqual(["provider-vm-shared-team"]);

    const endpoint = await Effect.runPromise(
      openAttachEndpoint({
        userId: "user-workflow-teammate",
        billingTeamId: "team-workflow-shared",
        providerVmId: "provider-vm-shared-team",
      }).pipe(Effect.provide(layer)),
    );
    expect(endpoint.transport).toBe("websocket");
    expect(attachCalls).toBe(1);

    const wrongAccountError = await Effect.runPromise(
      openAttachEndpoint({
        userId: "user-workflow-teammate",
        billingTeamId: "team-workflow-other",
        providerVmId: "provider-vm-shared-team",
      }).pipe(Effect.flip, Effect.provide(layer)),
    );
    expect(wrongAccountError).toBeInstanceOf(VmNotFoundError);
  });

  dbTest("lists migrated account-scoped personal VMs by default", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    await sql`
      insert into cloud_vms (user_id, billing_team_id, billing_plan_id, provider, provider_vm_id, image_id, status, created_at)
      values
        ('user-workflow-personal', 'user-workflow-personal', 'free', 'freestyle', 'provider-vm-personal-migrated', 'snapshot-test', 'running', now()),
        ('user-workflow-personal', null, 'free', 'freestyle', 'provider-vm-personal-legacy', 'snapshot-test', 'running', now()),
        ('user-workflow-other', 'user-workflow-other', 'free', 'freestyle', 'provider-vm-personal-other', 'snapshot-test', 'running', now())
    `;

    const listed = await Effect.runPromise(
      listUserVms("user-workflow-personal").pipe(Effect.provide(providerLayer({
        create: () => Effect.fail(new Error("unused") as never),
        destroy: () => Effect.void,
        exec: () => Effect.fail(new Error("unused") as never),
        openAttach: () => Effect.fail(new Error("unused") as never),
        openSSH: () => Effect.fail(new Error("unused") as never),
        revokeSSHIdentity: () => Effect.void,
      }))),
    );

    expect(listed.map((entry) => entry.providerVmId).sort()).toEqual([
      "provider-vm-personal-legacy",
      "provider-vm-personal-migrated",
    ]);
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
            attachmentId: `attachment-${attachCount}`,
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

  dbTest("records requested VM session metadata when opening a stable WebSocket attach", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vm_sessions, cloud_vms restart identity cascade`;
    const [vm] = await sql<{ id: string }[]>`
      insert into cloud_vms (user_id, provider, provider_vm_id, image_id, status)
      values ('user-workflow-session', 'freestyle', 'provider-vm-session-1', 'snapshot-test', 'running')
      returning id
    `;

    let attachOptions: unknown;
    const provider: VmProviderGatewayShape = {
      create: () => Effect.fail(new Error("unused") as never),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: (_provider, _vmId, options) =>
        Effect.sync(() => {
          attachOptions = options;
          return {
            transport: "websocket" as const,
            url: "wss://example.invalid/pty",
            headers: {},
            token: "stable-pty-token",
            sessionId: options?.sessionId ?? "unexpected-session",
            attachmentId: options?.attachmentId ?? "unexpected-attachment",
            expiresAtUnix: Math.floor(Date.now() / 1000) + 300,
            daemon: {
              url: "wss://example.invalid/rpc",
              headers: {},
              token: "stable-rpc-token-2",
              sessionId: "stable-rpc-session-2",
              expiresAtUnix: Math.floor(Date.now() / 1000) + 600,
            },
          };
        }),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
    };

    const result = await Effect.runPromise(
      openAttachEndpoint({
        userId: "user-workflow-session",
        providerVmId: "provider-vm-session-1",
        sessionTitle: "iPhone shell",
        options: {
          requireDaemon: true,
          sessionId: "session-ios-1",
          attachmentId: "attach-ios-1",
        },
      }).pipe(Effect.provide(providerLayer(provider))),
    );

    expect(result.transport).toBe("websocket");
    expect(attachOptions).toEqual({
      requireDaemon: true,
      sessionId: "session-ios-1",
      attachmentId: "attach-ios-1",
      providerMetadata: {},
    });
    const sessions = await sql<{ providerSessionId: string; title: string | null; attachmentCount: number; metadata: Record<string, unknown> }[]>`
      select provider_session_id as "providerSessionId", title, attachment_count as "attachmentCount", metadata
      from cloud_vm_sessions
      where vm_id = ${vm.id}
    `;
    expect(sessions).toEqual([{
      providerSessionId: "session-ios-1",
      title: "iPhone shell",
      attachmentCount: 1,
      metadata: {
        transport: "websocket",
        daemonAvailable: true,
        attachmentId: "attach-ios-1",
      },
    }]);
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
    providerMetadata: {},
    ...overrides,
  };
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
