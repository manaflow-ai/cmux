import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import {
  VmBillingGateway,
  noOpVmBillingGateway,
  type VmBillingGatewayShape,
} from "../services/vms/billingGateway";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepositoryLive } from "../services/vms/repository";
import {
  VmCreateCreditsInsufficientError,
  VmLimitExceededError,
  VmNotFoundError,
} from "../services/vms/errors";
import {
  createVm,
  destroyVm,
  execVm,
  openAttachEndpoint,
  openSshEndpoint,
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
  dbTest("creates one provider VM per user idempotency key and records usage", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

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
    await sql`truncate cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
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
    await sql`truncate cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
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

  dbTest("reserves Stack Auth credits only once per new idempotency key", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

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

  dbTest("does not call the provider when Stack Auth credits are insufficient", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

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
  });

  dbTest("refunds a reserved Stack Auth credit when provider create fails", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

    const provider: VmProviderGatewayShape = {
      create: () => Effect.fail(new Error("provider unavailable") as never),
      destroy: () => Effect.void,
      exec: () => Effect.succeed({ exitCode: 0, stdout: "", stderr: "" }),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
    };
    let refundCalls = 0;
    const billing: VmBillingGatewayShape = {
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
  });

  dbTest("does not attach another user's VM", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
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
    await sql`truncate cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
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
    await sql`truncate cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
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
