import type { AuthedUser } from "./auth";
import type { VmEntitlements } from "./entitlements";
import { persistentWorkspaceService, type PersistentWorkspaceService } from "./persistentWorkspace";

/**
 * Compose the real Freestyle workspace lifecycle for one authenticated request.
 * The heavy provider/workflow modules load only when no test or alternate
 * composition has already been installed.
 */
export async function persistentWorkspaceServiceForRequest(input: {
  readonly user: AuthedUser;
  readonly entitlements: VmEntitlements;
}): Promise<PersistentWorkspaceService> {
  const configured = persistentWorkspaceService();
  if (configured) return configured;

  const [drivers, images, modelPlane, adapterModule, lifecycle, storeModule, workflows, routeHelpers, Effect] = await Promise.all([
    import("./drivers"),
    import("./images/resolver"),
    import("./modelPlaneGateway"),
    import("./cloudVmRunAdapter"),
    import("./persistentWorkspace"),
    import("./runtimeWorkspaceStore"),
    import("./workflows"),
    import("./routeHelpers"),
    import("effect/Effect"),
  ]);
  const provider = drivers.defaultProviderId();
  const runAdapter = new adapterModule.CloudVmRunAdapter(drivers.getProvider(provider));
  const { user, entitlements } = input;

  return lifecycle.createPersistentWorkspaceService({
    store: storeModule.persistentWorkspaceStoreFromRuntime(),
    provider: lifecycle.persistentWorkspaceProviderFromCloudVm({
      provisionVm: async (request) => {
        const providerInput = request.providerInput;
        const selected = images.resolveVmImage(provider, providerInput?.image, process.env, {
          kind: "base",
          memoryMb: providerInput?.memoryMb,
          callerUserId: user.id,
        });
        const vm = await workflows.runVmWorkflow(workflows.createVm({
          userId: user.id,
          billingCustomerType: entitlements.billingCustomerType,
          billingTeamId: entitlements.billingTeamId,
          billingPlanId: entitlements.planId,
          maxActiveVms: entitlements.maxActiveVms,
          provider,
          image: selected.image,
          imageVersion: providerInput?.imageVersion ?? selected.imageVersion,
          imageSize: selected.size ?? undefined,
          perMachineHome: true,
          displayName: request.workspaceName,
          idempotencyKey: request.workspaceKey,
          modelPlane: modelPlane.vmModelPlaneGatewayFor({ teamId: entitlements.billingTeamId, stackUserId: user.id }),
          origin: "create",
          // The guest vm-kind write runs after the request's answer, kept alive by the platform.
          deferAfterResponse: (work) => routeHelpers.runAfterResponse(() => Effect.runPromise(work)),
        }));
        return { providerVmId: vm.providerVmId };
      },
      vm: {
        resume: async (providerVmId) => {
          await workflows.runVmWorkflow(workflows.resumeVm({
            userId: user.id,
            billingTeamId: entitlements.billingTeamId,
            teamIds: [entitlements.billingTeamId],
            providerVmId,
            maxActiveVms: entitlements.maxActiveVms,
            callerPlanId: entitlements.planId,
            modelPlane: modelPlane.vmModelPlaneGatewayFor({ teamId: entitlements.billingTeamId, stackUserId: user.id }),
          }));
        },
        pause: async (providerVmId) => {
          await workflows.runVmWorkflow(workflows.pauseVm({
            userId: user.id,
            billingTeamId: entitlements.billingTeamId,
            teamIds: [entitlements.billingTeamId],
            providerVmId,
          }));
        },
      },
      runAdapter,
      attach: async (record) => ({
        provider: record.provider,
        vmId: record.providerVmId,
        workspaceId: record.providerWorkspaceId,
        terminalId: record.providerTerminalId,
        sessionId: record.providerTerminalId ? `session_${record.providerTerminalId}` : undefined,
      }),
    }),
  });
}

/** Destroy a stopped persistent workspace through the normal VM cleanup path. */
export async function destroyPersistentWorkspaceVm(input: {
  readonly user: AuthedUser;
  readonly entitlements: VmEntitlements;
  readonly providerVmId: string;
}): Promise<void> {
  const [modelPlane, workflows] = await Promise.all([
    import("./modelPlaneGateway"),
    import("./workflows"),
  ]);
  await workflows.runVmWorkflow(workflows.destroyVm({
    userId: input.user.id,
    billingTeamId: input.entitlements.billingTeamId,
    teamIds: [input.entitlements.billingTeamId],
    providerVmId: input.providerVmId,
    modelPlane: modelPlane.vmModelPlaneRevoker(),
    source: "user_request",
  }));
}
