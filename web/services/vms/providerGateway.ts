import type { NetworkRulePlan } from "./networkPolicy";
import type { ProviderTlsRuleInventory, ProviderVmInventory, VmControlProbe } from "./health/types";
import * as Context from "effect/Context";
import * as Clock from "effect/Clock";
import * as Effect from "effect/Effect";
import * as FiberRef from "effect/FiberRef";
import * as Layer from "effect/Layer";
import {
  getProvider,
  type AttachEndpoint,
  type AttachOptions,
  type AttachTransport,
  type CreateOptions,
  type ExecOptions,
  type ExecResult,
  type VMFileContents,
  type VMFileEntry,
  type VMFileStat,
  type CreateProviderTunnelOptions,
  type ProviderId,
  type ProviderCredential,
  type ProviderNetwork,
  type ProviderTunnel,
  type ProviderTunnelAttachment,
  type ProviderTunnelCreateResult,
  type VMFirewallRule,
  type VMFirewallRuleInput,
  type RestoreOptions,
  type SnapshotRef,
  type SSHEndpoint,
  type SCPEndpoint,
  type VMHandle,
  type VMVolumeInventory,
  type VMVolumeListOptions,
  type VMStatus,
  type VmPauseState,
  type VMStats,
  type VMResourceStatsResult,
  type VMResizeOptions,
  type CmuxRemoteApprovalResult,
  type CmuxRemoteApprovalOptions,
  type CmuxRemoteAttachOptions,
  type CmuxRemoteEndpoint,
  type VmCapabilities,
  type EnsureProviderNetworkOptions,
  vmCapabilitiesFor,
} from "./drivers";
import { VM_PROVIDER_CREATE_TIMEOUT_MS } from "./operationTimeouts";
import { VmOperationUnsupportedError, VmProviderOperationError } from "./errors";
import { VmProviderReadDeadline } from "./routeDeadline";
import { ProviderReadDeadlineError, type ProviderReadOptions } from "./drivers/types";

