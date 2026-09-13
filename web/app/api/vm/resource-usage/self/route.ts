import { Effect } from "effect";
import { VmRepository } from "@/services/vms/repository";
import { makeVmResourceUsageHandler } from "@/services/vms/resourceUsageIngest";
import { VM_RESOURCE_USAGE_KEY } from "@/services/vms/resourceUsage";
import { requireVmPrincipal } from "@/services/vms/vmPrincipal";
import { runVmWorkflow } from "@/services/vms/workflows";

export const POST = makeVmResourceUsageHandler({
  authenticate: requireVmPrincipal,
  now: Date.now,
  accept: (vm, usage, receivedAt) => runVmWorkflow(Effect.gen(function* () {
    const repo = yield* VmRepository;
    if (!repo.mergeProviderMetadata) return yield* Effect.dieMessage("VM metadata repository is unavailable");
    yield* repo.mergeProviderMetadata({
      id: vm.id,
      patch: { [VM_RESOURCE_USAGE_KEY]: { ...usage, receivedAt, providerVmId: vm.providerVmId } },
    });
  })),
});
