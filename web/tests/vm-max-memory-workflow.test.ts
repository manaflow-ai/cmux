import { expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { VmRepository, type VmRepositoryShape } from "../services/vms/repository";
import { VmProviderGateway, type VmProviderGatewayShape } from "../services/vms/providerGateway";
import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import { createVm, forkVm, restoreVm } from "../services/vms/workflows";
import { vmWorkflowErrorCause } from "../services/vms/errors";

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
    createVm({ ...caller, provider: "freestyle", image: "snapshot", memoryMb: 65536 }),
    forkVm({ ...caller, teamIds: ["team"], providerVmId: "vm" }),
    restoreVm({ ...caller, provider: "freestyle", snapshotId: "snapshot" }),
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
