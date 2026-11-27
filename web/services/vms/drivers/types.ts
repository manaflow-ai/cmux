// Unified driver contract over each VM provider. No cloudrouter, no shared base class — just
// per-provider implementations behind an interface. Callers hold a `VMProvider` and never reach
// into specifics.

import type { NetworkRulePlan } from "../networkPolicy";
import type { GuestPromptIdentity } from "../guestPrompt";

export type ProviderId = "freestyle" | "gcp";

const PROVIDER_IDS: readonly ProviderId[] = ["freestyle", "gcp"];

export function isProviderId(value: unknown): value is ProviderId {
  return typeof value === "string" && PROVIDER_IDS.includes(value as ProviderId);
}

export type VMStatus = "creating" | "running" | "paused" | "destroyed";

/**
 * Options for a provider read a route bounds (routeDeadline.ts). The driver
 * passes `signal` to every request the read makes, so no request outlives
 * the route's answer.
 */
export type ProviderReadOptions = {
  readonly signal?: AbortSignal;
  /** Short-lived user credential; never persist this in providerMetadata. */
  readonly credential?: ProviderCredential;
};

/**
 * A provider's raw pause state, see `VMProvider.getPauseState`. `stopped` is
 * a powered-off machine: not a finished pause (memory is gone) and not
 * pausable either (the provider refuses to pause it).
 */
export type VmPauseState = "paused" | "in_progress" | "not_paused" | "stopped" | "destroyed";

/// A point-in-time reading of one machine. Sleeping machines are never woken for a
/// reading: they report `asleep` with only their provisioned memory.
export type VMStats = {
  readonly state: "awake" | "asleep" | "unknown";
  /** Health of the guest reporter, independent of provider power state. */
  readonly health?: "healthy" | "unknown" | "unresponsive";
  readonly sampledAt: number;
  /** Timestamp of the latest guest reporter sample, even when it is stale. */
  readonly resourceSampledAt?: number;
  readonly cpus?: number;
  readonly cpuPercent?: number;
  readonly loadAverage1m?: number;
  readonly memoryTotalMb?: number;
  readonly memoryUsedMb?: number;
  readonly diskTotalMb?: number;
  readonly diskUsedMb?: number;
};

/** Validated guest gauges and their server observation time; never capacity. */
export type VMResourceStatsResult = Pick<VMStats, "cpuPercent" | "memoryUsedMb" | "diskUsedMb"> & {
  readonly resourceSampledAt: number;
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
  /** The image is a live machine snapshot (fork or checkpoint restore); create waits for this machine's own daemon. */
  forked?: boolean;
  /** Provider-enforced lifetime runtime allowance for this allocation. */
  runtimeBudgetSeconds?: number;
  /** Human-facing machine label; providers may ignore this cosmetic field. */
  displayName?: string;
  /** Current prompt name, written into the guest rather than a shell environment. */
  promptIdentity?: GuestPromptIdentity;
  providerMetadata?: Record<string, unknown>;
  /**
   * The billing customer (its team, or the user for a user-billed machine):
   * the provider's end-user customer, so its abuse protection tells our
   * customers apart.
   * Providers without customers ignore it.
   */
  customerId?: string;
  /**
   * A short-lived credential handed off by the user's local client. Providers
   * must use it only for this operation and never copy it to a VM row.
   */
  providerCredential?: ProviderCredential;
  /**
   * The workflow's durable record of the allocation. A driver whose cleanup
   * needs a short-lived user credential names its provider id with `record`
   * before it sends the allocation request (and must not allocate when that
   * rejects), so an interrupted create still leaves a row naming its instance.
   * It calls `released` once its own rollback confirmed the allocation gone.
   */
  createCleanupIntent?: {
    readonly record: (providerVmId: string) => Promise<void>;
    readonly released: () => void;
  };
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
   * Per-domain request headers the provider's TLS edge injects into every
   * request the guest makes to `domain` (the coderouter route token and the
   * VM id). Header values are secrets: drivers pass them to the provider's
   * create call only, never persist them, and never write them into the guest.
   * Providers without an injecting edge must refuse them rather than drop them.
   */
  edgeRules?: readonly VmEdgeRule[];
  /**
   * The owner's private network to attach the machine to. When present the
   * machine takes an address on it and its session daemon is reachable only
   * from other members — the owner's other machines, and the owner's computer
   * over its WireGuard tunnel — so the driver opens no public inbound port.
   * Providers without `privateNetworking` ignore it.
   */
  network?: ProviderNetworkRef;
  /**
   * Outbound rules compiled from the machine's network policy
   * (services/vms/networkPolicy.ts). Absent: full public egress, the
   * historical default. Providers without egress control must refuse a
   * restricted plan rather than silently leave the machine open.
   */
  networkRules?: NetworkRulePlan;
};

