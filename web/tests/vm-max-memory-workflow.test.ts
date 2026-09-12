import { expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { VmRepository, type VmRepositoryShape } from "../services/vms/repository";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import { createVm, forkVm, restoreVm } from "../services/vms/workflows";
import { vmWorkflowErrorCause, VmProviderOperationError } from "../services/vms/errors";

test("create, fork, and restore reject a 64 GB machine on Pro before provisioning", async () => {
  let creates = 0;
  const reservation = { memoryMb: 65536, vcpus: 16, diskMb: 131072 };
  const repo = {
    findUserVm: () => Effect.succeed({ id: "row", userId: "user", billingTeamId: "team", status: "running", provider: "freestyle", providerVmId: "vm", providerMetadata: { cmuxResourceReservation: reservation } }),
    hasOwnedSnapshot: () => Effect.succeed(true),
    ownedSnapshotResourceReservation: () => Effect.succeed(reservation),
    beginCreate: () => Effect.sync(() => { creates++; throw new Error("must not create"); }),
  } as unknown as VmRepositoryShape;
  const providers = { getStats: () => Effect.succeed({ memoryTotalMb: 65536, cpus: 16, diskTotalMb: 131072 }) } as unknown as VmProviderGatewayShape;
  const layer = Layer.mergeAll(Layer.succeed(VmRepository, repo), Layer.succeed(VmProviderGateway, providers), Layer.succeed(VmBillingGateway, noOpVmBillingGateway()));
  const caller = { userId: "user", billingCustomerType: "team" as const, billingTeamId: "team", billingPlanId: "pro", maxActiveVms: 50 };
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
    findUserVm: () => Effect.succeed({ id: "row", userId: "u", billingTeamId: "u", status: "running", provider: "freestyle",
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
    maxActiveVms: 50, providerVmId: "vm" }).pipe(Effect.provide(layer)));
  expect(snapshots).toBe(1);
  expect(forks).toBe(0);
  expect(creates).toBe(0);
});
