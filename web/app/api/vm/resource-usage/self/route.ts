import { Effect } from "effect";
import { VmRepository } from "@/services/vms/repository";
import { makeVmResourceUsageHandler } from "@/services/vms/resourceUsageIngest";
import { requireVmPrincipal } from "@/services/vms/vmPrincipal";
import { runVmWorkflow } from "@/services/vms/workflows";

export const POST = makeVmResourceUsageHandler({
  authenticate: requireVmPrincipal,
  now: Date.now,
  accept: (vm, usage, receivedAt) => runVmWorkflow(Effect.gen(function* () {
    const repo = yield* VmRepository;
    if (!repo.recordResourceUsage) return yield* Effect.dieMessage("VM resource repository is unavailable");
    yield* repo.recordResourceUsage({
      id: vm.id,
      providerVmId: vm.providerVmId,
      usage,
      receivedAt,
    });
  })),
});