/** Enough of a provider network to attach a machine or a tunnel to it. */
export type ProviderNetworkRef = {
  readonly id: string;
  readonly memberIngress?: boolean;
};

export type VMFirewallEndpoint = {
  readonly vmId?: string;
  readonly vpcId?: string;
  readonly tunnelId?: string;
  readonly cidr?: string;
  readonly public?: true;
  readonly port?: number;
  readonly protocol?: "tcp" | "udp" | "icmp";
};

export type VMFirewallRule = {
  readonly id: string;
  readonly action: "allow";
  readonly source: VMFirewallEndpoint;
  readonly destination: VMFirewallEndpoint;
  readonly description?: string | null;
  readonly createdAt?: string;
  readonly updatedAt?: string;
};

export type VMFirewallRuleInput = {
  readonly source: VMFirewallEndpoint;
  readonly destination: VMFirewallEndpoint;
  readonly description?: string;
};

/** One edge header-injection rule; see CreateOptions.edgeRules. */
export type VmEdgeRule = {
  /** Exact host name the guest dials (no port, no scheme). */
  readonly domain: string;
  /** Headers the edge sets on every request to `domain`, overwriting the guest's. */
  readonly headers: Readonly<Record<string, string>>;
  /**
   * Where the edge connects for `domain` (port 443). Lets the guest dial one
   * fixed alias while each deployment routes it to its own API host. Absent:
   * the edge connects to `domain` itself.
   */
  readonly destinationHost?: string;
};

/** Create-time inputs a restore-from-snapshot shares with a fresh create. */
export type RestoreOptions = Pick<CreateOptions, "edgeRules" | "providerMetadata" | "networkRules" | "customerId"> & {
  /** The owner's private network; see {@link CreateOptions.network}. */
  network?: ProviderNetworkRef;
};

/** Private guest SSH, with the host key read through the authenticated provider API.
 * The client keeps its private key; only its public key reaches the control plane. */
