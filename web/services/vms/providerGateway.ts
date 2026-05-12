import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import {
  getProvider,
  type AttachEndpoint,
  type AttachOptions,
  type CreateOptions,
  type ExecResult,
  type ProviderId,
  type SSHEndpoint,
  type VMHandle,
} from "./drivers";
import { VmProviderOperationError } from "./errors";

export type VmProviderGatewayShape = {
  readonly create: (provider: ProviderId, options: CreateOptions) => Effect.Effect<VMHandle, VmProviderOperationError>;
  readonly destroy: (provider: ProviderId, vmId: string) => Effect.Effect<void, VmProviderOperationError>;
  readonly exec: (
    provider: ProviderId,
    vmId: string,
    command: string,
    options?: { timeoutMs?: number },
  ) => Effect.Effect<ExecResult, VmProviderOperationError>;
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

export const VmProviderGatewayLive = Layer.succeed(VmProviderGateway, {
  create: (provider, options) =>
    providerEffect(provider, "create", () => getProvider(provider).create(options)),
  destroy: (provider, vmId) =>
    providerEffect(provider, "destroy", () => getProvider(provider).destroy(vmId)),
  exec: (provider, vmId, command, options) =>
    providerEffect(provider, "exec", () => getProvider(provider).exec(vmId, command, options)),
  openAttach: (provider, vmId, options) =>
    providerEffect(provider, "openAttach", () => getProvider(provider).openAttach(vmId, options)),
  openSSH: (provider, vmId) =>
    providerEffect(provider, "openSSH", () => getProvider(provider).openSSH(vmId)),
  revokeSSHIdentity: (provider, identityHandle) =>
    providerEffect(provider, "revokeSSHIdentity", () =>
      getProvider(provider).revokeSSHIdentity(identityHandle)
    ),
});
