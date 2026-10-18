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
  PersistentWorkspaceNotFoundError,
  PersistentWorkspaceOwnershipError,
} from "./persistentWorkspace";
import { persistentWorkspaceStoreFromRuntime } from "./runtimeWorkspaceStore";
import { defaultProviderId, getProvider, HugeBlueProvider, type ProviderId } from "./drivers";
import { resolveVmImage } from "./images/resolver";
import type { VmEntitlements } from "./entitlements";
import type { AuthedUser } from "./auth";

export type PersistentWorkspaceCompositionInput = {
  readonly user: AuthedUser;
  readonly entitlements: VmEntitlements;
  readonly provider?: ProviderId;
  readonly env?: Readonly<Record<string, string | undefined>>;
  readonly runtimeId?: string;
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
  const env = input.env ?? process.env;
  const provider = providerId === "huge-blue" ? new HugeBlueProvider({ env }) : getProvider(providerId);
  if (providerId === "huge-blue" && (env.CMUX_VM_HUGE_BLUE_ENABLED !== "1"
    || !(env.HUGE_BLUE_ALLOWED_OWNER_IDS ?? "").split(",").map((id) => id.trim()).includes(input.user.id))) {
    throw new Error("Huge Blue shared-host workspaces require explicit internal-owner admission");
  }
  const hostAdapters = createConfiguredHostLeaseAdaptersFromEnv(env);
  const hostLeaseProvider = providerId as VmHostLeaseProvider;
  if (!hostAdapters.has(hostLeaseProvider)) {
    throw new Error(`persistent workspace host lease adapter is not configured for ${hostLeaseProvider}`);
  }
  const hostLeaseTransport = new VmHostLeaseTransport(new DrizzleVmHostLeaseStore(), hostAdapters);
  const effectBroker = createAgentBrokerLifecycleEffectBroker({
    workerId: env.CMUX_BROKER_WORKER_ID?.trim() || `web-lifecycle:${input.user.id}`,
    sourceSha: env.CMUX_SOURCE_SHA?.trim() || env.VERCEL_GIT_COMMIT_SHA?.trim() || "web-runtime",
    scopeRevision: () => env.VERCEL_GIT_COMMIT_SHA?.trim() || "runtime",
    leaseTtlMs: Number(env.CMUX_BROKER_LEASE_TTL_MS) || undefined,
  });
  // Shared-host placement has no image allocation; Freestyle keeps normal VM admission.
  const image = providerId === "huge-blue" ? null : resolveVmImage(providerId, undefined, env, { kind: "base" });
  const runAdapter = new CloudVmRunAdapter(provider);

  const workspaceProvider = persistentWorkspaceProviderFromCloudVm({
    provisionVm: async (request) => {
      // Internal shared-host placement allocates a daemon workspace, not a paid VM.
      if (providerId === "huge-blue") return provider.create({ image: "shared-host" });
      const { createVm, runVmWorkflow } = await import("./workflows");
      const { vmModelPlaneGatewayFor } = await import("./modelPlaneGateway");
      const vm = await runVmWorkflow(createVm({
        userId: input.user.id,
        billingCustomerType: input.entitlements.billingCustomerType,
        billingTeamId: input.entitlements.billingTeamId,
        billingPlanId: input.entitlements.planId,
        maxActiveVms: input.entitlements.maxActiveVms,
        provider: providerId,
        image: image!.image,
        imageVersion: image!.imageVersion,
        imageSize: image!.size ?? undefined,
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
    scopedAttach: providerId === "huge-blue",
    attach: async (record) => {
      if (!provider.openCmuxRemote) throw new Error(`${providerId} does not support cmux remote attach`);
      const endpoint = await provider.openCmuxRemote(record.providerVmId!, { workspaceScope: { runtimeId: record.runtimeId, ownerId: record.ownerId, tenantId: record.tenantId } });
      return { ...endpoint, providerWorkspaceId: record.providerWorkspaceId };
    },
  });

  return createPersistentWorkspaceService({
    providerId,
    store: persistentWorkspaceStoreFromRuntime(),
    provider: workspaceProvider,
  });
}

/** Use an explicitly installed test/host override, otherwise compose the live service. */
export async function persistentWorkspaceServiceForRequest(
  input: PersistentWorkspaceCompositionInput,
): Promise<PersistentWorkspaceService> {
  const configured = persistentWorkspaceService();
  if (configured) return configured;
  if (input.runtimeId) {
    const record = await persistentWorkspaceStoreFromRuntime().getRuntime({ runtimeId: input.runtimeId });
    if (!record) throw new PersistentWorkspaceNotFoundError(input.runtimeId);
    if (record.ownerId !== input.user.id || record.tenantId !== input.entitlements.billingTeamId) {
      throw new PersistentWorkspaceOwnershipError();
    }
    return createConfiguredPersistentWorkspaceService({ ...input, provider: record.provider });
  }
  return createConfiguredPersistentWorkspaceService(input);
}
