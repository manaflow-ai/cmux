# VM provider driver contract

`VmProviderDriver` in `types.ts` is the interface consumed by `VmProviderGateway`.
`VMProvider` remains a compatibility alias. Freestyle is the only registered provider.
Drivers translate provider SDK responses into this contract; workflows own database
state, authorization, billing, and create deduplication.

## Capabilities and lifecycle

The registry's `vmCapabilitiesOf` combines implemented methods with explicit capability
flags. Keep those declarations consistent with the methods a driver can serve.
Private networking is an account-level capability: owner networks and client tunnels
outlive individual machines.

- `create` and `restore` return a machine handle. Roll back newly created provider resources
  when setup fails. A restored machine uses the owner's network just like a new machine.
- `destroy` and network/tunnel deletion treat an already-missing resource as success.
- `getStatus` and `getStats` must not wake a sleeping machine.
- `exec` returns an exit code and output streams. Validate its response through
  `schemas.ts`, including administrative commands used during attach and repair.
  An absent or malformed status code is a provider error. Freestyle's explicit null
  status code means timeout and maps to exit 124. Null streams become empty strings.
- `snapshot`, `restore`, and optional snapshot inventory/deletion operate through the
  gateway. Snapshot deletion verifies the snapshot belongs to the requested machine.

## Attach and ports

Freestyle declares only the `cmux-remote` session transport. `cmuxTuiDaemon.ts` owns the
shared pinned-daemon installation, readiness, and attach bundle helpers. Keep the
current trusted-carrier and private-network path; the retired cmuxd-remote PTY/RPC
lease installation and SSH fallback do not apply to these machines.

The driver repairs the daemon when necessary and validates the attach bundle before
returning a route. Prefer a machine's private address. Desktop and forwarded HTTP
ports require its private network; they never fall back to public ingress.

## Errors

`ProviderError` names the provider and operation, retaining underlying SDK errors in
`cause` where applicable. `schemas.ts` rejects malformed exec responses at the driver
boundary. The gateway maps driver failures into typed workflow errors. Best-effort
health probes may translate failure into an unsuccessful probe, but must never turn
malformed responses into successful commands.
