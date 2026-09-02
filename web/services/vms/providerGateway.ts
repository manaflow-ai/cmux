import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import {
  getProvider,
  type AttachEndpoint,
  type AttachOptions,
  type AttachTransport,
  type CreateOptions,
  type ExecOptions,
  type ExecResult,
  type CreateProviderTunnelOptions,
  type ProviderId,
  type ProviderNetwork,
  type ProviderTunnel,
  type RestoreOptions,
  type SnapshotRef,
  type SSHEndpoint,
  type VMHandle,
  type VMVolumeInventory,
  type VMVolumeListOptions,
  type VMStatus,
  type VMStats,
  type CmuxRemoteApprovalResult,
  type CmuxRemoteApprovalOptions,
  type CmuxRemoteAttachOptions,
  type CmuxRemoteEndpoint,
} from "./drivers";
import { VmOperationUnsupportedError, VmProviderOperationError } from "./errors";

export type VmProviderGatewayShape = {
  readonly create: (provider: ProviderId, options: CreateOptions) => Effect.Effect<VMHandle, VmProviderOperationError>;
  readonly destroy: (provider: ProviderId, vmId: string) => Effect.Effect<void, VmProviderOperationError>;
  /** Optional: delete a machine-owned persistent home volume after its machine is destroyed. */
  readonly deleteHomeVolume?: (
    provider: ProviderId,
    volumeName: string,
  ) => Effect.Effect<void, VmProviderOperationError>;
  /** Optional provider volume inventory used by the report-only VM reaper. */
  readonly listVolumes?: (
    provider: ProviderId,
    options?: VMVolumeListOptions,
  ) => Effect.Effect<VMVolumeInventory, VmProviderOperationError>;
  readonly getStatus?: (provider: ProviderId, vmId: string) => Effect.Effect<VMStatus, VmProviderOperationError>;
  readonly resume?: (provider: ProviderId, vmId: string) => Effect.Effect<VMHandle, VmProviderOperationError>;
  readonly pause?: (provider: ProviderId, vmId: string) => Effect.Effect<void, VmProviderOperationError>;
  readonly snapshot?: (
    provider: ProviderId,
    vmId: string,
    name?: string,
  ) => Effect.Effect<SnapshotRef, VmProviderOperationError>;
  readonly restore?: (
    provider: ProviderId,
    snapshotId: string,
    options?: RestoreOptions,
  ) => Effect.Effect<VMHandle, VmProviderOperationError>;
  readonly fork?: (provider: ProviderId, vmId: string) => Effect.Effect<VMHandle, VmProviderOperationError>;
  readonly exec: (
    provider: ProviderId,
    vmId: string,
    command: string,
    options?: ExecOptions,
  ) => Effect.Effect<ExecResult, VmProviderOperationError>;
  readonly openPort?: (
    provider: ProviderId,
    vmId: string,
    port: number,
  ) => Effect.Effect<{ url: string; token: string; openUrl: string; expiresAtMs?: number }, VmProviderOperationError>;
  readonly getStats?: (
    provider: ProviderId,
    vmId: string,
  ) => Effect.Effect<VMStats, VmProviderOperationError>;
  /** Session transports the provider serves; undefined = legacy websocket/ssh. */
  readonly attachTransports?: (provider: ProviderId) => readonly AttachTransport[] | undefined;
  readonly openAttach: (
    provider: ProviderId,
    vmId: string,
    options?: AttachOptions,
  ) => Effect.Effect<AttachEndpoint, VmProviderOperationError>;
  readonly openCmuxRemote?: (
    provider: ProviderId,
    vmId: string,
    options?: CmuxRemoteAttachOptions,
  ) => Effect.Effect<CmuxRemoteEndpoint, VmProviderOperationError>;
  readonly approveCmuxRemoteEnrollment?: (
    provider: ProviderId,
    vmId: string,
    invitationId: string,
    options?: CmuxRemoteApprovalOptions,
  ) => Effect.Effect<CmuxRemoteApprovalResult, VmProviderOperationError>;
  readonly openSSH: (provider: ProviderId, vmId: string) => Effect.Effect<SSHEndpoint, VmProviderOperationError>;
  readonly revokeSSHIdentity: (
    provider: ProviderId,
    identityHandle: string,
  ) => Effect.Effect<void, VmProviderOperationError>;
  readonly revokeEndpointLeases?: (
    provider: ProviderId,
    vmId: string,
  ) => Effect.Effect<void, VmProviderOperationError>;
  /**
   * Per-owner private networks and WireGuard tunnels. Optional as a group —
   * test doubles built before the feature simply omit them — and workflows
   * treat an absent member the same as a provider without the capability.
   */
  readonly supportsPrivateNetworking?: (provider: ProviderId) => boolean;
  readonly ensureNetwork?: (
    provider: ProviderId,
    options: { slug: string; displayName?: string },
  ) => Effect.Effect<ProviderNetwork, VmProviderOperationError>;
  readonly deleteNetwork?: (
    provider: ProviderId,
    networkId: string,
  ) => Effect.Effect<void, VmProviderOperationError>;
  readonly createTunnel?: (
    provider: ProviderId,
    options: CreateProviderTunnelOptions,
  ) => Effect.Effect<ProviderTunnel, VmProviderOperationError>;
  readonly getTunnel?: (
    provider: ProviderId,
    tunnelId: string,
    networkId: string,
  ) => Effect.Effect<ProviderTunnel | null, VmProviderOperationError>;
  readonly rotateTunnelKey?: (
    provider: ProviderId,
    tunnelId: string,
    clientPublicKey: string,
    networkId: string,
  ) => Effect.Effect<ProviderTunnel, VmProviderOperationError>;
  readonly deleteTunnel?: (
    provider: ProviderId,
    tunnelId: string,
  ) => Effect.Effect<void, VmProviderOperationError>;
};

