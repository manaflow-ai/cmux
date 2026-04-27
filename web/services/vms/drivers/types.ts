// Unified driver contract over each VM provider. No cloudrouter, no shared base class — just two
// implementations behind an interface. Callers hold a `VMProvider` and never reach into specifics.

export type ProviderId = "e2b" | "freestyle";

export type VMStatus = "creating" | "running" | "paused" | "destroyed";

export type VMHandle = {
  provider: ProviderId;
  providerVmId: string;
  status: VMStatus;
  image: string; // e.g. "cmux-sandbox:v0-71a954b8e53b" for e2b
  createdAt: number;
};

export type CreateOptions = {
  image: string; // provider-specific template/snapshot identifier
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

export type AttachOptions = {
  /**
   * Workspace attaches need a cmuxd RPC endpoint so browser panels can proxy remote
   * loopback URLs. PTY-only split attaches can omit it and only mint a terminal lease.
   */
  requireDaemon?: boolean;
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

export interface VMProvider {
  readonly id: ProviderId;

  create(options: CreateOptions): Promise<VMHandle>;
  destroy(vmId: string): Promise<void>;

  pause(vmId: string): Promise<void>;
  resume(vmId: string): Promise<VMHandle>;

  exec(vmId: string, command: string, opts?: { timeoutMs?: number }): Promise<ExecResult>;

  snapshot(vmId: string, name?: string): Promise<SnapshotRef>;
  restore(snapshotId: string): Promise<VMHandle>;

  // Returns a live attach endpoint the client can dial into. Providers prefer cmuxd-remote
  // WebSocket PTY with a short-lived one-use lease, with provider-specific fallbacks.
  openAttach(vmId: string, options?: AttachOptions): Promise<AttachEndpoint>;

  // Returns a live SSH endpoint the client can dial into. Drivers are responsible for ensuring
  // sshd is running (some providers need an explicit start step).
  openSSH(vmId: string): Promise<SSHEndpoint>;

  // Best-effort revocation of an identity handle that `openSSH` previously returned. No-op
  // if the driver doesn't mint revocable credentials (e.g. E2B), must not throw on unknown
  // or already-revoked handles. Cleanup paths rely on it being safe to call.
  revokeSSHIdentity(identityHandle: string): Promise<void>;
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