export type VmProviderGatewayShape = {
  readonly create: (provider: ProviderId, options: CreateOptions) => Effect.Effect<VMHandle, VmProviderOperationError>;
  readonly destroy: (provider: ProviderId, vmId: string, credential?: ProviderCredential) => Effect.Effect<void, VmProviderOperationError>;
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
  /** Account-wide VM inventory for the read-only staff health sweep. */
  readonly listAccountVms?: (
    provider: ProviderId,
    options: { readonly deadlineAtMs: number },
  ) => Effect.Effect<ProviderVmInventory, VmProviderOperationError>;
  /** Account-wide TLS rules, reduced to attribution ids, for the health sweep. */
  readonly listAccountTlsRules?: (
    provider: ProviderId,
    options: { readonly deadlineAtMs: number },
  ) => Effect.Effect<ProviderTlsRuleInventory, VmProviderOperationError>;
  /** One bounded control-path probe of a running VM; never fails, a failure is an outcome. */
  readonly probeVmControl?: (
    provider: ProviderId,
    vmId: string,
    options: { readonly timeoutMs: number },
  ) => Effect.Effect<VmControlProbe, VmProviderOperationError>;
  readonly getStatus?: (provider: ProviderId, vmId: string, credential?: ProviderCredential) => Effect.Effect<VMStatus, VmProviderOperationError>;
  readonly getPauseState?: (provider: ProviderId, vmId: string, credential?: ProviderCredential) => Effect.Effect<VmPauseState | null, VmProviderOperationError>;
  readonly resume?: (provider: ProviderId, vmId: string, credential?: ProviderCredential) => Effect.Effect<VMHandle, VmProviderOperationError>;
  readonly pause?: (provider: ProviderId, vmId: string, credential?: ProviderCredential) => Effect.Effect<void, VmProviderOperationError>;
  readonly setRuntimeBudget?: (provider: ProviderId, vmId: string, remainingSeconds: number | null) => Effect.Effect<void, VmProviderOperationError>;
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
  /** Every snapshot taken from the machine, newest first (`cmux vm snapshot ls`). */
  readonly listSnapshots?: (
    provider: ProviderId,
    vmId: string,
  ) => Effect.Effect<SnapshotRef[], VmProviderOperationError>;
  /** Delete one snapshot taken from the machine (`cmux vm snapshot rm`). */
  readonly deleteSnapshot?: (
    provider: ProviderId,
    vmId: string,
    snapshotId: string,
  ) => Effect.Effect<void, VmProviderOperationError>;
  readonly fork?: (provider: ProviderId, vmId: string) => Effect.Effect<VMHandle, VmProviderOperationError>;
  /** Driver capabilities. Optional for compatibility with older test doubles. */
  readonly capabilities?: (provider: ProviderId) => VmCapabilities;
  readonly exec: (
    provider: ProviderId,
    vmId: string,
    command: string,
    options?: ExecOptions,
  ) => Effect.Effect<ExecResult, VmProviderOperationError>;
  readonly listFiles?: (provider: ProviderId, vmId: string, path: string) => Effect.Effect<VMFileEntry[], VmProviderOperationError>;
  readonly readFile?: (provider: ProviderId, vmId: string, path: string) => Effect.Effect<VMFileContents, VmProviderOperationError>;
  readonly writeFile?: (provider: ProviderId, vmId: string, path: string, data: Uint8Array, mode?: number) => Effect.Effect<void, VmProviderOperationError>;
  readonly makeDirectory?: (provider: ProviderId, vmId: string, path: string) => Effect.Effect<void, VmProviderOperationError>;
  readonly removeFile?: (provider: ProviderId, vmId: string, path: string) => Effect.Effect<void, VmProviderOperationError>;
  readonly statFile?: (provider: ProviderId, vmId: string, path: string) => Effect.Effect<VMFileStat, VmProviderOperationError>;
  readonly openPort?: (
    provider: ProviderId,
    vmId: string,
    port: number,
  ) => Effect.Effect<{ url: string; token: string; openUrl: string; expiresAtMs?: number }, VmProviderOperationError>;
  readonly getStats?: (
    provider: ProviderId,
    vmId: string,
  ) => Effect.Effect<VMStats, VmProviderOperationError>;
  readonly getResourceStats?: (
    provider: ProviderId,
    vmId: string,
  ) => Effect.Effect<VMResourceStatsResult | null, VmProviderOperationError>;
  /** Force a provider-level reboot; unlike resume this does not probe the guest first. */
  readonly restart?: (provider: ProviderId, vmId: string) => Effect.Effect<void, VmProviderOperationError | VmOperationUnsupportedError>;
  readonly resize?: (
    provider: ProviderId,
    vmId: string,
    options: VMResizeOptions,
  ) => Effect.Effect<void, VmProviderOperationError | VmOperationUnsupportedError>;
  readonly applyNetworkPolicy?: (
    provider: ProviderId,
    vmId: string,
    plan: NetworkRulePlan,
  ) => Effect.Effect<void, VmProviderOperationError | VmOperationUnsupportedError>;
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
  readonly prepareSCP?: (provider: ProviderId, vmId: string, publicKey: string) => Effect.Effect<SCPEndpoint, VmProviderOperationError>;
  readonly openSSH: (provider: ProviderId, vmId: string, credential?: ProviderCredential) => Effect.Effect<SSHEndpoint, VmProviderOperationError>;
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
    options: EnsureProviderNetworkOptions,
  ) => Effect.Effect<ProviderNetwork, VmProviderOperationError>;
  /** Read a provider network by id or slug without creating or repairing it. */
  readonly getNetwork?: (
    provider: ProviderId,
    networkIdOrSlug: string,
  ) => Effect.Effect<ProviderNetwork | null, VmProviderOperationError>;
  readonly deleteNetwork?: (
    provider: ProviderId,
    networkId: string,
  ) => Effect.Effect<void, VmProviderOperationError>;
  readonly createTunnel?: (
    provider: ProviderId,
    options: CreateProviderTunnelOptions,
  ) => Effect.Effect<ProviderTunnelCreateResult, VmProviderOperationError>;
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
  readonly attachTunnelNetwork?: (provider: ProviderId, tunnelId: string, networkId: string) => Effect.Effect<ProviderTunnelAttachment, VmProviderOperationError>;
  readonly detachTunnelNetwork?: (provider: ProviderId, tunnelId: string, networkId: string) => Effect.Effect<void, VmProviderOperationError>;
  readonly listNetworkTunnelIds?: (provider: ProviderId, networkId: string) => Effect.Effect<string[], VmProviderOperationError>;
  readonly listFirewallRules?: (provider: ProviderId, options?: { vmId?: string; vpcId?: string; tunnelId?: string }) => Effect.Effect<VMFirewallRule[], VmProviderOperationError>;
  readonly getFirewallRule?: (provider: ProviderId, ruleId: string) => Effect.Effect<VMFirewallRule, VmProviderOperationError>;
  readonly createFirewallRule?: (provider: ProviderId, options: VMFirewallRuleInput) => Effect.Effect<VMFirewallRule, VmProviderOperationError>;
  readonly deleteFirewallRule?: (provider: ProviderId, ruleId: string) => Effect.Effect<void, VmProviderOperationError>;
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