export class VmProviderGateway extends Context.Tag("cmux/VmProviderGateway")<
  VmProviderGateway,
  VmProviderGatewayShape
>() {}

/**
 * The driver's private-networking half, or a typed unsupported failure. Callers
 * that can proceed without a network check `supportsPrivateNetworking` first;
 * reaching here on a provider without it is a programming error, not a
 * configuration one.
 */
function privateNetworking(provider: ProviderId) {
  const impl = getProvider(provider).privateNetworking;
  if (!impl) {
    throw new VmOperationUnsupportedError({ provider, operation: "privateNetworking" });
  }
  return impl;
}

function providerEffect<A>(
  provider: ProviderId,
  operation: string,
  run: () => Promise<A>,
): Effect.Effect<A, VmProviderOperationError> {
  return Effect.tryPromise({
    try: run,
    catch: (cause) => new VmProviderOperationError({ provider, operation, cause }),
  });
}

export const VmProviderGatewayLive = Layer.succeed(VmProviderGateway, {
  create: (provider, options) =>
    providerEffect(provider, "create", () => getProvider(provider).create(options)),
  destroy: (provider, vmId) =>
    providerEffect(provider, "destroy", () => getProvider(provider).destroy(vmId)),
  deleteHomeVolume: (provider, volumeName) =>
    providerEffect(provider, "deleteHomeVolume", async () => {
      const impl = getProvider(provider);
      // Providers without persistent volumes have nothing to delete.
      if (!impl.deleteHomeVolume) return;
      await impl.deleteHomeVolume(volumeName);
    }),
  listVolumes: (provider, options) =>
    providerEffect(provider, "listVolumes", async () => {
      const impl = getProvider(provider);
      // Providers without persistent volume support have no inventory to reap.
      if (!impl.listVolumes) return [];
      return await impl.listVolumes(options);
    }),
  getStatus: (provider, vmId) =>
    providerEffect(provider, "getStatus", async () => {
      const driver = getProvider(provider);
      if (!driver.getStatus) return "running" as const;
      return await driver.getStatus(vmId);
    }),
  resume: (provider, vmId) =>
    providerEffect(provider, "resume", () => getProvider(provider).resume(vmId)),
  pause: (provider, vmId) =>
    providerEffect(provider, "pause", () => getProvider(provider).pause(vmId)),
  snapshot: (provider, vmId, name) =>
    providerEffect(provider, "snapshot", () => getProvider(provider).snapshot(vmId, name)),
  restore: (provider, snapshotId, options) =>
    providerEffect(provider, "restore", () => getProvider(provider).restore(snapshotId, options)),
  fork: (provider, vmId) =>
    providerEffect(provider, "fork", async () => {
      const driver = getProvider(provider);
      if (!driver.fork) {
        throw new VmOperationUnsupportedError({ provider, operation: "fork" });
      }
      return await driver.fork(vmId);
    }),
  exec: (provider, vmId, command, options) =>
    providerEffect(provider, "exec", () => getProvider(provider).exec(vmId, command, options)),
  openPort: (provider, vmId, port) =>
    providerEffect(provider, "openPort", () => {
      const impl = getProvider(provider);
      if (!impl.openPort) {
        throw new Error(`provider ${provider} does not support opening ports`);
      }
      return impl.openPort(vmId, port);
    }),
  getStats: (provider, vmId) =>
    providerEffect(provider, "getStats", () => {
      const impl = getProvider(provider);
      if (!impl.getStats) {
        // Typed, so the route answers "unsupported" (non-retryable) instead of
        // a retryable 502 the activity panel would poll forever.
        throw new VmOperationUnsupportedError({ provider, operation: "getStats" });
      }
      return impl.getStats(vmId);
    }),
  attachTransports: (provider) => getProvider(provider).attachTransports,
  openAttach: (provider, vmId, options) =>
    providerEffect(provider, "openAttach", () => getProvider(provider).openAttach(vmId, options)),
  openCmuxRemote: (provider, vmId, options) =>
    providerEffect(provider, "openCmuxRemote", () => {
      const impl = getProvider(provider);
      if (!impl.openCmuxRemote) {
        throw new Error(`provider ${provider} does not run the cmux-tui remote daemon yet`);
      }
      return impl.openCmuxRemote(vmId, options);
    }),
  approveCmuxRemoteEnrollment: (provider, vmId, invitationId, options) =>
    providerEffect(provider, "approveCmuxRemoteEnrollment", () => {
      const impl = getProvider(provider);
      if (!impl.approveCmuxRemoteEnrollment) {
        throw new Error(`provider ${provider} does not run the cmux-tui remote daemon yet`);
      }
      return impl.approveCmuxRemoteEnrollment(vmId, invitationId, options);
    }),
  openSSH: (provider, vmId) =>
    providerEffect(provider, "openSSH", () => getProvider(provider).openSSH(vmId)),
  revokeSSHIdentity: (provider, identityHandle) =>
    providerEffect(provider, "revokeSSHIdentity", () =>
      getProvider(provider).revokeSSHIdentity(identityHandle)
    ),
  revokeEndpointLeases: (provider, vmId) => {
    const driver = getProvider(provider);
    if (!driver.revokeEndpointLeases) return Effect.void;
    return providerEffect(provider, "revokeEndpointLeases", () => driver.revokeEndpointLeases!(vmId));
  },
  supportsPrivateNetworking: (provider) => !!getProvider(provider).privateNetworking,
  ensureNetwork: (provider, options) =>
    providerEffect(provider, "ensureNetwork", () =>
      privateNetworking(provider).ensureNetwork(options)
    ),
  deleteNetwork: (provider, networkId) =>
    providerEffect(provider, "deleteNetwork", () =>
      privateNetworking(provider).deleteNetwork(networkId)
    ),
  createTunnel: (provider, options) =>
    providerEffect(provider, "createTunnel", () =>
      privateNetworking(provider).createTunnel(options)
    ),
  getTunnel: (provider, tunnelId, networkId) =>
    providerEffect(provider, "getTunnel", () =>
      privateNetworking(provider).getTunnel(tunnelId, networkId)
    ),
  rotateTunnelKey: (provider, tunnelId, clientPublicKey, networkId) =>
    providerEffect(provider, "rotateTunnelKey", () =>
      privateNetworking(provider).rotateTunnelKey(tunnelId, clientPublicKey, networkId)
    ),
  deleteTunnel: (provider, tunnelId) =>
    providerEffect(provider, "deleteTunnel", () =>
      privateNetworking(provider).deleteTunnel(tunnelId)
    ),
});
