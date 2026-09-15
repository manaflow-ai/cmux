import { describe, expect, test } from "bun:test";
import * as Effect from "effect/Effect";
import * as Exit from "effect/Exit";
import * as Cause from "effect/Cause";
import * as Layer from "effect/Layer";

import { VmBillingGateway, noOpVmBillingGateway } from "../services/vms/billingGateway";
import { VmDatabaseError, VmOperationUnsupportedError, VmProviderOperationError } from "../services/vms/errors";
import {
  VmProviderGateway,
  type VmProviderGatewayShape,
} from "../services/vms/providerGateway";
import { vmCapabilitiesFor } from "../services/vms/drivers";
import { VmRepository, type VmRepositoryShape } from "../services/vms/repository";
import { forkVm } from "../services/vms/workflows";

// The live gateway always defines `fork` and answers "unsupported" from inside
// it when the driver has no native fork. forkVm used the presence of that
// function as "the provider forks natively", so on Freestyle (snapshot and
// create, no fork call) every fork failed with vm_operation_unsupported while
// the snapshot-based path a few lines below was unreachable.
describe("forkVm provider capability", () => {
  test("the live gateway reports no native fork for freestyle", () => {
    expect(vmCapabilitiesFor("freestyle").fork).toBe(false);
  });

  test("a provider without native fork takes the snapshot path, never the fork call", async () => {
    const source = {
      id: "00000000-0000-4000-8000-0000000000f0",
      userId: "user-fork-capability",
      billingTeamId: "team-fork-capability",
      billingPlanId: "pro",
      provider: "freestyle" as const,
      providerVmId: "provider-vm-fork-source",
      imageId: "sh-source",
      imageVersion: null,
      status: "running" as const,
      providerMetadata: {},
    };
    const repo = {
      findUserVm: () => Effect.succeed(source),
      findUserVmAnyStatus: () => Effect.succeed(source),
      recordUsageEvent: () => Effect.void,
      markProviderObservedStatus: () => Effect.succeed(true),
      // The native path inserts the copy row before calling the provider; a
      // typed failure here names that path when the decision is wrong.
      beginCreate: () =>
        Effect.fail(new VmDatabaseError({ operation: "beginCreate", cause: new Error("native fork path reached") })),
    } as unknown as VmRepositoryShape;
    const calls: string[] = [];
    const provider = {
      capabilities: () => ({ snapshot: true, restore: true, fork: false, ports: false }),
      getStatus: () => Effect.succeed("running" as const),
      resume: () => Effect.fail(new Error("unused") as never),
      // Mirrors VmProviderGatewayLive: the function exists, the driver does not.
      fork: (providerId: "freestyle", _vmId: string) =>
        Effect.sync(() => { void _vmId; calls.push("fork"); }).pipe(
          Effect.flatMap(() =>
            Effect.fail(new VmProviderOperationError({
              provider: providerId,
              operation: "fork",
              cause: new VmOperationUnsupportedError({ provider: providerId, operation: "fork" }),
            }))
          ),
        ),
      snapshot: (providerId: "freestyle") =>
        Effect.sync(() => calls.push("snapshot")).pipe(
          Effect.flatMap(() =>
            Effect.fail(new VmProviderOperationError({
              provider: providerId,
              operation: "snapshot",
              cause: new Error("snapshot path reached"),
            }))
          ),
        ),
      create: () => Effect.fail(new Error("unused") as never),
      destroy: () => Effect.void,
      exec: () => Effect.fail(new Error("unused") as never),
      openAttach: () => Effect.fail(new Error("unused") as never),
      openSSH: () => Effect.fail(new Error("unused") as never),
      revokeSSHIdentity: () => Effect.void,
    } as unknown as VmProviderGatewayShape;
    const layer = Layer.mergeAll(
      Layer.succeed(VmRepository, repo),
      Layer.succeed(VmProviderGateway, provider),
      Layer.succeed(VmBillingGateway, noOpVmBillingGateway()),
    );

    const exit = await Effect.runPromiseExit(
      forkVm({
        userId: source.userId,
        billingCustomerType: "team",
        billingTeamId: source.billingTeamId,
        teamIds: [source.billingTeamId],
        billingPlanId: "pro",
        maxActiveVms: 50,
        providerVmId: source.providerVmId,
      }).pipe(Effect.provide(layer)),
    );

    expect(Exit.isFailure(exit)).toBe(true);
    if (!Exit.isFailure(exit)) return;
    const failure = Cause.failureOption(exit.cause);
    expect(failure._tag).toBe("Some");
    if (failure._tag !== "Some") return;
    expect(`${failure.value._tag}:${(failure.value as { operation?: string }).operation}`)
      .toBe("VmProviderOperationError:snapshot");
    expect(calls).toEqual(["snapshot"]);
  });
});
