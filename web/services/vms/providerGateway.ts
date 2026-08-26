import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import {
  getProvider,
  NotImplementedError,
  type AttachEndpoint,
  type AttachOptions,
  type CreateOptions,
  type ExecResult,
  type ProviderId,
  type SnapshotRef,
  type SSHEndpoint,
  type VMHandle,
  type VmProviderCapabilities,
  type VMStatus,
  type VMStats,
} from "./drivers";
import { VmProviderOperationError } from "./errors";

export type VmProviderGatewayShape = {
  readonly create: (provider: ProviderId, options: CreateOptions) => Effect.Effect<VMHandle, VmProviderOperationError>;
  readonly destroy: (provider: ProviderId, vmId: string) => Effect.Effect<void, VmProviderOperationError>;
  readonly getStatus?: (provider: ProviderId, vmId: string) => Effect.Effect<VMStatus, VmProviderOperationError>;
  readonly resume?: (provider: ProviderId, vmId: string) => Effect.Effect<VMHandle, VmProviderOperationError>;
  readonly pause?: (provider: ProviderId, vmId: string) => Effect.Effect<void, VmProviderOperationError>;
  readonly snapshot?: (
    provider: ProviderId,
    vmId: string,
    name?: string,
  ) => Effect.Effect<SnapshotRef, VmProviderOperationError>;
  readonly restore?: (provider: ProviderId, snapshotId: string) => Effect.Effect<VMHandle, VmProviderOperationError>;
  readonly fork?: (provider: ProviderId, vmId: string) => Effect.Effect<VMHandle, VmProviderOperationError>;
  readonly exec: (
    provider: ProviderId,
    vmId: string,
    command: string,
    options?: { timeoutMs?: number },
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
  readonly openAttach: (
    provider: ProviderId,
    vmId: string,
    options?: AttachOptions,
  ) => Effect.Effect<AttachEndpoint, VmProviderOperationError>;
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
   * The provider's declared capability flags, for branching before an operation is attempted
   * (instead of calling a method and catching NotImplementedError). Optional so existing test
   * fakes keep compiling; the Live layer always provides it.
   */
  readonly capabilities?: (provider: ProviderId) => VmProviderCapabilities;
};

export class VmProviderGateway extends Context.Tag("cmux/VmProviderGateway")<
  VmProviderGateway,
  VmProviderGatewayShape
>() {}

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

// Optional operations are gated on the driver's DECLARED capabilities, not on method
// presence or a thrown NotImplementedError: the flags are the contract, and the error each
// gate raises is byte-identical to what the old throwing stubs produced, so callers see no
// behavior change.
export const VmProviderGatewayLive = Layer.succeed(VmProviderGateway, {
  create: (provider, options) =>
    providerEffect(provider, "create", () => getProvider(provider).create(options)),
  destroy: (provider, vmId) =>
    providerEffect(provider, "destroy", () => getProvider(provider).destroy(vmId)),
  getStatus: (provider, vmId) =>
    providerEffect(provider, "getStatus", async () => {
      const driver = getProvider(provider);
      if (!driver.capabilities.getStatus || !driver.getStatus) return "running" as const;
      return await driver.getStatus(vmId);
    }),
  resume: (provider, vmId) =>
    providerEffect(provider, "resume", () => getProvider(provider).resume(vmId)),
  pause: (provider, vmId) =>
    providerEffect(provider, "pause", () => getProvider(provider).pause(vmId)),
  snapshot: (provider, vmId, name) =>
    providerEffect(provider, "snapshot", async () => {
      const driver = getProvider(provider);
      if (!driver.capabilities.snapshot || !driver.snapshot) {
        throw new NotImplementedError(provider, "snapshot");
      }
      return await driver.snapshot(vmId, name);
    }),
  restore: (provider, snapshotId) =>
    providerEffect(provider, "restore", async () => {
      const driver = getProvider(provider);
      if (!driver.capabilities.snapshot || !driver.restore) {
        throw new NotImplementedError(provider, "restore");
      }
      return await driver.restore(snapshotId);
    }),
  fork: (provider, vmId) =>
    providerEffect(provider, "fork", async () => {
      const driver = getProvider(provider);
      if (!driver.capabilities.fork || !driver.fork) {
        throw new Error("Cloud VM forks are not supported by this provider");
      }
      return await driver.fork(vmId);
    }),
  exec: (provider, vmId, command, options) =>
    providerEffect(provider, "exec", () => getProvider(provider).exec(vmId, command, options)),
  openPort: (provider, vmId, port) =>
    providerEffect(provider, "openPort", () => {
      const impl = getProvider(provider);
      if (!impl.capabilities.openPort || !impl.openPort) {
        throw new Error(`provider ${provider} does not support opening ports`);
      }
      return impl.openPort(vmId, port);
    }),
  getStats: (provider, vmId) =>
    providerEffect(provider, "getStats", () => {
      const impl = getProvider(provider);
      if (!impl.capabilities.getStats || !impl.getStats) {
        throw new Error(`provider ${provider} does not report machine stats`);
      }
      return impl.getStats(vmId);
    }),
  openAttach: (provider, vmId, options) =>
    providerEffect(provider, "openAttach", () => getProvider(provider).openAttach(vmId, options)),
  openSSH: (provider, vmId) =>
    providerEffect(provider, "openSSH", () => getProvider(provider).openSSH(vmId)),
  revokeSSHIdentity: (provider, identityHandle) =>
    providerEffect(provider, "revokeSSHIdentity", () =>
      getProvider(provider).revokeSSHIdentity(identityHandle)
    ),
  revokeEndpointLeases: (provider, vmId) => {
    const driver = getProvider(provider);
    if (!driver.capabilities.revokeEndpointLeases || !driver.revokeEndpointLeases) {
      return Effect.void;
    }
    return providerEffect(provider, "revokeEndpointLeases", () => driver.revokeEndpointLeases!(vmId));
  },
  capabilities: (provider) => getProvider(provider).capabilities,
});