export type SCPEndpoint = {
  host: string;
  port: number;
  username: string;
  hostPublicKey: string;
  expiresAtUnix: number;
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
  /** Provider-neutral dial metadata for clients that open a local proxy first. */
  proxy?: { readonly kind: "gcp-iap"; readonly project: string; readonly zone: string; readonly instance: string; readonly port: number };
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
  /** Compatibility mode: true only while this endpoint still relies on the
   * private network for carrier authentication. Grant-required endpoints are
   * false and carry a short-lived invitation below. */
  trustedCarrier: boolean;
  /** A short-lived cryptographic grant for a client not yet admitted. */
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
  /** Authoritative display name and revision, refreshed before returning the terminal. */
  promptIdentity?: GuestPromptIdentity;
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

export type VMFileEntry = {
  name: string;
  kind: "file" | "directory" | "symlink";
  size?: number;
  mode?: number;
  modifiedAt?: number;
};

export type VMFileContents = {
  path: string;
  data: Uint8Array;
  size: number;
};

export type VMFileStat = {
  path: string;
  kind: "file" | "directory" | "symlink";
  size?: number;
  mode?: number;
  modifiedAt?: number;
};

export type ExecOptions = {
  readonly timeoutMs?: number;
  /**
   * Run as root instead of the work user. Every exec ran as root before
   * public `vm exec` moved to the work user (#16769); cmux's own guest
   * maintenance that writes root-owned paths still needs it.
   */
  readonly asRoot?: boolean;
  /** Server-side metadata persisted with the VM row, used for durable-home routing. */
  readonly providerMetadata?: Record<string, unknown>;
  /**
   * Standard input of the command (cx-psxg: the acpmux person key). A driver
   * sends it only in the provider call itself, never in a backgrounded call
   * the provider stores, and never logs, traces or persists it.
   */
  readonly stdin?: SecretBytes;
  /** Ends the provider request: the driver passes it to every request it makes. */
  readonly signal?: AbortSignal;
  /**
   * Gateway only: abort the provider request (through `signal`) when the
   * calling fiber is interrupted, a timeout included. Without it an
   * interrupted exec's request runs on to its own end.
   */
  readonly cancelOnInterrupt?: boolean;
};

const REDACTED = "[redacted]";

/**
 * Bytes that are never logged, traced, serialized or stored (cx-psxg). JSON,
 * string conversion and Node's inspector print "[redacted]"; only
 * {@link SecretBytes.base64} gives the bytes, for the provider request.
 */
export class SecretBytes {
  #bytes: Uint8Array;
  #wiped = false;

  constructor(bytes: Uint8Array) {
    this.#bytes = bytes;
  }

  get byteLength(): number {
    return this.#bytes.byteLength;
  }

  /** The bytes as standard base64, for the provider request body only. */
  base64(): string {
    return Buffer.from(this.#bytes.buffer, this.#bytes.byteOffset, this.#bytes.byteLength).toString("base64");
  }

  /** The bytes as UTF-8 for a provider request or attach handoff only. */
  utf8(): string {
    return Buffer.from(this.#bytes.buffer, this.#bytes.byteOffset, this.#bytes.byteLength).toString("utf8");
  }

  /** Overwrites the bytes with zeros (the caller's buffer, which this object does not copy). */
  wipe(): void {
    this.#bytes.fill(0);
    this.#wiped = true;
  }

  /** True once {@link wipe} has run; a wiped secret must never be sent. */
  get wiped(): boolean {
    return this.#wiped;
  }

  toJSON(): string {
    return REDACTED;
  }

  toString(): string {
    return REDACTED;
  }

  [Symbol.for("nodejs.util.inspect.custom")](): string {
    return REDACTED;
  }
}

/**
 * A local-client credential for a user-owned provider. The server may hold
 * this object only for the current request. `SecretBytes` keeps accidental
 * traces, JSON responses, and error inspection redacted.
 */
export type ProviderCredential = {
  readonly provider: "gcp";
  readonly accessToken: SecretBytes;
  readonly expiresAtUnix: number;
  /** Public key is safe to send to Compute Engine instance metadata. */
  readonly sshPublicKey?: string;
  /** Private key is returned only to the caller's attach session. */
  readonly sshPrivateKeyPem?: SecretBytes;
  readonly sshUsername?: string;
  /** Aborted by {@link wipeProviderCredential}, cancelling in-flight provider requests. */
  readonly lifetime?: AbortController;
};

/** Zero-fills the credential's secrets. Safe to call more than once. */
export function wipeProviderCredential(credential: ProviderCredential | undefined): void {
  credential?.lifetime?.abort();
  credential?.accessToken.wipe();
  credential?.sshPrivateKeyPem?.wipe();
}

export type SnapshotRef = {
  id: string;
  createdAt: number;
  name?: string;
};

/** Grow-only resources accepted by a provider resize operation. */
export type VMResizeOptions = {
  readonly cpu?: number;
  readonly memoryMb?: number;
  readonly storageMb?: number;
};

/**
 * What a provider can actually do, so clients hide verbs that would only fail.
 * This is the client-visible provider contract: every VM API response carries
 * it, and the CLI/app gates verbs on it instead of assuming a provider name.
 */
export interface VmCapabilities {
  readonly snapshot: boolean;
  readonly restore: boolean;
  readonly fork: boolean;
  /** One-shot non-interactive command execution (`POST /api/vm/:id/exec`). */
  readonly exec: boolean;
  /** Live CPU/memory/disk readings (`GET /api/vm/:id/stats`). */
  readonly stats: boolean;
  /** Provider-level recovery for a frozen machine (`POST /api/vm/:id/restart`). */
  readonly restart: boolean;
  /** Token-gated HTTPS preview URLs for arbitrary VM ports (`POST /api/vm/:id/open-port`). */
  readonly ports: boolean;
  /** A desktop (VNC) image exists for this provider. */
  readonly desktop: boolean;
  /** `CreateOptions.memoryMb` is honored rather than ignored. */
  readonly sizing: boolean;
  /** `CreateOptions.homeVolume` is honored rather than ignored. */
  readonly persistentHome: boolean;
  /** Session transports the driver can hand out, in preference order. */
  readonly attachTransports: readonly AttachTransport[];
}

/** A private network that every machine belonging to one user shares. */
export type ProviderNetwork = {
  readonly id: string;
  readonly slug: string | null;
  /** IPv4 CIDR, when the network has one. */
  readonly cidr: string | null;
  /** IPv6 CIDR. Always present: provider networks are dual-stack. */
  readonly cidrV6: string | null;
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
  readonly attachments?: readonly ProviderTunnelAttachment[];
};

export type ProviderTunnelAttachment = {
  readonly networkId: string;
  readonly addressV4: string | null;
  readonly addressV6: string | null;
};

export class ProviderTunnelNetworkOverlapError extends Error {
  readonly kind = "network_overlap" as const;
}

/** Result of enrolling a tunnel, including whether provider state was recovered or rotated. */
export type ProviderTunnelCreateResult = {
  readonly tunnel: ProviderTunnel;
  readonly created: boolean;
  readonly rotated: boolean;
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
  ensureNetwork(options: EnsureProviderNetworkOptions): Promise<ProviderNetwork>;
  /** Read a network back by id or slug, or null when the provider has none. */
  getNetwork(networkIdOrSlug: string): Promise<ProviderNetwork | null>;
  /** Delete a network. Must succeed when it is already gone. */
  deleteNetwork(networkId: string): Promise<void>;
  /** Create a tunnel with the network already attached. */
  createTunnel(options: CreateProviderTunnelOptions): Promise<ProviderTunnelCreateResult>;
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
  attachTunnelNetwork?(tunnelId: string, networkId: string): Promise<ProviderTunnelAttachment>;
  detachTunnelNetwork?(tunnelId: string, networkId: string): Promise<void>;
  /** Ids of every tunnel attached to a network. */
  listNetworkTunnelIds?(networkId: string): Promise<string[]>;
  listFirewallRules?(options?: { vmId?: string; vpcId?: string; tunnelId?: string }): Promise<VMFirewallRule[]>;
  getFirewallRule?(ruleId: string): Promise<VMFirewallRule>;
  createFirewallRule?(options: VMFirewallRuleInput): Promise<VMFirewallRule>;
  deleteFirewallRule?(ruleId: string): Promise<void>;
}

export type EnsureProviderNetworkOptions = {
  readonly slug: string;
  readonly displayName?: string;
  readonly heal?: boolean;
  readonly membersRule?: boolean;
  /**
   * The IPv4 range for a network this call creates. Omitted means the
   * provider's default. It never changes an existing network: a provider
   * network's range is fixed for its life.
   */
  readonly cidr?: string;
  /** User-owned provider credential and placement for providers such as GCP. */
  readonly providerCredential?: ProviderCredential;
  readonly providerProject?: string;
  readonly providerRegion?: string;
};

export interface VMProvider {
  readonly id: ProviderId;

  /**
   * Per-owner private networks and the WireGuard tunnels into them. Undefined
   * on drivers whose machines are only reachable at a public address.
   */
  readonly privateNetworking?: VMPrivateNetworking;
  /** Set false when the provider provisions a VPC but has no tunnel/tailnet transport yet. */
  readonly privateNetworkingTunnels?: boolean;
  /**
   * Optional-operation support. A driver that implements `snapshot`/`restore` only to
   * throw NotImplementedError declares that here; `fork` defaults to whether the method
   * exists. Everything omitted defaults to supported.
   */
  readonly capabilities?: Partial<VmCapabilities>;

  create(options: CreateOptions): Promise<VMHandle>;
  /**
   * Delete the machine; a machine already gone counts as deleted. `strict`: only the provider's
   * own "no such machine" answer counts as gone (not any 404, which can be an endpoint error).
   */
  destroy(vmId: string, credential?: ProviderCredential, options?: { readonly strict?: boolean }): Promise<void>;

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
  /**
   * Optional account-wide, read-only inventory for the staff health sweep. It
   * covers every VM and TLS rule on the provider account, not only cmux rows.
   */
  readonly healthInventory?: VmHealthInventory;

  getStatus?(vmId: string, options?: ProviderReadOptions): Promise<VMStatus>;
  /**
   * Whether the machine is paused at the provider, still moving between
   * states (`in_progress`, e.g. Freestyle `pausing` or `starting`), or
   * neither. Unlike {@link getStatus} this never folds a transition or a
   * powered-off machine into `paused`; pause retries reconcile on it.
   */
  getPauseState?(vmId: string, credential?: ProviderCredential): Promise<VmPauseState>;
  /// Live CPU/memory/disk for the Cloud panel's activity view. Must not wake a
  /// sleeping machine.
  getStats?(vmId: string, options?: ProviderReadOptions): Promise<VMStats>;
  /** Optional direct guest probe; must not install tooling, mutate, or wake. */
  getResourceStats?(vmId: string): Promise<VMResourceStatsResult | null>;
  /** Force a provider-level reboot without using the guest exec channel. */
  restart?(vmId: string): Promise<void>;
  /** Grow one or more VM resources. Freestyle currently uses storage only. */
  resize?(vmId: string, options: VMResizeOptions): Promise<void>;
  /** Converge a live machine's outbound rules on `plan`. Must not restart or wake it. */
  applyNetworkPolicy?(vmId: string, plan: NetworkRulePlan): Promise<void>;

  pause(vmId: string, credential?: ProviderCredential): Promise<void>;
  resume(vmId: string, credential?: ProviderCredential): Promise<VMHandle>;
  setRuntimeBudget?(vmId: string, remainingSeconds: number | null): Promise<void>;

  exec(vmId: string, command: string, opts?: ExecOptions): Promise<ExecResult>;

  /** Backend-wrapped guest filesystem operations. Paths are validated by the route and driver. */
  listFiles?(vmId: string, path: string, options?: ProviderReadOptions): Promise<VMFileEntry[]>;
  readFile?(vmId: string, path: string, options?: ProviderReadOptions): Promise<VMFileContents>;
  writeFile?(vmId: string, path: string, data: Uint8Array, mode?: number): Promise<void>;
  makeDirectory?(vmId: string, path: string): Promise<void>;
  removeFile?(vmId: string, path: string): Promise<void>;
  statFile?(vmId: string, path: string, options?: ProviderReadOptions): Promise<VMFileStat>;

  // Optional: mint a private, token-gated HTTPS preview URL for an arbitrary HTTP port on the
  // VM (the exe.dev "https://vmname.exe.xyz:3456" equivalent). openUrl embeds the token as a
  // query parameter for direct browser use.
  openPort?(vmId: string, port: number): Promise<{ url: string; token: string; openUrl: string; expiresAtMs?: number }>;

  snapshot(vmId: string, name?: string): Promise<SnapshotRef>;
  /**
   * Optional: every snapshot taken from `vmId`, newest first. Absent on a
   * provider that cannot enumerate snapshots; the gateway answers unsupported.
   */
  listSnapshots?(vmId: string, options?: ProviderReadOptions): Promise<SnapshotRef[]>;
  /**
   * Optional: delete one snapshot taken from `vmId`. A snapshot that does not
   * exist or was taken from another machine fails with an error
   * `isProviderNotFoundError` recognizes, so the workflow answers not-found
   * rather than deleting across machines.
   */
  deleteSnapshot?(vmId: string, snapshotId: string): Promise<void>;
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

  // Optional: a live attach endpoint the client can dial into — a cmuxd-remote WebSocket
  // PTY with a short-lived one-use lease. A driver only implements this when it lists
  // `websocket` in attachTransports; workflows refuse the transport before reaching a
  // driver that omits it.
  openAttach?(vmId: string, options?: AttachOptions): Promise<AttachEndpoint>;

  // Optional: attach through the cmux-tui remote daemon in the VM (see CmuxRemoteEndpoint).
  // Every cmux Cloud machine runs this daemon; providers that have not been migrated
  // leave this undefined.
  openCmuxRemote?(vmId: string, options?: CmuxRemoteAttachOptions): Promise<CmuxRemoteEndpoint>;
  // Optional, compatibility only: the trusted listener needs no approval, so a
  // provider answers `approved` without touching the machine. Older Mac builds
  // still call it once after their first connect.
  approveCmuxRemoteEnrollment?(
    vmId: string,
    invitationId: string,
    options?: CmuxRemoteApprovalOptions,
  ): Promise<CmuxRemoteApprovalResult>;

  // Optional: a live SSH endpoint the client can dial into. Drivers are responsible for
  // ensuring sshd is running (some providers need an explicit start step). Only drivers
  // listing `ssh` in attachTransports implement this.
  openSSH?(vmId: string, credential?: ProviderCredential): Promise<SSHEndpoint>;
  prepareSCP?(vmId: string, publicKey: string): Promise<SCPEndpoint>;

  // Best-effort revocation of an identity handle that `openSSH` previously returned. No-op
  // if the driver doesn't mint revocable credentials, must not throw on unknown
  // or already-revoked handles. Cleanup paths rely on it being safe to call.
  revokeSSHIdentity?(identityHandle: string): Promise<void>;

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

/**
 * A machine that can never be attached as it is: it was created before the
 * attach contract the server now requires, and nothing on the server changes
 * that. Routes answer with a non-retryable recreate action, never a retryable
 * outage; see docs/cloud-guest-upgrades.md.
 */
/**
 * A provider read did not answer within the route's budget and was aborted
 * (routeDeadline.ts). Routes answer 504 vm_provider_timeout.
 */
export class ProviderReadDeadlineError extends ProviderError {
  constructor(provider: ProviderId, operation: string, readonly waitedMs: number) {
    super(provider, `${operation} did not answer within ${Math.round(waitedMs)} ms`);
    this.name = "ProviderReadDeadlineError";
  }
}

export class ProviderMachineRecreateRequiredError extends ProviderError {
  constructor(provider: ProviderId, message: string) {
    super(provider, message);
    this.name = "ProviderMachineRecreateRequiredError";
  }
}

/**
 * The machine is in a state the operation cannot run in (still starting,
 * pausing, or not running). Routes answer 409 vm_state_conflict with a
 * wait-and-retry action, never a generic outage.
 */
export class ProviderStateConflictError extends ProviderError {
  constructor(provider: ProviderId, message: string, cause?: unknown) {
    super(provider, message, cause);
    this.name = "ProviderStateConflictError";
  }
}

/** How a provider's 409 answer reads: no room for the machine, a machine-state conflict, or an unresponsive guest. */
export type ProviderConflictKind = "capacity" | "state" | "unresponsive";

/**
 * Classifies a provider failure that is a 409 refusal. The first error in the
 * cause chain that carries an HTTP status decides; it must be 409. Freestyle
 * answers capacity as `CONFLICT` "no manager has enough capacity" or
 * `PLACEMENT_REJECTED`, an unresponsive guest as `VM_NON_RESPONSIVE`, and a
 * machine in the wrong state (still starting, not running) as `CONFLICT`.
 * Every other status, any other 409, and a 409 that never reached the
 * provider is null.
 */
/** Freestyle's placement refusal: "no manager has enough capacity for vm". */
const PROVIDER_CAPACITY_MESSAGE = /\bno manager has enough capacity\b/i;

/** Freestyle 409 messages about the machine's lifecycle state. */
const PROVIDER_STATE_CONFLICT_MESSAGE = /\b(?:is )?still (?:starting|stopping|pausing|resuming|suspending|booting)\b|\bis not running\b|\bis (?:paused|pausing|suspended|suspending|stopped|stopping|starting|resuming)\b|\bresuming state\b/i;

export function providerConflictKind(err: unknown): ProviderConflictKind | null {
  let current = err;
  for (let depth = 0; depth < 8 && current; depth += 1) {
    if (current instanceof ProviderStateConflictError) return "state";
    if (typeof current !== "object") return null;
    const record = current as { status?: unknown; code?: unknown; message?: unknown; body?: { code?: unknown; message?: unknown }; cause?: unknown };
    if (typeof record.status === "number") {
      if (record.status !== 409) return null;
      const code = typeof record.code === "string" ? record.code : typeof record.body?.code === "string" ? record.body.code : "";
      const message = typeof record.message === "string" ? record.message : typeof record.body?.message === "string" ? record.body.message : "";
      if (code === "PLACEMENT_REJECTED" || PROVIDER_CAPACITY_MESSAGE.test(message)) return "capacity";
      if (code === "VM_NON_RESPONSIVE") return "unresponsive";
      // Only a message that names the machine's state is a state conflict.
      // Every other 409 (network policy, slug, tunnel, port, snapshot in use,
      // quota) is a real resource conflict and keeps the generic answer.
      return PROVIDER_STATE_CONFLICT_MESSAGE.test(message) ? "state" : null;
    }
    current = record.cause;
  }
  return null;
}

/**
 * A guest command the server needed never ran or never exited: the provider's
 * exec channel failed, or the command outlived its timeout. Nothing about the
 * service the command would have checked is known, so routes name the machine
 * as unresponsive and give a restart action, never a generic outage.
 */
export class ProviderGuestUnresponsiveError extends ProviderError {
  constructor(provider: ProviderId, message: string, cause?: unknown) {
    super(provider, message, cause);
    this.name = "ProviderGuestUnresponsiveError";
  }
}

/**
 * The owner's private network has no free address for another member. It
 * stays full until machines are deleted or computers are revoked, so routes
 * answer with a non-retryable cleanup action, never a retryable outage.
 */
export class ProviderNetworkFullError extends ProviderError {
  constructor(provider: ProviderId, message: string, cause?: unknown) {
    super(provider, message, cause);
    this.name = "ProviderNetworkFullError";
  }
}

/**
 * The provider account holds its maximum number of TLS rules. The cap is
 * account-wide, so the user cannot free it and an immediate retry cannot
 * succeed; routes answer with a capacity refusal and operators are alerted.
 */
export class ProviderTlsRuleLimitError extends ProviderError {
  constructor(provider: ProviderId, message: string, cause?: unknown) {
    super(provider, message, cause);
    this.name = "ProviderTlsRuleLimitError";
  }
}

/** True when `err` or one of its causes is a {@link ProviderGuestUnresponsiveError}. */
export function hasProviderGuestUnresponsiveCause(err: unknown): boolean {
  let current = err;
  for (let depth = 0; depth < 8 && current; depth += 1) {
    if (current instanceof ProviderGuestUnresponsiveError) return true;
    current = typeof current === "object" ? (current as { cause?: unknown }).cause : undefined;
  }
  return false;
}

/**
 * True when a provider failure says the call was never answered, not that it
 * was refused: a stuck guest ({@link ProviderGuestUnresponsiveError}), a
 * client timeout or abort, a gateway 502/504 (a background request polled
 * past its limit), or the provider's VM_NON_RESPONSIVE. The first error in
 * the chain that carries an HTTP status decides, so an early 401/403/404/429
 * or another 5xx is a refusal. A hung call may still complete at the provider.
 */
export function isProviderHangCause(err: unknown): boolean {
  let current = err;
  for (let depth = 0; depth < 8 && current; depth += 1) {
    if (current instanceof ProviderGuestUnresponsiveError) return true;
    if (typeof current !== "object") return false;
    const record = current as { status?: unknown; code?: unknown; name?: unknown; cause?: unknown };
    if (typeof record.status === "number") {
      return record.status === 502 || record.status === 504 || record.code === "VM_NON_RESPONSIVE";
    }
    if (record.name === "TimeoutError" || record.name === "AbortError") return true;
    current = record.cause;
  }
  return false;
}

/** Whether `err` or anything in its cause chain is a {@link ProviderTlsRuleLimitError}. */
export function hasProviderTlsRuleLimitCause(err: unknown): boolean {
  let current = err;
  for (let depth = 0; depth < 8 && current; depth += 1) {
    if (current instanceof ProviderTlsRuleLimitError) return true;
    current = typeof current === "object" ? (current as { cause?: unknown }).cause : undefined;
  }
  return false;
}

/** An unpublished runtime artifact; diagnostics stay server-side while routes localize the failure. */
export class ProviderArtifactUnavailableError extends ProviderError {
  constructor(provider: ProviderId, diagnostic: { readonly manifestUrl: string; readonly target: string }) {
    super(provider, "vm_artifact_unavailable", diagnostic);
    this.name = "ProviderArtifactUnavailableError";
  }
}

/**
 * Read-only account inventory for the staff Cloud VM health sweep. No member
 * may start, pause, update, or delete anything.
 */
export type VmHealthInventory = {
  listAccountVms(options: { readonly deadlineAtMs: number; readonly signal?: AbortSignal }): Promise<import("../health/types").ProviderVmInventory>;
  listAccountTlsRules(options: { readonly deadlineAtMs: number; readonly signal?: AbortSignal }): Promise<import("../health/types").ProviderTlsRuleInventory>;
  /** One bounded control-path request against a running VM; never wakes a paused one on purpose. */
  probeControl(vmId: string, options: { readonly timeoutMs: number; readonly signal?: AbortSignal }): Promise<import("../health/types").VmControlProbe>;
};
