// Unified driver contract over each VM provider. No cloudrouter, no shared base class — just
// per-provider implementations behind an interface. Callers hold a `VMProvider` and never reach
// into specifics.

export type ProviderId = "e2b" | "freestyle" | "daytona" | "blaxel";

const PROVIDER_IDS: readonly ProviderId[] = ["e2b", "freestyle", "daytona", "blaxel"];

export function isProviderId(value: unknown): value is ProviderId {
  return typeof value === "string" && PROVIDER_IDS.includes(value as ProviderId);
}

export type VMStatus = "creating" | "running" | "paused" | "destroyed";

/// A point-in-time reading of one machine. Sleeping machines are never woken for a
/// reading: they report `asleep` with only their provisioned memory.
export type VMStats = {
  readonly state: "awake" | "asleep" | "unknown";
  readonly sampledAt: number;
  readonly cpus?: number;
  readonly cpuPercent?: number;
  readonly loadAverage1m?: number;
  readonly memoryTotalMb?: number;
  readonly memoryUsedMb?: number;
  readonly diskTotalMb?: number;
  readonly diskUsedMb?: number;
};

export type VMHandle = {
  provider: ProviderId;
  providerVmId: string;
  status: VMStatus;
  image: string; // e.g. "cmux-sandbox:v0-71a954b8e53b" for e2b
  createdAt: number;
  providerMetadata?: Record<string, unknown>;
};

export type CreateOptions = {
  image: string; // provider-specific template/snapshot identifier
  providerMetadata?: Record<string, unknown>;
  bakedFreestyleSignedAdmin?: boolean;
  /**
   * Name of a persistent volume to mount as the machine's home directory. Providers that
   * support it create the volume if missing and record it in providerMetadata so attach can
   * resurrect a dead sandbox around the same home. Providers without volume support ignore it.
   */
  homeVolume?: string;
  /**
   * Machine size as memory in MB (vCPUs scale with memory on providers that size
   * this way). Providers without sizing ignore it.
   */
  memoryMb?: number;
  /**
   * Machine-level environment injected at create time (e.g. the coderouter
   * model-plane env: OPENAI_BASE_URL + a per-machine route token). Values may
   * be secrets: drivers must pass them to the provider's create call only and
   * never echo them into VMHandle.providerMetadata, which is persisted.
   * Providers without machine-level env support ignore it.
   */
  envs?: Readonly<Record<string, string>>;
};

export type SSHEndpoint = {
  transport: "ssh";
  host: string;
  port: number;
  username: string;
  publicKeyFingerprint: string | null;
  // One-time credential for this attach session. Drivers decide whether that's a password,
  // a bearer over an SSH ProxyCommand, or an authorized_keys line the client pushes.
  credential: { kind: "password"; value: string } | { kind: "authorizedKey"; privateKeyPem: string };
  daemon?: {
    url: string;
    headers: Record<string, string>;
    token: string;
    sessionId: string;
    expiresAtUnix: number;
  };
  /**
   * Opaque identity/token handle the driver needs later to revoke these credentials.
   * Freestyle uses its identity id; E2B returns an empty string (no identities there yet).
   * The VM workflow stores this in Postgres and calls `revokeSSHIdentity` on destroy and before
   * minting a replacement identity, so unreferenced tokens don't pile up on the provider side.
   */
  identityHandle: string;
};

export type WebSocketPtyEndpoint = {
  transport: "websocket";
  url: string;
  headers: Record<string, string>;
  token: string;
  sessionId: string;
  attachmentId: string;
  expiresAtUnix: number;
  daemon?: {
    url: string;
    headers: Record<string, string>;
    token: string;
    sessionId: string;
    expiresAtUnix: number;
  };
};

export type AttachEndpoint = SSHEndpoint | WebSocketPtyEndpoint;

/** Session transports a provider can hand out; `attachTransports` on VMProvider lists a driver's. */
export type AttachTransport = "ssh" | "websocket" | "cmux-remote";

/**
 * Attach through the cmux-tui remote daemon running in the VM
 * (docs/cloud-cmux-tui-daemon.md). The route
 * is the provider's tokenized ingress to the daemon's `/v1/link` listener; the
 * token only gates reachability — session auth is the daemon's Noise device
 * enrollment. `invitation` is present when the caller's device is not yet
 * enrolled: the client connects with `remote connect --invite-file`, then asks
 * the control plane to approve the pending enrollment it minted.
 */
export type CmuxRemoteEndpoint = {
  transport: "cmux-remote";
  /** `wss://<host>/v1/link?<provider-token>` — carries the ingress token, so it is never embedded in an invitation. */
  route: string;
  /** Ingress token (hashed into the lease ledger, never persisted raw). */
  token: string;
  expiresAtUnix: number;
  /** Daemon session name inside the VM (`server start --session`). */
  session: string;
  /**
   * The installed daemon's build identity, so a client can compare its own
   * `remote-probe` and say which side is stale instead of failing opaquely.
   */
  daemonBuild?: {
    commit: string | null;
    remoteProtocol: number | null;
    version: string | null;
  };
  invitation?: {
    /** Single-use `cmux://enroll/...` URI; the client must pass it via `--invite-file`, never argv. */
    uri: string;
    /** Identifier the client returns to the approve endpoint. */
    invitationId: string;
    expiresAtUnix: number;
  };
};

export type CmuxRemoteAttachOptions = {
  /**
   * The caller's cmux-tui device fingerprint, when it already enrolled with this
   * VM's daemon. Lets the provider skip minting an invitation.
   */
  deviceFingerprint?: string;
  /**
   * Transport capabilities the caller's cmux-tui client advertises (`remote-probe
   * --json` → `capabilities`). `direct-ws-user-agent` lets the provider hand out the
   * branded machine host, whose ingress refuses upgrades without a User-Agent.
   */
  clientCapabilities?: readonly string[];
  providerMetadata?: Record<string, unknown>;
};

