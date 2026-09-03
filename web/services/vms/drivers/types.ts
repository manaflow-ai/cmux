// Unified driver contract over each VM provider. No cloudrouter, no shared base class — just
// per-provider implementations behind an interface. Callers hold a `VMProvider` and never reach
// into specifics.

export type ProviderId = "freestyle";

const PROVIDER_IDS: readonly ProviderId[] = ["freestyle"];

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

/** A provider persistent volume normalized for report-only inventory scans. */
export type VMVolume = {
  readonly name: string;
  /** Epoch milliseconds from provider metadata, when present. */
  readonly createdAt?: number | null;
  /**
   * Provider attachment id. `null` means the provider explicitly reported that
   * the volume is not attached; `undefined` means attachment is unknown.
   */
  readonly attachedTo?: string | null;
  /** Optional explicit state for providers that distinguish unknown from free. */
  readonly attachmentState?: "attached" | "unattached" | "unknown";
};

/** One bounded provider page returned to the report-only reaper. */
export type VMVolumePage = {
  readonly volumes: readonly VMVolume[];
  readonly nextCursor?: string | null;
  /** Whether the provider explicitly supports pagination for this response. */
  readonly complete?: boolean;
};

export type VMVolumeListOptions = {
  /** Provider page size. Callers must keep this at or below their run budget. */
  readonly limit: number;
  readonly cursor?: string;
};

/** Legacy providers may still return one array; the reaper treats it as partial coverage. */
export type VMVolumeInventory = readonly VMVolume[] | VMVolumePage;

export type VMHandle = {
  provider: ProviderId;
  providerVmId: string;
  status: VMStatus;
  image: string; // the provider snapshot id the machine booted from
  createdAt: number;
  providerMetadata?: Record<string, unknown>;
};

export type CreateOptions = {
  image: string; // provider-specific template/snapshot identifier
  providerMetadata?: Record<string, unknown>;
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
   * The snapshot's own shape when the image is a sized ladder entry
   * (services/vms/images/sizes.ts): the machine boots at the shape that was
   * sold and the driver must not read it back or resize. Absent for size-less
   * images, which are grown to `memoryMb`.
   */
  imageSize?: { readonly name: string; readonly cpu: number; readonly memoryMb: number; readonly storageMb: number } | null;
  /**
   * Machine-level environment delivered at create time (the coderouter
   * model-plane env: OPENAI_BASE_URL plus placeholder keys). Treat values as
   * secrets anyway: drivers pass them to the provider's create call or write
   * them into the guest only, and never echo them into
   * VMHandle.providerMetadata, which is persisted. Providers without
   * machine-level env support ignore it.
   */
  envs?: Readonly<Record<string, string>>;
  /**
   * Per-domain request headers the provider's TLS edge injects into every
   * request the guest makes to `domain` (the coderouter route token and the
   * VM id). Header values are secrets: drivers pass them to the provider's
   * create call only, never persist them, and never write them into the guest.
   * Providers without an injecting edge must refuse them rather than drop them.
   */
  edgeRules?: readonly VmEdgeRule[];
  /**
   * Scheduler for work that must not delay the create response: the guest
   * probe that waits for the provider's TLS edge to activate the coderouter
   * rule (Freestyle takes seconds). The route passes its after-response hook;
   * a caller without one (scripts, tests) gets the work awaited inline.
   */
  afterResponse?: (work: () => Promise<void>) => void;
  /**
   * The owner's private network to attach the machine to. When present the
   * machine takes an address on it and its session daemon is reachable only
   * from other members — the owner's other machines, and the owner's computer
   * over its WireGuard tunnel — so the driver opens no public inbound port.
   * Providers without `privateNetworking` ignore it.
   */
  network?: ProviderNetworkRef;
};

/** Enough of a provider network to attach a machine or a tunnel to it. */
export type ProviderNetworkRef = {
  readonly id: string;
};

/** One edge header-injection rule; see CreateOptions.edgeRules. */
export type VmEdgeRule = {
  /** Exact host name the guest dials (no port, no scheme). */
  readonly domain: string;
  /** Headers the edge sets on every request to `domain`, overwriting the guest's. */
  readonly headers: Readonly<Record<string, string>>;
};

