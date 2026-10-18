import { randomUUID } from "node:crypto";
import { DrizzlePersistentWorkspaceStore } from "../runtimeComposition";
import { createAgentBrokerLifecycleEffectBroker } from "./lifecycleEffectBroker";
import { DrizzleVmHostLeaseStore } from "./hostLeaseStore";
import { createHugeBlueHostLeaseAdapter, VmHostLeaseTransport } from "./hostLeaseTransport";
import { createPersistentWorkspaceService, persistentWorkspaceProviderFromCloudVm, type PersistentWorkspaceService } from "./persistentWorkspace";
import { CloudVmRunAdapter } from "./cloudVmRunAdapter";
import { HugeBlueProvider } from "./drivers/hugeBlue";
import type { AuthedUser } from "./auth";
import { createSshHostLeaseClient } from "./sshHostLeaseClient";

export function createConfiguredPersistentWorkspaceService(input: {
  readonly user: Pick<AuthedUser, "id" | "billingTeamId">;
  readonly provider: "huge-blue";
  readonly entitlements: Record<string, unknown>;
}): PersistentWorkspaceService {
  if (!process.env.HUGE_BLUE_SSH_HOST) throw new Error("HUGE_BLUE_SSH_HOST is required for staging composition");
  const provider = new HugeBlueProvider();
  const leaseClient = createSshHostLeaseClient(process.env.HUGE_BLUE_SSH_HOST, {
    user: process.env.HUGE_BLUE_SSH_USER,
    identityFile: process.env.HUGE_BLUE_SSH_KEY,
    proxyCommand: process.env.HUGE_BLUE_SSH_PROXY_COMMAND,
  });
  const hostLeaseTransport = new VmHostLeaseTransport(new DrizzleVmHostLeaseStore(), new Map([
    ["huge-blue", createHugeBlueHostLeaseAdapter(leaseClient)],
  ]));
  const effectBroker = createAgentBrokerLifecycleEffectBroker({
    workerId: process.env.CMUX_BROKER_WORKER_ID ?? "staging-api",
    sourceSha: process.env.CMUX_SOURCE_SHA ?? "staging",
    scopeRevision: process.env.CMUX_STAGING_BRANCH ?? "staging",
    leaseTtlMs: Number(process.env.CMUX_BROKER_LEASE_TTL_MS ?? 30_000),
  });
  const runAdapter = new CloudVmRunAdapter(provider);
  const workspaceProvider = persistentWorkspaceProviderFromCloudVm({
    providerId: input.provider,
    hostLeaseProvider: input.provider,
    hostLeaseTransport,
    effectBroker,
    runAdapter,
    hostLeaseTtlMs: Number(process.env.CMUX_BROKER_LEASE_TTL_MS ?? 30_000),
    provisionVm: async (request) => {
      const vm = await provider.create({
        image: request.providerInput?.image ?? process.env.HUGE_BLUE_VM_IMAGE ?? "huge-blue-host",
        displayName: request.workspaceName,
      });
      return { providerVmId: vm.providerVmId };
    },
    vm: {
      resume: async (providerVmId) => { await provider.resume(providerVmId); },
      pause: async (providerVmId) => { await provider.pause(providerVmId); },
    },
    attach: async ({ record, scope }) => ({
      ...(await provider.openCmuxRemote(record.providerVmId ?? process.env.HUGE_BLUE_VM_ID ?? "huge-blue-staging", { workspaceScope: scope })),
      providerWorkspaceId: record.providerWorkspaceId,
      providerTerminalId: record.providerTerminalId,
    }),
  });
  return createPersistentWorkspaceService({
    store: new DrizzlePersistentWorkspaceStore(),
    provider: workspaceProvider,
    identity: () => ({ runtimeId: randomUUID(), workspaceId: randomUUID() }),
  });
}