export type CmuxRemoteApprovalResult = {
  approved: boolean;
  /** Fingerprint of the device that claimed the invitation, when approved. */
  deviceFingerprint?: string;
  /** `pending` when the client has not connected yet — the caller should retry. */
  state: "approved" | "pending" | "already_enrolled";
};

export type AttachOptions = {
  /**
   * Workspace attaches need a cmuxd RPC endpoint so browser panels can proxy remote
   * loopback URLs. PTY-only split attaches can omit it and only mint a terminal lease.
   */
  requireDaemon?: boolean;
  /**
   * Stable VM-daemon session id to attach to. When omitted, providers keep the
   * historical behavior and mint a fresh one-use terminal session.
   */
  sessionId?: string;
  /**
   * Stable visible-client attachment id. The daemon uses this to supersede a
   * stale pane/client attachment without killing the underlying VM session.
   */
  attachmentId?: string;
  /**
   * Server-side provider metadata loaded from the owned VM row. Never trust client input
   * for this field; workflows overwrite it before calling the provider.
   */
  providerMetadata?: Record<string, unknown>;
};

export type ExecResult = {
  exitCode: number;
  stdout: string;
  stderr: string;
};

export type SnapshotRef = {
  id: string;
  createdAt: number;
  name?: string;
};

/** What a provider can actually do, so clients hide verbs that would only fail. */
export interface VmCapabilities {
  readonly snapshot: boolean;
  readonly restore: boolean;
  readonly fork: boolean;
}

export interface VMProvider {
  readonly id: ProviderId;
  /**
   * Optional-operation support. A driver that implements `snapshot`/`restore` only to
   * throw NotImplementedError declares that here; `fork` defaults to whether the method
   * exists. Everything omitted defaults to supported.
   */
  readonly capabilities?: Partial<VmCapabilities>;

  create(options: CreateOptions): Promise<VMHandle>;
  destroy(vmId: string): Promise<void>;

  getStatus?(vmId: string): Promise<VMStatus>;
  /// Live CPU/memory/disk for the Cloud panel's activity view. Must not wake a
  /// sleeping machine.
  getStats?(vmId: string): Promise<VMStats>;

  pause(vmId: string): Promise<void>;
  resume(vmId: string): Promise<VMHandle>;

  exec(vmId: string, command: string, opts?: { timeoutMs?: number }): Promise<ExecResult>;

  // Optional: mint a private, token-gated HTTPS preview URL for an arbitrary HTTP port on the
  // VM (the exe.dev "https://vmname.exe.xyz:3456" equivalent). openUrl embeds the token as a
  // query parameter for direct browser use.
  openPort?(vmId: string, port: number): Promise<{ url: string; token: string; openUrl: string; expiresAtMs?: number }>;

  snapshot(vmId: string, name?: string): Promise<SnapshotRef>;
  restore(snapshotId: string): Promise<VMHandle>;
  fork?(vmId: string): Promise<VMHandle>;

  // Session transports this driver supports. Undefined means the legacy set (`websocket`
  // and/or `ssh` via openAttach/openSSH). A driver that lists only `cmux-remote` (Blaxel)
  // never serves openAttach: workflows fail such requests with
  // VmAttachTransportUnsupportedError before reaching the provider.
  readonly attachTransports?: readonly AttachTransport[];

  // Returns a live attach endpoint the client can dial into: cmuxd-remote WebSocket PTY
  // with a short-lived one-use lease (E2B/Daytona/Freestyle), or SSH.
  openAttach(vmId: string, options?: AttachOptions): Promise<AttachEndpoint>;

  // Optional: attach through the cmux-tui remote daemon in the VM (see CmuxRemoteEndpoint).
  // Blaxel machines run only this daemon; providers that have not been migrated leave
  // this undefined.
  openCmuxRemote?(vmId: string, options?: CmuxRemoteAttachOptions): Promise<CmuxRemoteEndpoint>;
  // Optional: approve the pending enrollment a previous openCmuxRemote invited.
  approveCmuxRemoteEnrollment?(vmId: string, invitationId: string): Promise<CmuxRemoteApprovalResult>;

  // Returns a live SSH endpoint the client can dial into. Drivers are responsible for ensuring
  // sshd is running (some providers need an explicit start step).
  openSSH(vmId: string): Promise<SSHEndpoint>;

  // Best-effort revocation of an identity handle that `openSSH` previously returned. No-op
  // if the driver doesn't mint revocable credentials (e.g. E2B), must not throw on unknown
  // or already-revoked handles. Cleanup paths rely on it being safe to call.
  revokeSSHIdentity(identityHandle: string): Promise<void>;

  /**
   * Invalidates endpoint credentials and live daemon connections for one VM.
   *
   * This is invoked during account sign-out after the local client has closed
   * its workspaces. Providers that do not expose revocable WebSocket/preview
   * credentials may omit it; the control plane still marks their lease rows
   * revoked so no new endpoint can be returned to the signed-out account.
   */
  revokeEndpointLeases?(vmId: string): Promise<void>;
}

export class ProviderError extends Error {
  constructor(
    public readonly provider: ProviderId,
    message: string,
    public readonly cause?: unknown,
  ) {
    super(`[${provider}] ${message}`);
    this.name = "ProviderError";
  }
}

export class NotImplementedError extends ProviderError {
  constructor(provider: ProviderId, operation: string) {
    super(provider, `${operation}: not implemented yet`);
    this.name = "NotImplementedError";
  }
}
