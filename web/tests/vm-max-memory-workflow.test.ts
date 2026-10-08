import { expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { VmRepository, type VmRepositoryShape } from "../services/vms/repository";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import { createVm, forkVm, networkSlugForUser, openBaseVm, resetBaseVm, restoreVm, resumeVm } from "../services/vms/workflows";
import { vmWorkflowErrorCause, vmWorkflowErrorFromCause, VmProviderOperationError } from "../services/vms/errors";

test("create, fork, and restore reject a 64 GB machine on Pro before provisioning", async () => {
  let creates = 0;
  const reservation = { memoryMb: 65536, vcpus: 16, diskMb: 131072 };
  const repo = {
    findUserVm: () => Effect.succeed({ id: "row", userId: "user", billingTeamId: "team", ownerTeamId: "team", coderouterPoolId: null, status: "running", provider: "freestyle", providerVmId: "vm", providerMetadata: { cmuxResourceReservation: reservation } }),
    hasOwnedSnapshot: () => Effect.succeed(true),
    ownedSnapshotResourceReservation: () => Effect.succeed(reservation),
    beginCreate: () => Effect.sync(() => { creates++; throw new Error("must not create"); }),
  } as unknown as VmRepositoryShape;
  const providers = { getStats: () => Effect.succeed({ memoryTotalMb: 65536, cpus: 16, diskTotalMb: 131072 }) } as unknown as VmProviderGatewayShape;
  const layer = Layer.mergeAll(Layer.succeed(VmRepository, repo), Layer.succeed(VmProviderGateway, providers), Layer.succeed(VmBillingGateway, noOpVmBillingGateway()));
  const caller = { userId: "user", billingCustomerType: "team" as const, billingTeamId: "team", billingPlanId: "pro", maxActiveVms: 5 };
  for (const program of [
    createVm({ ...caller, provider: "freestyle", image: "snapshot", memoryMb: 65536 }).pipe(Effect.asVoid),
    forkVm({ ...caller, teamIds: ["team"], providerVmId: "vm" }).pipe(Effect.asVoid),
    restoreVm({ ...caller, provider: "freestyle", snapshotId: "snapshot" }).pipe(Effect.asVoid),
  ]) {
    try {
      await Effect.runPromise(program.pipe(Effect.provide(layer)));
      throw new Error("expected plan rejection");
    } catch (error) {
      expect(vmWorkflowErrorCause(error)?._tag).toBe("VmMemoryPlanError");
    }
  }
  expect(creates).toBe(0);
});

test("Pro rejects a 12-vCPU create shape even when memory is within the plan ceiling", async () => {
  const layer = Layer.mergeAll(
    Layer.succeed(VmRepository, {} as VmRepositoryShape),
    Layer.succeed(VmProviderGateway, {} as VmProviderGatewayShape),
    Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
  );
  const caller = {
    userId: "u",
    billingCustomerType: "user" as const,
    billingTeamId: "u",
    billingPlanId: "pro",
    maxActiveVms: 5,
    provider: "freestyle" as const,
    image: "snapshot",
  };
  const invalidReservation = { vcpus: 12, memoryMb: 16 * 1024, diskMb: 96 * 1024 };
  for (const program of [
    createVm({ ...caller, resourceReservation: invalidReservation }).pipe(Effect.asVoid),
    openBaseVm({ ...caller, imageSize: { name: "lgx", cpu: 12, memoryMb: 16 * 1024, storageMb: 96 * 1024 } }).pipe(Effect.asVoid),
    resetBaseVm({ ...caller, imageSize: { name: "lgx", cpu: 12, memoryMb: 16 * 1024, storageMb: 96 * 1024 } }).pipe(Effect.asVoid),
  ]) {
    try {
      await Effect.runPromise(program.pipe(Effect.provide(layer)));
      throw new Error("expected plan rejection");
    } catch (error) {
      expect(vmWorkflowErrorCause(error)?._tag).toBe("VmMemoryPlanError");
    }
  }
});

test("Go rejects undersized CPU, memory, and disk before billing or provider work", async () => {
  const layer = Layer.mergeAll(Layer.succeed(VmRepository, {} as VmRepositoryShape),
    Layer.succeed(VmProviderGateway, {} as VmProviderGatewayShape), Layer.succeed(VmBillingGateway, noOpVmBillingGateway()));
  for (const shape of [{ vcpus: 1, memoryMb: 4096, diskMb: 16384 }, { vcpus: 2, memoryMb: 2048, diskMb: 16384 }, { vcpus: 2, memoryMb: 4096, diskMb: 8192 }]) {
    try {
      await Effect.runPromise(createVm({ userId: "u", billingCustomerType: "user", billingTeamId: "u", billingPlanId: "go",
        maxActiveVms: 1, provider: "freestyle", image: "small", resourceReservation: shape }).pipe(Effect.provide(layer)));
      throw new Error("expected shape rejection");
    } catch (error) { expect(vmWorkflowErrorCause(error)?._tag).toBe("VmGoShapeError"); }
  }
});

test("a gateway fork method cannot override the provider capability", async () => {
  let snapshots = 0;
  let forks = 0;
  let creates = 0;
  const repo = {
    findUserVm: () => Effect.succeed({ id: "row", userId: "u", billingTeamId: "u", ownerTeamId: "u", coderouterPoolId: null, status: "running", provider: "freestyle",
      providerVmId: "vm", providerMetadata: { cmuxResourceReservation: { memoryMb: 8192, vcpus: 4, diskMb: 32768 } } }),
    beginCreate: () => Effect.sync(() => { creates++; throw new Error("must not reserve a native fork"); }),
  } as unknown as VmRepositoryShape;
  const provider = {
    capabilities: () => ({ fork: false }),
    fork: () => Effect.sync(() => { forks++; throw new Error("unsupported native fork called"); }),
    snapshot: () => { snapshots++; return Effect.fail(new VmProviderOperationError({ provider: "freestyle", operation: "snapshot_fallback", cause: "test stop" })); },
  } as unknown as VmProviderGatewayShape;
  const layer = Layer.mergeAll(Layer.succeed(VmRepository, repo), Layer.succeed(VmProviderGateway, provider), Layer.succeed(VmBillingGateway, noOpVmBillingGateway()));
  await Effect.runPromiseExit(forkVm({ userId: "u", billingCustomerType: "user", billingTeamId: "u", billingPlanId: "pro",
    maxActiveVms: 5, providerVmId: "vm" }).pipe(Effect.provide(layer)));
  expect(snapshots).toBe(1);
  expect(forks).toBe(0);
  expect(creates).toBe(0);
});

test("a native fork retry cannot return a Max-sized row to Pro", async () => {
  let forks = 0;
  const source = {
    id: "source",
    userId: "u",
    billingTeamId: "u",
    ownerTeamId: "u",
    coderouterPoolId: null,
    status: "running" as const,
    provider: "freestyle" as const,
    providerVmId: "source-provider-vm",
    imageId: "snapshot",
    imageVersion: null,
    createdAt: new Date("2026-01-01T00:00:00Z"),
    displayName: null,
    slug: null,
    providerMetadata: {
      cmuxResourceReservation: { memoryMb: 8192, vcpus: 4, diskMb: 32768 },
    },
  };
  const existing = {
    ...source,
    id: "fork",
    providerVmId: "fork-provider-vm",
    providerMetadata: {
      cmuxResourceReservation: { memoryMb: 24576, vcpus: 12, diskMb: 98304 },
    },
  };
  const repo = {
    findUserVm: () => Effect.succeed(source),
    beginCreate: () => Effect.succeed({ inserted: false as const, vm: existing }),
  } as unknown as VmRepositoryShape;
  const providers = {
    capabilities: () => ({ fork: true }),
    fork: () => Effect.sync(() => {
      forks += 1;
      throw new Error("must not fork after the entitlement check");
    }),
  } as unknown as VmProviderGatewayShape;
  const layer = Layer.mergeAll(
    Layer.succeed(VmRepository, repo),
    Layer.succeed(VmProviderGateway, providers),
    Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
  );

  const result = await Effect.runPromiseExit(forkVm({
    userId: "u",
    billingCustomerType: "user",
    billingTeamId: "u",
    billingPlanId: "pro",
    maxActiveVms: 5,
    providerVmId: "source-provider-vm",
    idempotencyKey: "retry",
  }).pipe(Effect.provide(layer)));

  expect(result._tag).toBe("Failure");
  if (result._tag === "Failure") {
    expect(vmWorkflowErrorFromCause(result.cause)?._tag).toBe("VmMemoryPlanError");
  }
  expect(forks).toBe(0);
});


test("Pro cannot bypass the memory gate with unknown snapshot or fork dimensions", async () => {
  const repo = {
    findUserVm: () => Effect.succeed({ id: "row", userId: "u", billingTeamId: "u", ownerTeamId: "u", coderouterPoolId: null, status: "running", provider: "freestyle", providerVmId: "vm", providerMetadata: {} }),
    hasOwnedSnapshot: () => Effect.succeed(true),
    ownedSnapshotResourceReservation: () => Effect.succeed(null),
  } as unknown as VmRepositoryShape;
  const layer = Layer.mergeAll(Layer.succeed(VmRepository, repo),
    Layer.succeed(VmProviderGateway, {
      getStats: () => Effect.succeed({ memoryTotalMb: 65536, cpus: 32, diskTotalMb: 131072 }),
    } as unknown as VmProviderGatewayShape), Layer.succeed(VmBillingGateway, noOpVmBillingGateway()));
  const caller = { userId: "u", billingCustomerType: "user" as const, billingTeamId: "u", billingPlanId: "pro", maxActiveVms: 5 };
  for (const program of [
    forkVm({ ...caller, providerVmId: "vm" }).pipe(Effect.asVoid),
    restoreVm({ ...caller, provider: "freestyle", snapshotId: "snapshot" }).pipe(Effect.asVoid),
    createVm({ ...caller, provider: "freestyle", image: "snapshot", memoryMb: 65536,
      imageSize: { name: "2xl", cpu: 32, memoryMb: 65536, storageMb: 131072 } }).pipe(Effect.asVoid),
  ]) {
    try {
      await Effect.runPromise(program.pipe(Effect.provide(layer)));
      throw new Error("expected plan rejection");
    } catch (error) {
      expect(vmWorkflowErrorCause(error)?._tag).toBe("VmMemoryPlanError");
    }
  }
});

test("access verbs refuse a machine larger than the caller's current plan", async () => {
  const run = async (callerPlanId: string, reservation: { memoryMb: number; vcpus: number; diskMb: number }) => {
    const repo = {
      findUserVm: () => Effect.succeed({ id: "row", userId: "u", billingTeamId: "u", ownerTeamId: "u", coderouterPoolId: null, status: "running",
        provider: "freestyle", providerVmId: "vm", providerMetadata: { cmuxResourceReservation: reservation } }),
    } as unknown as VmRepositoryShape;
    // No resume/getStatus adapter: a machine that passes the plan gate
    // answers "running" without any provider call.
    const layer = Layer.mergeAll(Layer.succeed(VmRepository, repo),
      Layer.succeed(VmProviderGateway, {} as VmProviderGatewayShape), Layer.succeed(VmBillingGateway, noOpVmBillingGateway()));
    return Effect.runPromise(resumeVm({ userId: "u", billingTeamId: "u", providerVmId: "vm", maxActiveVms: 5, callerPlanId })
      .pipe(Effect.provide(layer)))
      .then(() => null, (error) => vmWorkflowErrorCause(error)?._tag ?? "unknown");
  };
  // A 64 GB Max machine is locked on Pro.
  expect(await run("pro", { memoryMb: 65536, vcpus: 32, diskMb: 131072 })).toBe("VmMemoryPlanError");
  // CPU above the plan also locks an 8 GB machine.
  expect(await run("pro", { memoryMb: 8192, vcpus: 20, diskMb: 32768 })).toBe("VmMemoryPlanError");
  expect(await run("team", { memoryMb: 65536, vcpus: 16, diskMb: 131072 })).toBe("VmMemoryPlanError");
  // CPU above Max's 2xl row is above every plan.
  expect(await run("max", { memoryMb: 65536, vcpus: 40, diskMb: 131072 })).toBe("VmMemoryPlanError");
  // Machines inside the plan pass.
  expect(await run("pro", { memoryMb: 16384, vcpus: 8, diskMb: 65536 })).toBeNull();
  expect(await run("max", { memoryMb: 65536, vcpus: 32, diskMb: 131072 })).toBeNull();
});

test("paid access probes legacy rows without a reservation before allowing open or resume", async () => {
  const row = {
    id: "row",
    userId: "u",
    billingTeamId: "u",
    ownerTeamId: "u",
    coderouterPoolId: null,
    status: "running" as const,
    provider: "freestyle" as const,
    providerVmId: "vm",
    providerMetadata: {},
  };
  const repo = { findUserVm: () => Effect.succeed(row) } as unknown as VmRepositoryShape;
  const providers = {
    getStats: () => Effect.succeed({ memoryTotalMb: 24576, cpus: 12, diskTotalMb: 98304 }),
  } as unknown as VmProviderGatewayShape;
  const layer = Layer.mergeAll(
    Layer.succeed(VmRepository, repo),
    Layer.succeed(VmProviderGateway, providers),
    Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
  );
  const result = await Effect.runPromiseExit(
    resumeVm({ userId: "u", billingTeamId: "u", providerVmId: "vm", maxActiveVms: 5, callerPlanId: "pro" })
      .pipe(Effect.provide(layer)),
  );
  expect(result._tag).toBe("Failure");
  expect(vmWorkflowErrorFromCause(result.cause)?._tag).toBe("VmMemoryPlanError");
});

test("reopening an existing oversized Base cannot bypass the caller's Pro CPU ceiling", async () => {
  const base = { id: "base", name: "default" };
  const generation = { id: "generation", generation: 1 };
  const caller = {
    userId: "u",
    billingCustomerType: "user" as const,
    billingTeamId: "u",
    billingPlanId: "pro",
    maxActiveVms: 5,
    provider: "freestyle" as const,
    image: "snapshot",
    baseName: "default",
  };
  for (const vcpus of [12, 16]) {
    const existing = {
      id: `vm-${vcpus}`,
      userId: "u",
      billingTeamId: "u",
      ownerTeamId: "u",
      coderouterPoolId: null,
      status: "running" as const,
      provider: "freestyle" as const,
      providerVmId: `provider-vm-${vcpus}`,
      providerMetadata: {
        cmuxResourceReservation: {
          vcpus,
          memoryMb: vcpus * 2 * 1024,
          diskMb: 128 * 1024,
        },
      },
    };
    const repo = {
      beginBaseOpen: () => Effect.succeed({
        kind: "existing" as const,
        base,
        generation,
        vm: existing,
      }),
    } as unknown as VmRepositoryShape;
    const providers = {
      getStatus: () => Effect.succeed("running" as const),
    } as unknown as VmProviderGatewayShape;
    const layer = Layer.mergeAll(
      Layer.succeed(VmRepository, repo),
      Layer.succeed(VmProviderGateway, providers),
      Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
    );
    const result = await Effect.runPromiseExit(openBaseVm(caller).pipe(Effect.provide(layer)));
    expect(result._tag).toBe("Failure");
    if (result._tag === "Failure") {
      expect(vmWorkflowErrorFromCause(result.cause)?._tag).toBe("VmMemoryPlanError");
    }
  }
});

test("reopening a markerless Base persists the measured reservation before returning it", async () => {
  const base = { id: "base", name: "default" };
  const generation = { id: "generation", generation: 1 };
  const existing = {
    id: "vm",
    userId: "u",
    billingTeamId: "u",
    ownerTeamId: "u",
    coderouterPoolId: null,
    status: "running" as const,
    provider: "freestyle" as const,
    providerVmId: "provider-vm",
    imageId: "snapshot",
    imageVersion: null,
    createdAt: new Date("2026-01-01T00:00:00Z"),
    displayName: null,
    slug: null,
    providerMetadata: {},
  };
  let persisted: unknown;
  const repo = {
    beginBaseOpen: () => Effect.succeed({
      kind: "existing" as const,
      base,
      generation,
      vm: existing,
    }),
    setResourceReservation: (input: { id: string; reservation: unknown }) => Effect.sync(() => {
      persisted = input;
      return true;
    }),
  } as unknown as VmRepositoryShape;
  const providers = {
    getStatus: () => Effect.succeed("running" as const),
    getStats: () => Effect.succeed({ memoryTotalMb: 16384, cpus: 8, diskTotalMb: 65536 }),
  } as unknown as VmProviderGatewayShape;
  const layer = Layer.mergeAll(
    Layer.succeed(VmRepository, repo),
    Layer.succeed(VmProviderGateway, providers),
    Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
  );

  await Effect.runPromise(openBaseVm({
    userId: "u",
    billingCustomerType: "user",
    billingTeamId: "u",
    billingPlanId: "pro",
    maxActiveVms: 5,
    provider: "freestyle",
    image: "snapshot",
    baseName: "default",
  }).pipe(Effect.provide(layer)));

  expect(persisted).toEqual({
    id: "vm",
    reservation: { memoryMb: 16384, vcpus: 8, diskMb: 65536 },
  });
});

test("an idempotent create retry cannot return a Max-sized row to Pro", async () => {
  const existing = {
    id: "vm",
    userId: "u",
    billingTeamId: "u",
    ownerTeamId: "u",
    coderouterPoolId: null,
    status: "running" as const,
    provider: "freestyle" as const,
    providerVmId: "provider-vm",
    imageId: "snapshot",
    imageVersion: null,
    createdAt: new Date("2026-01-01T00:00:00Z"),
    displayName: null,
    slug: null,
    providerMetadata: {
      cmuxResourceReservation: { memoryMb: 24576, vcpus: 12, diskMb: 98304 },
    },
  };
  const repo = {
    beginCreate: () => Effect.succeed({ inserted: false as const, vm: existing }),
    findNetwork: () => Effect.succeed({
      id: "network",
      userId: "u",
      provider: "freestyle" as const,
      providerNetworkId: "provider-network",
      slug: networkSlugForUser("u"),
      cidr: null,
      cidrV6: null,
      createdAt: new Date("2026-01-01T00:00:00Z"),
      updatedAt: new Date("2026-01-01T00:00:00Z"),
    }),
    upsertNetwork: () => Effect.die("the existing owner network should be reused"),
  } as unknown as VmRepositoryShape;
  const providers = {
    supportsPrivateNetworking: () => true,
    ensureNetwork: () => Effect.die("the existing owner network should be reused"),
  } as unknown as VmProviderGatewayShape;
  const layer = Layer.mergeAll(
    Layer.succeed(VmRepository, repo),
    Layer.succeed(VmProviderGateway, providers),
    Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
  );

  const result = await Effect.runPromiseExit(createVm({
    userId: "u",
    billingCustomerType: "user",
    billingTeamId: "u",
    billingPlanId: "pro",
    maxActiveVms: 5,
    provider: "freestyle",
    image: "snapshot",
    idempotencyKey: "retry",
  }).pipe(Effect.provide(layer)));

  expect(result._tag).toBe("Failure");
  if (result._tag === "Failure") {
    expect(vmWorkflowErrorFromCause(result.cause)?._tag).toBe("VmMemoryPlanError");
  }
});