/** The driver's health inventory, or a typed unsupported failure. */
function healthInventory(provider: ProviderId) {
  const impl = getProvider(provider).healthInventory;
  if (!impl) {
    throw new VmOperationUnsupportedError({ provider, operation: "healthInventory" });
  }
  return impl;
}

/**
 * A provider read a route may bound (routeDeadline.ts). Outside a bounded
 * route it is a plain provider call. Inside one, it gets the time left
 * before the route's answer; at that point the call is interrupted, which
 * aborts the signal the driver passed to every request, and the read fails
 * with ProviderReadDeadlineError (504 vm_provider_timeout).
 */
function boundedProviderRead<A>(
  provider: ProviderId,
  operation: string,
  run: (options: ProviderReadOptions) => Promise<A>,
): Effect.Effect<A, VmProviderOperationError> {
  return Effect.flatMap(FiberRef.get(VmProviderReadDeadline), (deadlineAtMs) => {
    if (deadlineAtMs === null) return providerEffect(provider, operation, () => run({}));
    return Effect.flatMap(Clock.currentTimeMillis, (nowMs) => {
      const remainingMs = Math.max(0, deadlineAtMs - nowMs);
      return Effect.tryPromise({
        try: (signal) => run({ signal }),
        catch: (cause) => new VmProviderOperationError({ provider, operation, cause }),
      }).pipe(
        Effect.timeoutFail({
          duration: remainingMs,
          onTimeout: () => new VmProviderOperationError({
            provider,
            operation,
            cause: new ProviderReadDeadlineError(provider, operation, remainingMs),
          }),
        }),
      );
    });
  });
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
  // Bounded by the provider create deadline even when the SDK polls past it,
  // so a create answered "in progress" (routeDeadline.ts) reaches createVm's
  // failure path (credit refund, row failed) inside the route's reserve.
  create: (provider, options) =>
    providerEffect(provider, "create", () => getProvider(provider).create(options)).pipe(
      Effect.timeoutFail({
        duration: VM_PROVIDER_CREATE_TIMEOUT_MS,
        onTimeout: () => new VmProviderOperationError({
          provider,
          operation: "create",
          cause: new Error(`provider create did not answer within ${VM_PROVIDER_CREATE_TIMEOUT_MS / 60_000} minutes`),
        }),
      }),
    ),
  destroy: (provider, vmId, credential) =>
    providerEffect(provider, "destroy", () => getProvider(provider).destroy(vmId, credential)),
  deleteHomeVolume: (provider, volumeName) =>
    providerEffect(provider, "deleteHomeVolume", async () => {
      const impl = getProvider(provider);
      // A caller only reaches this seam with an explicitly owned volume. Do
      // not report success when the current driver cannot delete legacy
      // storage: durable cleanup must remain pending for retry/operator work.
      if (!impl.deleteHomeVolume) {
        throw new VmOperationUnsupportedError({ provider, operation: "deleteHomeVolume" });
      }
      await impl.deleteHomeVolume(volumeName);
    }),
  listAccountVms: (provider, options) =>
    Effect.tryPromise({
      try: (signal) => healthInventory(provider).listAccountVms({ ...options, signal }),
      catch: (cause) => new VmProviderOperationError({ provider, operation: "listAccountVms", cause }),
    }),
  listAccountTlsRules: (provider, options) =>
    Effect.tryPromise({
      try: (signal) => healthInventory(provider).listAccountTlsRules({ ...options, signal }),
      catch: (cause) => new VmProviderOperationError({ provider, operation: "listAccountTlsRules", cause }),
    }),
  probeVmControl: (provider, vmId, options) =>
    Effect.tryPromise({
      try: (signal) => healthInventory(provider).probeControl(vmId, { ...options, signal }),
      catch: (cause) => new VmProviderOperationError({ provider, operation: "probeVmControl", cause }),
    }),
  listVolumes: (provider, options) =>
    providerEffect(provider, "listVolumes", async () => {
      const impl = getProvider(provider);
      // Providers without persistent volume support have no inventory to reap.
      if (!impl.listVolumes) return [];
      return await impl.listVolumes(options);
    }),
  getStatus: (provider, vmId, credential) =>
    boundedProviderRead(provider, "getStatus", async (options) => {
      const driver = getProvider(provider);
      if (!driver.getStatus) return "running" as const;
      return await driver.getStatus(vmId, { ...options, credential });
    }),
  getPauseState: (provider, vmId, credential) =>
    providerEffect(provider, "getPauseState", async () => {
      const driver = getProvider(provider);
      return driver.getPauseState ? await driver.getPauseState(vmId, credential) : null;
    }),
  resume: (provider, vmId, credential) =>
    providerEffect(provider, "resume", () => getProvider(provider).resume(vmId, credential)),
  pause: (provider, vmId, credential) =>
    providerEffect(provider, "pause", () => getProvider(provider).pause(vmId, credential)),
  setRuntimeBudget: (provider, vmId, remainingSeconds) => providerEffect(provider, "setRuntimeBudget", async () => {
    const driver = getProvider(provider);
    if (!driver.setRuntimeBudget) throw new Error("Provider runtime caps are unavailable");
    await driver.setRuntimeBudget(vmId, remainingSeconds);
  }),
  snapshot: (provider, vmId, name) =>
    providerEffect(provider, "snapshot", () => getProvider(provider).snapshot(vmId, name)),
  restore: (provider, snapshotId, options) =>
    providerEffect(provider, "restore", () => getProvider(provider).restore(snapshotId, options)),
  capabilities: (provider) => vmCapabilitiesFor(provider),
  listSnapshots: (provider, vmId) =>
    boundedProviderRead(provider, "listSnapshots", async (options) => {
      const impl = getProvider(provider);
      if (!impl.listSnapshots) {
        // Typed, so the route answers 501 (cannot) rather than a retryable 502.
        throw new VmOperationUnsupportedError({ provider, operation: "listSnapshots" });
      }
      return await impl.listSnapshots(vmId, options);
    }),
  deleteSnapshot: (provider, vmId, snapshotId) =>
    providerEffect(provider, "deleteSnapshot", async () => {
      const impl = getProvider(provider);
      if (!impl.deleteSnapshot) {
        throw new VmOperationUnsupportedError({ provider, operation: "deleteSnapshot" });
      }
      await impl.deleteSnapshot(vmId, snapshotId);
    }),
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
  listFiles: (provider, vmId, path) => boundedProviderRead(provider, "listFiles", async (options) => {
    const impl = getProvider(provider);
    if (!impl.listFiles) throw new VmOperationUnsupportedError({ provider, operation: "listFiles" });
    return impl.listFiles(vmId, path, options);
  }),
  readFile: (provider, vmId, path) => boundedProviderRead(provider, "readFile", async (options) => {
    const impl = getProvider(provider);
    if (!impl.readFile) throw new VmOperationUnsupportedError({ provider, operation: "readFile" });
    return impl.readFile(vmId, path, options);
  }),
  writeFile: (provider, vmId, path, data, mode) => providerEffect(provider, "writeFile", async () => {
    const impl = getProvider(provider);
    if (!impl.writeFile) throw new VmOperationUnsupportedError({ provider, operation: "writeFile" });
    return impl.writeFile(vmId, path, data, mode);
  }),
  makeDirectory: (provider, vmId, path) => providerEffect(provider, "makeDirectory", async () => {
    const impl = getProvider(provider);
    if (!impl.makeDirectory) throw new VmOperationUnsupportedError({ provider, operation: "makeDirectory" });
    return impl.makeDirectory(vmId, path);
  }),
  removeFile: (provider, vmId, path) => providerEffect(provider, "removeFile", async () => {
    const impl = getProvider(provider);
    if (!impl.removeFile) throw new VmOperationUnsupportedError({ provider, operation: "removeFile" });
    return impl.removeFile(vmId, path);
  }),
  statFile: (provider, vmId, path) => boundedProviderRead(provider, "statFile", async (options) => {
    const impl = getProvider(provider);
    if (!impl.statFile) throw new VmOperationUnsupportedError({ provider, operation: "statFile" });
    return impl.statFile(vmId, path, options);
  }),
  openPort: (provider, vmId, port) =>
    providerEffect(provider, "openPort", async () => {
      const impl = getProvider(provider);
      if (!impl.openPort) {
        throw new VmOperationUnsupportedError({ provider, operation: "openPort" });
      }
      return await impl.openPort(vmId, port);
    }),
  getStats: (provider, vmId) =>
    boundedProviderRead(provider, "getStats", async (options) => {
      const impl = getProvider(provider);
      if (!impl.getStats) {
        // Typed, so the route answers "unsupported" (non-retryable) instead of
        // a retryable 502 the activity panel would poll forever.
        throw new VmOperationUnsupportedError({ provider, operation: "getStats" });
      }
      return await impl.getStats(vmId, options);
    }),
  getResourceStats: (provider, vmId) => providerEffect(provider, "getResourceStats", async () => {
    const impl = getProvider(provider);
    if (!impl.getResourceStats) {
      throw new VmOperationUnsupportedError({ provider, operation: "getResourceStats" });
    }
    return await impl.getResourceStats(vmId);
  }),
  restart: (provider, vmId) => {
    const impl = getProvider(provider);
    if (!vmCapabilitiesFor(provider).restart || !impl.restart) {
      return Effect.fail(new VmOperationUnsupportedError({ provider, operation: "restart" }));
    }
    return providerEffect(provider, "restart", () => impl.restart!(vmId));
  },
  resize: (provider, vmId, options) => {
    const impl = getProvider(provider);
    if (!impl.resize) return Effect.fail(new VmOperationUnsupportedError({ provider, operation: "resize" }));
    return providerEffect(provider, "resize", () => impl.resize!(vmId, options));
  },
  applyNetworkPolicy: (provider, vmId, plan) => {
    const impl = getProvider(provider);
    if (!impl.applyNetworkPolicy) return Effect.fail(new VmOperationUnsupportedError({ provider, operation: "applyNetworkPolicy" }));
    return providerEffect(provider, "applyNetworkPolicy", () => impl.applyNetworkPolicy!(vmId, plan));
  },
  attachTransports: (provider) => getProvider(provider).attachTransports,
  openAttach: (provider, vmId, options) =>
    providerEffect(provider, "openAttach", async () => {
      const impl = getProvider(provider);
      if (!impl.openAttach) {
        throw new VmOperationUnsupportedError({ provider, operation: "openAttach" });
      }
      return await impl.openAttach(vmId, options);
    }),
  openCmuxRemote: (provider, vmId, options) =>
    providerEffect(provider, "openCmuxRemote", () => {
      const impl = getProvider(provider);
      if (!impl.openCmuxRemote) {
        throw new VmOperationUnsupportedError({ provider, operation: "openCmuxRemote" });
      }
      return impl.openCmuxRemote(vmId, options);
    }),
  approveCmuxRemoteEnrollment: (provider, vmId, invitationId, options) =>
    providerEffect(provider, "approveCmuxRemoteEnrollment", () => {
      const impl = getProvider(provider);
      if (!impl.approveCmuxRemoteEnrollment) {
        throw new VmOperationUnsupportedError({ provider, operation: "approveCmuxRemoteEnrollment" });
      }
      return impl.approveCmuxRemoteEnrollment(vmId, invitationId, options);
    }),
  prepareSCP: (provider, vmId, publicKey) =>
    providerEffect(provider, "prepareSCP", async () => {
      const impl = getProvider(provider);
      if (!impl.prepareSCP) throw new VmOperationUnsupportedError({ provider, operation: "prepareSCP" });
      return impl.prepareSCP(vmId, publicKey);
    }),
  openSSH: (provider, vmId, credential) =>
    providerEffect(provider, "openSSH", async () => {
      const impl = getProvider(provider);
      if (!impl.openSSH) {
        throw new VmOperationUnsupportedError({ provider, operation: "openSSH" });
      }
      return await impl.openSSH(vmId, credential);
    }),
  revokeSSHIdentity: (provider, identityHandle) => {
    const driver = getProvider(provider);
    // A driver without openSSH never minted an identity; revocation is a no-op.
    if (!driver.openSSH) return Effect.void;
    return providerEffect(provider, "revokeSSHIdentity", async () => {
      if (!driver.revokeSSHIdentity) throw new VmOperationUnsupportedError({ provider, operation: "revokeSSHIdentity" });
      await driver.revokeSSHIdentity(identityHandle);
    });
  },
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
  getNetwork: (provider, networkId) =>
    providerEffect(provider, "getNetwork", () =>
      privateNetworking(provider).getNetwork(networkId)
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
  attachTunnelNetwork: (provider, tunnelId, networkId) =>
    providerEffect(provider, "attachTunnelNetwork", async () => {
      const networking = privateNetworking(provider);
      if (!networking.attachTunnelNetwork) throw new VmOperationUnsupportedError({ provider, operation: "attachTunnelNetwork" });
      return await networking.attachTunnelNetwork(tunnelId, networkId);
    }),
  detachTunnelNetwork: (provider, tunnelId, networkId) =>
    providerEffect(provider, "detachTunnelNetwork", async () => {
      const networking = privateNetworking(provider);
      if (!networking.detachTunnelNetwork) throw new VmOperationUnsupportedError({ provider, operation: "detachTunnelNetwork" });
      await networking.detachTunnelNetwork(tunnelId, networkId);
    }),
  listNetworkTunnelIds: (provider, networkId) =>
    providerEffect(provider, "listNetworkTunnelIds", async () => {
      const networking = privateNetworking(provider);
      if (!networking.listNetworkTunnelIds) throw new VmOperationUnsupportedError({ provider, operation: "listNetworkTunnelIds" });
      return await networking.listNetworkTunnelIds(networkId);
    }),
  listFirewallRules: (provider, options) => providerEffect(provider, "listFirewallRules", async () => {
    const networking = getProvider(provider).privateNetworking;
    if (!networking?.listFirewallRules) throw new VmOperationUnsupportedError({ provider, operation: "listFirewallRules" });
    return await networking.listFirewallRules(options);
  }),
  getFirewallRule: (provider, ruleId) => providerEffect(provider, "getFirewallRule", async () => {
    const networking = getProvider(provider).privateNetworking;
    if (!networking?.getFirewallRule) throw new VmOperationUnsupportedError({ provider, operation: "getFirewallRule" });
    return await networking.getFirewallRule(ruleId);
  }),
  createFirewallRule: (provider, options) => providerEffect(provider, "createFirewallRule", async () => {
    const networking = getProvider(provider).privateNetworking;
    if (!networking?.createFirewallRule) throw new VmOperationUnsupportedError({ provider, operation: "createFirewallRule" });
    return await networking.createFirewallRule(options);
  }),
  deleteFirewallRule: (provider, ruleId) => providerEffect(provider, "deleteFirewallRule", async () => {
    const networking = getProvider(provider).privateNetworking;
    if (!networking?.deleteFirewallRule) throw new VmOperationUnsupportedError({ provider, operation: "deleteFirewallRule" });
    await networking.deleteFirewallRule(ruleId);
  }),
});
