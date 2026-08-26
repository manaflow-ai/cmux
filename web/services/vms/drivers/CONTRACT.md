# VmProviderDriver contract

`types.ts` defines `VmProviderDriver`, the single interface every VM provider implements
(`blaxel.ts`, `freestyle.ts`, `daytona.ts`, `e2b.ts`). Workflows never import a concrete driver:
they reach providers through `VmProviderGateway` (`../providerGateway.ts`), which resolves the
driver by `ProviderId` and lifts each call into Effect. Adding a provider means one new driver
file plus a registry entry in `index.ts` (and, to make it selectable, a kill-switch env key in
`../config.ts` and an image entry in `../images/manifest.json`).

## Shared modules a driver must use

- `cmuxdConstants.ts` — cmuxd port, lease paths, TTLs, timeout clamps. Never re-declare these.
- `cmuxdAttach.ts` — the attach ritual: lease-path discovery, reusable-RPC-lease read,
  atomic lease install, endpoint assembly inputs, and the `/healthz` poll (`waitForCmuxdHealthy`,
  the ONE retry idiom). A driver supplies only a `ProviderTransport` (`exec` into the guest).
- `schemas.ts` — zod schemas for provider JSON. Every raw JSON payload from a provider API is
  validated at the driver boundary; `as T` casts of provider responses are forbidden. Schema
  mismatch raises `ProviderError` naming the provider and operation.
- `wsLease.ts` — lease minting primitives (tokens, sha256 lease bodies, shell quoting).

## Identity and state

- `providerVmId` is the provider's own machine identifier and the key workflows store in
  Postgres. Blaxel uses the human-friendly sandbox name; the others use SDK ids.
- `providerMetadata` is an opaque, driver-owned bag persisted on the VM row and handed back on
  later calls (`AttachOptions.providerMetadata`). Only the server may populate it; workflows
  overwrite anything a client sent. Blaxel stores `sandboxUrl`, `previewUrl`, `homeVolume`,
  `image`, `memoryMb` (resurrection needs them); Freestyle stores its daemon admin token.
- `VMStatus` is the four-state cmux view (`creating | running | paused | destroyed`); each
  driver maps its provider's richer state machine onto it and must map unknown states to
  `running`, never throw.

## Method semantics

| Method | Semantics | Idempotency |
| --- | --- | --- |
| `create` | Provision a machine from a resolved image and return a running handle. Must roll back the provider resource if bootstrap fails partway (Blaxel deletes the sandbox but keeps the durable home volume). | Not idempotent; caller (workflow) owns dedup via the repository create-lock. |
| `destroy` | Release the machine's compute and ingress. | Idempotent: an already-gone machine (provider 404) is success, not an error. Cleanup paths retry it. |
| `getStatus?` | Cheap control-plane read of the machine state. Must not wake or mutate. Omitting it means "assume running" (the gateway substitutes that). | Read-only. |
| `getStats?` | CPU/memory/disk sample for the activity panel. Must NOT wake a sleeping machine — report `asleep` with provisioned totals instead. | Read-only. |
| `pause` | Suspend/standby: stop billing-relevant compute while keeping the filesystem. Providers with automatic standby (Blaxel) implement it as a no-op. | Idempotent. |
| `resume` | Wake: bring the machine back to `running` and return a fresh handle. For auto-standby providers this is just a status read (the read itself wakes). Should repair the in-guest daemon if the provider kills processes on stop (Daytona). | Idempotent. |
| `exec` | Run one shell command in the guest, returning `{exitCode, stdout, stderr}`. Timeouts clamp to `MAX_EXEC_TIMEOUT_MS`. A malformed provider response (e.g. missing exit code) is a `ProviderError`, never silently exit-0. | Not idempotent (arbitrary command). |
| `snapshot` / `restore` | Durable image of the machine / new machine from such an image. Providers without the feature throw `NotImplementedError`. | `restore` creates a new machine each call. |
| `fork?` | Clone a running machine (Freestyle only today). | Not idempotent. |
| `openAttach` | The write-lease + endpoint path: ensure the in-guest cmuxd daemon is healthy (repairing or re-bootstrapping if the transport allows), install a one-use PTY lease plus the reusable RPC lease, and return a `WebSocketPtyEndpoint`. With `requireDaemon` it must fail rather than return a PTY-only endpoint; without it, Freestyle may fall back to SSH for health-shaped failures only. Honors `sessionId`/`attachmentId` pinning from `AttachOptions`. | Safe to repeat; every call mints a fresh PTY lease, and the RPC lease is reused until near expiry. |
| `openSSH` | Mint a live SSH endpoint with a per-session revocable credential. WebSocket-only providers throw a user-facing `ProviderError` pointing at the attach path. | Each call mints a new identity; caller must revoke the previous `identityHandle`. |
| `revokeSSHIdentity` | Revoke a credential handle from `openSSH`. Must be safe on unknown/already-revoked handles and a no-op for providers that never mint them. | Idempotent by contract. |
| `revokeEndpointLeases?` | Sign-out path: kill provider-side ingress credentials and live daemon connections for one VM so copied URLs stop working before their TTL. Next authenticated attach recreates everything. | Idempotent (missing previews/processes are success). |
| `openPort?` | The desktop/VNC and arbitrary-port ingress: a private, token-gated HTTPS preview URL for one guest port. The desktop wrapper (`../desktopWrapper.ts`) turns `openUrl` into the user-visible `/vm/desktop/...` page that frames noVNC. Providers without port ingress omit it and the gateway reports "does not support opening ports". | Safe to repeat; re-issues the preview and a fresh token. |

## Error taxonomy

- `ProviderError` (`types.ts`) — the only error class drivers throw for provider-side failures.
  Tagged with the `ProviderId`; the original SDK/HTTP error rides in `cause`. Drivers wrap
  unknown thrown values so callers never see raw SDK exceptions.
- `NotImplementedError extends ProviderError` — a capability the provider genuinely lacks.
- `../providerErrors.ts` classifies provider-not-found / identity-not-found out of
  `ProviderError.cause` so workflows can treat "already gone" as success.
- The gateway wraps every driver rejection in `VmWorkflowError`'s `VmProviderOperationError`
  (`../errors.ts`), carrying `{provider, operation, cause}`; workflows switch on that, never on
  driver-specific error strings. One exception lives inside a driver: Freestyle's SSH-fallback
  classifier matches its own health-check messages, which is why `cmuxdAttach.ts` keeps those
  messages stable (`"<label> cmuxd websocket health check failed/returned <status>"`).

## Attach endpoint invariants

- `WebSocketPtyEndpoint.token` is one-use and expires in minutes; `daemon.token` is reusable
  for hours and shared across attaches to the same VM.
- Every ingress URL must be private (token-gated). Blaxel previews that come back `public` are
  treated as absent and recreated.
- Lease files are installed atomically (temp file + `mv -f`) with mode 600 under a mode-700
  directory, in ONE exec round-trip, so the daemon never observes a half-written lease.
