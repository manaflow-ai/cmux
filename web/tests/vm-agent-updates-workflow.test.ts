import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import { guestAgentUpdatesCommand } from "../services/vms/guestAgentUpdates";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmRepository, type CloudVmRow, type VmRepositoryShape } from "../services/vms/repository";
import { createVm, openVmCmuxRemote, setVmAgentUpdates } from "../services/vms/workflows";

const NOW = new Date("2026-01-01T00:00:00.000Z");

function row(overrides: Partial<CloudVmRow> = {}): CloudVmRow {
  return {
    id: "00000000-0000-4000-8000-000000000401",
    userId: "user-agents",
    billingTeamId: "team-agents",
    billingPlanId: "pro",
    provider: "freestyle",
    providerVmId: "vm-agents",
    displayName: null,
    slug: null,
    imageId: "snapshot-test",
    imageVersion: null,
    status: "running",
    idempotencyKey: null,
    createdAt: NOW,
    updatedAt: NOW,
    destroyedAt: null,
    failureCode: null,
    failureMessage: null,
    providerMetadata: {},
    networkPolicy: null,
    networkPolicyStatus: null,
    agentUpdates: null,
    ownerTeamId: "team-agents",
    coderouterPoolId: null,
    ...overrides,
  };
}

function harness(options: { vm?: CloudVmRow; exec?: () => Effect.Effect<{ exitCode: number; stdout: string; stderr: string }, Error> } = {}) {
  const execs: string[] = [];
  const settings: Array<{ id: string; agentUpdates: string }> = [];
  const begun: Array<Record<string, unknown>> = [];
  const vm = options.vm ?? row();
  const repo = {
    findUserVm: () => Effect.succeed(vm),
    setAgentUpdates: (input: { id: string; agentUpdates: string }) => Effect.sync(() => { settings.push(input); }),
    recordLease: () => Effect.void,
    recordUsageEvent: () => Effect.void,
    recordUsageEvents: () => Effect.void,
    beginCreate: (input: Record<string, unknown>) => Effect.sync(() => {
      begun.push(input);
      return { inserted: true, vm: row({ status: "provisioning", providerVmId: null }) };
    }),
    legacyResourceReservationCandidates: () => Effect.succeed([]),
    claimBillingGrant: () => Effect.succeed({ kind: "already_claimed" as const }),
    markBillingGrantApplied: () => Effect.void,
    deleteBillingGrant: () => Effect.void,
    markCreateRunning: () => Effect.succeed(row({ agentUpdates: "latest" })),
    markCreateFailed: () => Effect.void,
    findNetwork: () => Effect.succeed(null),
    upsertNetwork: () => Effect.succeed({
      id: "network-row", userId: "user-agents", provider: "freestyle" as const, providerNetworkId: "network-1",
      slug: "cmux-agents", cidr: "10.0.0.0/24", cidrV6: "fd00::/64", createdAt: NOW, updatedAt: NOW,
    }),
  } as unknown as VmRepositoryShape;
  const providers = {
    openCmuxRemote: () => Effect.succeed({
      transport: "cmux-remote", route: "ws://10.0.0.5:1337/v1/link", token: "test-token",
      session: "test-session", expiresAtUnix: 2_000_000_000, trustedCarrier: true,
    }),
    create: () => Effect.succeed({ provider: "freestyle" as const, providerVmId: "vm-agents", status: "running" as const, image: "snapshot-test", createdAt: NOW.getTime() }),
    destroy: () => Effect.void,
    exec: (_provider: string, _vmId: string, command: string) => {
      execs.push(command);
      return options.exec?.() ?? Effect.succeed({ exitCode: 0, stdout: "", stderr: "" });
    },
    supportsPrivateNetworking: () => true,
    ensureNetwork: () => Effect.succeed({ id: "network-1", slug: "cmux-agents", cidr: "10.0.0.0/24", cidrV6: "fd00::/64" }),
  } as unknown as VmProviderGatewayShape;
  const layer = Layer.mergeAll(
    Layer.succeed(VmRepository, repo),
    Layer.succeed(VmProviderGateway, providers),
    Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
  );
  // Collects deferred work the way the route's runAfterResponse would, so a
  // test can run it after the response and see that attach never waited.
  const deferred: Array<Effect.Effect<void>> = [];
  const deferAfterResponse = (work: Effect.Effect<void>) => { deferred.push(work); };
  return { layer, execs, settings, begun, deferred, deferAfterResponse };
}

const access = { userId: "user-agents", billingTeamId: "team-agents", teamIds: ["team-agents"], providerVmId: "vm-agents", callerPlanId: "pro" };

