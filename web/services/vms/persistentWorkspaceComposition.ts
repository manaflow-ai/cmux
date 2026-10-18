import { CloudVmRunAdapter } from "./cloudVmRunAdapter";
import { createAgentBrokerLifecycleEffectBroker } from "./lifecycleEffectBroker";
import {
  createConfiguredHostLeaseAdaptersFromEnv,
  VmHostLeaseTransport,
  type VmHostLeaseProvider,
} from "./hostLeaseTransport";
import { DrizzleVmHostLeaseStore } from "./hostLeaseStore";
import {
  createPersistentWorkspaceService,
  persistentWorkspaceService,
  persistentWorkspaceProviderFromCloudVm,
  type PersistentWorkspaceService,
} from "./persistentWorkspace";
import { persistentWorkspaceStoreFromRuntime } from "./runtimeWorkspaceStore";
import { defaultProviderId, getProvider, type ProviderId } from "./drivers";
import { resolveVmImage } from "./images/resolver";
import { createVm, runVmWorkflow } from "./workflows";
import type { VmEntitlements } from "./entitlements";
import type { AuthedUser } from "./auth";
import { vmModelPlaneGatewayFor } from "./modelPlaneGateway";

export type PersistentWorkspaceCompositionInput = {
  readonly user: AuthedUser;
  readonly entitlements: VmEntitlements;
  readonly provider?: ProviderId;
  readonly env?: Readonly<Record<string, string | undefined>>;
};

/**
 * Production composition for the persistent workspace routes. This factory
 * deliberately receives the already-resolved user and VM entitlements from
 * the route, so provisioning still goes through the normal VM admission and
 * billing workflow instead of inventing a second create path.
 */
export function createConfiguredPersistentWorkspaceService(
  input: PersistentWorkspaceCompositionInput,
): PersistentWorkspaceService {
  const providerId = input.provider ?? defaultProviderId();
  const provider = getProvider(providerId);
  const env = input.env ?? process.env;
  const hostAdapters = createConfiguredHostLeaseAdaptersFromEnv(env);
  const hostLeaseProvider = providerId as VmHostLeaseProvider;
  if (!hostAdapters.has(hostLeaseProvider)) {
    throw new Error(`persistent workspace host lease adapter is not configured for ${hostLeaseProvider}`);
  }
  const hostLeaseTransport = new VmHostLeaseTransport(new DrizzleVmHostLeaseStore(), hostAdapters);
  const effectBroker = createAgentBrokerLifecycleEffectBroker({
    workerId: env.CMUX_BROKER_WORKER_ID?.trim() || `web-lifecycle:${input.user.id}`,
    sourceSha: env.VERCEL_GIT_COMMIT_SHA?.trim() || "web-runtime",
    scopeRevision: () => env.VERCEL_GIT_COMMIT_SHA?.trim() || "runtime",
    leaseTtlMs: Number(env.CMUX_BROKER_LEASE_TTL_MS) || undefined,
  });
  const image = resolveVmImage(providerId, undefined, env, { kind: "base" });
  const runAdapter = new CloudVmRunAdapter(provider);

  const workspaceProvider = persistentWorkspaceProviderFromCloudVm({
    provisionVm: async (request) => {
      const vm = await runVmWorkflow(createVm({
        userId: input.user.id,
        billingCustomerType: input.entitlements.billingCustomerType,
        billingTeamId: input.entitlements.billingTeamId,
        billingPlanId: input.entitlements.planId,
        maxActiveVms: input.entitlements.maxActiveVms,
        provider: providerId,
        image: image.image,
        imageVersion: image.imageVersion,
        imageSize: image.size ?? undefined,
        displayName: request.workspaceName,
        perMachineHome: true,
        idempotencyKey: request.effectKey,
        modelPlane: vmModelPlaneGatewayFor({
          teamId: input.entitlements.billingTeamId,
          stackUserId: input.user.id,
        }),
        origin: "create",
      }));
      return { providerVmId: vm.providerVmId };
    },
    vm: {
      resume: async (vmId) => { await provider.resume(vmId); },
      pause: async (vmId) => { await provider.pause(vmId); },
    },
    runAdapter,
    hostLeaseTransport,
    effectBroker,
    hostLeaseProvider,
    hostLeaseTtlMs: Number(env.CMUX_BROKER_LEASE_TTL_MS) || undefined,
    attach: async (record) => {
      if (!provider.openCmuxRemote) throw new Error(`${providerId} does not support cmux remote attach`);
      return provider.openCmuxRemote(record.providerVmId!);
    },
  });

  return createPersistentWorkspaceService({
    store: persistentWorkspaceStoreFromRuntime(),
    provider: workspaceProvider,
  });
}

/** Use an explicitly installed test/host override, otherwise compose the live service. */
export function persistentWorkspaceServiceForRequest(
  input: PersistentWorkspaceCompositionInput,
): PersistentWorkspaceService {
  return persistentWorkspaceService() ?? createConfiguredPersistentWorkspaceService(input);
}
