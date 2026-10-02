import { expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { VmRepository, type VmRepositoryShape } from "../services/vms/repository";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import { createVm, forkVm, restoreVm, resumeVm } from "../services/vms/workflows";
import { vmWorkflowErrorCause, VmProviderOperationError } from "../services/vms/errors";

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


test("Pro cannot bypass the memory gate with unknown snapshot or fork dimensions", async () => {
  const repo = {
    findUserVm: () => Effect.succeed({ id: "row", userId: "u", billingTeamId: "u", ownerTeamId: "u", coderouterPoolId: null, status: "running", provider: "freestyle", providerVmId: "vm", providerMetadata: {} }),
    hasOwnedSnapshot: () => Effect.succeed(true),
    ownedSnapshotResourceReservation: () => Effect.succeed(null),
  } as unknown as VmRepositoryShape;
  const layer = Layer.mergeAll(Layer.succeed(VmRepository, repo),
    Layer.succeed(VmProviderGateway, {} as VmProviderGatewayShape), Layer.succeed(VmBillingGateway, noOpVmBillingGateway()));
  const caller = { userId: "u", billingCustomerType: "user" as const, billingTeamId: "u", billingPlanId: "pro", maxActiveVms: 5 };
  for (const program of [
    forkVm({ ...caller, providerVmId: "vm" }).pipe(Effect.asVoid),
    restoreVm({ ...caller, provider: "freestyle", snapshotId: "snapshot" }).pipe(Effect.asVoid),
    createVm({ ...caller, provider: "freestyle", image: "snapshot", memoryMb: 16384,
      imageSize: { name: "xl", cpu: 8, memoryMb: 32768, storageMb: 131072 } }).pipe(Effect.asVoid),
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
  // A 24 GB machine made under the old Pro ceiling is locked on Pro.
  expect(await run("pro", { memoryMb: 24576, vcpus: 6, diskMb: 98304 })).toBe("VmMemoryPlanError");
  // CPU above the plan also locks an 8 GB machine.
  expect(await run("pro", { memoryMb: 8192, vcpus: 6, diskMb: 32768 })).toBe("VmMemoryPlanError");
  expect(await run("team", { memoryMb: 16384, vcpus: 4, diskMb: 65536 })).toBe("VmMemoryPlanError");
  // A 64 GB machine is above every plan, Max included.
  expect(await run("max", { memoryMb: 65536, vcpus: 16, diskMb: 131072 })).toBe("VmMemoryPlanError");
  // Machines inside the plan pass.
  expect(await run("pro", { memoryMb: 8192, vcpus: 4, diskMb: 32768 })).toBeNull();
  expect(await run("max", { memoryMb: 32768, vcpus: 16, diskMb: 131072 })).toBeNull();
});