describe("agent updates workflows", () => {
  test("an image-pinned attach runs no guest exec", async () => {
    const h = harness();
    await Effect.runPromise(openVmCmuxRemote({ ...access, deferAfterResponse: h.deferAfterResponse }).pipe(Effect.provide(h.layer)));
    expect(h.deferred).toHaveLength(0);
    expect(h.execs).toHaveLength(0);
  });

  test("an opted-in attach sends the updater after the response", async () => {
    const h = harness({ vm: row({ agentUpdates: "latest" }) });
    const endpoint = await Effect.runPromise(openVmCmuxRemote({ ...access, deferAfterResponse: h.deferAfterResponse }).pipe(Effect.provide(h.layer)));
    expect(endpoint.token).toBe("test-token");
    expect(h.execs).toHaveLength(0);
    expect(h.deferred).toHaveLength(1);
    await Effect.runPromise(h.deferred[0]!);
    expect(h.execs).toEqual([guestAgentUpdatesCommand("latest")]);
  });

  test("a failing or non-zero guest exec never fails the attach", async () => {
    for (const exec of [
      () => Effect.fail(new Error("guest unreachable")),
      () => Effect.succeed({ exitCode: 1, stdout: "", stderr: "sudo: a password is required" }),
    ]) {
      const h = harness({ vm: row({ agentUpdates: "latest" }), exec });
      const endpoint = await Effect.runPromise(openVmCmuxRemote({ ...access, deferAfterResponse: h.deferAfterResponse }).pipe(Effect.provide(h.layer)));
      expect(endpoint.token).toBe("test-token");
      await Effect.runPromise(h.deferred[0]!);
      expect(h.execs).toHaveLength(1);
    }
  });

  test("changing the setting stores it and tells a running guest after the response", async () => {
    const h = harness();
    const entry = await Effect.runPromise(setVmAgentUpdates({ ...access, agentUpdates: "latest", deferAfterResponse: h.deferAfterResponse }).pipe(Effect.provide(h.layer)));
    expect(entry.agentUpdates).toBe("latest");
    expect(h.settings).toEqual([{ id: row().id, agentUpdates: "latest" }]);
    await Effect.runPromise(h.deferred[0]!);
    expect(h.execs).toEqual([guestAgentUpdatesCommand("latest")]);

    const off = harness({ vm: row({ agentUpdates: "latest" }) });
    const pinned = await Effect.runPromise(setVmAgentUpdates({ ...access, agentUpdates: "image", deferAfterResponse: off.deferAfterResponse }).pipe(Effect.provide(off.layer)));
    expect(pinned.agentUpdates).toBe("image");
    await Effect.runPromise(off.deferred[0]!);
    expect(off.execs).toEqual([guestAgentUpdatesCommand("image")]);
  });

  test("a paused machine is not woken by a setting change", async () => {
    const h = harness({ vm: row({ status: "paused" }) });
    await Effect.runPromise(setVmAgentUpdates({ ...access, agentUpdates: "latest", deferAfterResponse: h.deferAfterResponse }).pipe(Effect.provide(h.layer)));
    expect(h.settings).toHaveLength(1);
    expect(h.deferred).toHaveLength(0);
    expect(h.execs).toHaveLength(0);
  });

  test("an opted-in create starts the updater after the response", async () => {
    // The create response carries the first connection, so no later attach
    // is guaranteed; without this a new machine kept its image's agents.
    const create = (agentUpdates: "latest" | undefined, h: ReturnType<typeof harness>) => Effect.runPromise(createVm({
      userId: "user-agents",
      billingCustomerType: "team",
      billingTeamId: "team-agents",
      billingPlanId: "pro",
      maxActiveVms: 50,
      provider: "freestyle",
      image: "snapshot-test",
      ...(agentUpdates ? { agentUpdates } : {}),
      deferAfterResponse: h.deferAfterResponse,
    }).pipe(Effect.provide(h.layer)));
    const updater = guestAgentUpdatesCommand("latest");

    const opted = harness();
    await create("latest", opted);
    expect(opted.execs).not.toContain(updater);
    for (const work of opted.deferred) await Effect.runPromise(work);
    expect(opted.execs.filter((command) => command === updater)).toHaveLength(1);
  });

  test("create stores the opt-in on the new row", async () => {
    const h = harness();
    const entry = await Effect.runPromise(createVm({
      userId: "user-agents",
      billingCustomerType: "team",
      billingTeamId: "team-agents",
      billingPlanId: "max",
      maxActiveVms: 50,
      provider: "freestyle",
      image: "snapshot-test",
      imageSize: { name: "xl", cpu: 16, memoryMb: 32768, storageMb: 131072 },
      agentUpdates: "latest",
    }).pipe(Effect.provide(h.layer)));
    expect(h.begun[0]?.agentUpdates).toBe("latest");
    expect(entry.agentUpdates).toBe("latest");
  });
});