/** Create-time inputs a restore-from-snapshot shares with a fresh create. */
export type RestoreOptions = Pick<CreateOptions, "envs" | "edgeRules" | "providerMetadata" | "afterResponse"> & {
  /** The owner's private network; see {@link CreateOptions.network}. */
  network?: ProviderNetworkRef;
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
   * Freestyle uses its identity id.
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
  /**
   * The machine's addresses on its owner's private network, when the driver
   * read them while resolving the route. The workflow backfills them into the
   * VM row so machines created before address recording still get a copyable
   * IP after their first attach.
   */
  networkAddresses?: { ipv4?: string; ipv6?: string };
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

export type CmuxRemoteApprovalOptions = {
  /** Server-side metadata persisted with the VM row, used for durable-home routing. */
  readonly providerMetadata?: Record<string, unknown>;
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

export type ExecOptions = {
  readonly timeoutMs?: number;
  /** Server-side metadata persisted with the VM row, used for durable-home routing. */
  readonly providerMetadata?: Record<string, unknown>;
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

/** A private network that every machine belonging to one user shares. */
export type ProviderNetwork = {
  readonly id: string;
  readonly slug: string | null;
  /** IPv4 CIDR, when the network has one. */
  readonly cidr: string | null;
  /** IPv6 CIDR. Always present: provider networks are dual-stack. */
  readonly cidrV6: string;
};

/**
 * A WireGuard tunnel: one of the owner's computers as a member of their
 * private network.
 *
 * `clientConfig` is a complete `wg-quick` config whose `PrivateKey` is blank —
 * cmux always supplies its own public key, so the provider never mints (or
 * sees) a private key, and the client fills its own in from its keystore.
 */
export type ProviderTunnel = {
  readonly id: string;
  readonly clientConfig: string;
  readonly clientPublicKey: string;
  readonly serverPublicKey: string;
  readonly endpointHost: string | null;
  readonly endpointPort: number;
  /** The client's `AllowedIPs` — every range it routes through the tunnel. */
  readonly routes: readonly string[];
  /** The tunnel's address inside the attached network, i.e. what the VMs see. */
  readonly addressV4: string | null;
  readonly addressV6: string | null;
};

export type CreateProviderTunnelOptions = {
  readonly slug: string;
  readonly displayName?: string;
  /** Base64 Curve25519 public key. Required: cmux never lets the provider mint a private key. */
  readonly clientPublicKey: string;
  readonly networkId: string;
};

/**
 * Private networking, as a whole-account capability rather than a per-machine
 * one: the network and the tunnels into it outlive every machine on them, so
 * they are addressed by owner, not by VM id.
 *
 * A driver that does not implement this leaves `privateNetworking` undefined,
 * and its machines keep whatever reachability the driver gives them directly.
 */
export interface VMPrivateNetworking {
  /**
   * The owner's network, created if it does not exist yet. Must be idempotent
   * under concurrent calls with the same slug: two machines created at once
   * must land on one network, not two.
   */
  ensureNetwork(options: { slug: string; displayName?: string }): Promise<ProviderNetwork>;
  /** Read a network back, or null when it no longer exists at the provider. */
  getNetwork(networkId: string): Promise<ProviderNetwork | null>;
  /** Delete a network. Must succeed when it is already gone. */
  deleteNetwork(networkId: string): Promise<void>;
  /** Create a tunnel with the network already attached. */
  createTunnel(options: CreateProviderTunnelOptions): Promise<ProviderTunnel>;
  /**
   * Read a tunnel back with its address inside `networkId`, re-attaching the
   * network if the attachment is missing. Null when the tunnel is gone at the
   * provider, which is how a stale control-plane row is detected.
   */
  getTunnel(tunnelId: string, networkId: string): Promise<ProviderTunnel | null>;
  /**
   * Replace the tunnel's keys, keeping its id and every attachment. Used when a
   * client presents a public key that does not match the recorded one — a
   * reinstalled app that lost its private key.
   */
  rotateTunnelKey(tunnelId: string, clientPublicKey: string, networkId: string): Promise<ProviderTunnel>;
  /** Delete a tunnel. Must succeed when it is already gone. */
  deleteTunnel(tunnelId: string): Promise<void>;
}

export interface VMProvider {
  readonly id: ProviderId;

  /**
   * Per-owner private networks and the WireGuard tunnels into them. Undefined
   * on drivers whose machines are only reachable at a public address.
   */
  readonly privateNetworking?: VMPrivateNetworking;
  /**
   * Optional-operation support. A driver that implements `snapshot`/`restore` only to
   * throw NotImplementedError declares that here; `fork` defaults to whether the method
   * exists. Everything omitted defaults to supported.
   */
  readonly capabilities?: Partial<VmCapabilities>;

  create(options: CreateOptions): Promise<VMHandle>;
  destroy(vmId: string): Promise<void>;

  /**
   * Optional: delete a persistent home volume by name. Implementations must treat
   * an already-missing volume as success and absorb the provider's brief
   * volume-still-attached window after the owning sandbox is deleted (bounded
   * retry). Ownership is the caller's judgment: only a volume owned solely by a
   * destroyed machine may be passed here.
   */
  deleteHomeVolume?(volumeName: string): Promise<void>;

  /** Optional provider volume inventory used by the report-only VM reaper. */
  listVolumes?(options?: VMVolumeListOptions): Promise<VMVolumeInventory>;

  getStatus?(vmId: string): Promise<VMStatus>;
  /// Live CPU/memory/disk for the Cloud panel's activity view. Must not wake a
  /// sleeping machine.
  getStats?(vmId: string): Promise<VMStats>;

  pause(vmId: string): Promise<void>;
  resume(vmId: string): Promise<VMHandle>;

  exec(vmId: string, command: string, opts?: ExecOptions): Promise<ExecResult>;

  // Optional: mint a private, token-gated HTTPS preview URL for an arbitrary HTTP port on the
  // VM (the exe.dev "https://vmname.exe.xyz:3456" equivalent). openUrl embeds the token as a
  // query parameter for direct browser use.
  openPort?(vmId: string, port: number): Promise<{ url: string; token: string; openUrl: string; expiresAtMs?: number }>;

  snapshot(vmId: string, name?: string): Promise<SnapshotRef>;
  /**
   * Boot a new machine from a snapshot. `options.network` places it on the
   * owner's private network exactly as `create` does — a restored machine is a
   * machine like any other, and one restored outside the network would be the
   * only unreachable one in the account.
   */
  restore(snapshotId: string, options?: RestoreOptions): Promise<VMHandle>;
  fork?(vmId: string): Promise<VMHandle>;

  // Session transports this driver supports. Undefined means the legacy set (`websocket`
  // and/or `ssh` via openAttach/openSSH). A driver that lists only `cmux-remote`
  // never serves openAttach: workflows fail such requests with
  // VmAttachTransportUnsupportedError before reaching the provider.
  readonly attachTransports?: readonly AttachTransport[];

  // Returns a live attach endpoint the client can dial into: cmuxd-remote WebSocket PTY
  // with a short-lived one-use lease, or SSH. Every current driver is cmux-remote only
  // and throws here; the seam stays for a provider that serves a raw PTY again.
  openAttach(vmId: string, options?: AttachOptions): Promise<AttachEndpoint>;

  // Optional: attach through the cmux-tui remote daemon in the VM (see CmuxRemoteEndpoint).
  // Every cmux Cloud machine runs this daemon; providers that have not been migrated
  // leave this undefined.
  openCmuxRemote?(vmId: string, options?: CmuxRemoteAttachOptions): Promise<CmuxRemoteEndpoint>;
  // Optional: approve the pending enrollment a previous openCmuxRemote invited.
  approveCmuxRemoteEnrollment?(
    vmId: string,
    invitationId: string,
    options?: CmuxRemoteApprovalOptions,
  ): Promise<CmuxRemoteApprovalResult>;

  // Returns a live SSH endpoint the client can dial into. Drivers are responsible for ensuring
  // sshd is running (some providers need an explicit start step).
  openSSH(vmId: string): Promise<SSHEndpoint>;

  // Best-effort revocation of an identity handle that `openSSH` previously returned. No-op
  // if the driver doesn't mint revocable credentials, must not throw on unknown
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
