import {
  Freestyle,
  FreestyleApiError,
  type ResizeVmOptions,
  type TunnelData,
  type VmData,
  type Vm,
  type VpcData,
  type SnapshotData,
} from "freestyle";

import { randomBytes } from "node:crypto";
import type { NetworkRulePlan } from "../networkPolicy";
import { FreestyleTlsRuleLimitRestoreError, inlineEgressFirewallRules, inlineEgressTlsRules, isFreestyleTlsRuleLimit, reconcileFreestyleEgress } from "./freestyleNetworkPolicy";
import { isIP } from "node:net";
import { Effect } from "effect";
import { FreestyleResourceStatsReader } from "./freestyleResourceStatsReader";
import { freestyleCustomer } from "./freestyleCustomer";
import { freestyleHealthInventory } from "./freestyleHealthInventory";
import { announceFreestyleNetwork } from "./freestyleNetworkAnnouncement";
import { freestyleRequestFetch } from "./freestyleRequestTiming";
import { currentVmRequestContext } from "../requestContext";
import {
  ProviderError,
  ProviderGuestUnresponsiveError,
  isProviderHangCause,
  ProviderMachineRecreateRequiredError,
  ProviderNetworkFullError,
  ProviderTlsRuleLimitError,
  type AttachTransport,
  type ProviderCredential,
  type SSHEndpoint,
  type CmuxRemoteApprovalResult,
  type CmuxRemoteApprovalOptions,
  type CmuxRemoteAttachOptions,
  type CmuxRemoteEndpoint,
  type CreateOptions,
  type CreateProviderTunnelOptions,
  type EnsureProviderNetworkOptions,
  type ExecOptions,
  type ExecResult,
  type VMFileContents,
  type VMFileEntry,
  type VMFileStat,
  type VMFirewallRule,
  type VMFirewallRuleInput,
  type ProviderNetwork,
  type ProviderTunnel,
  type ProviderTunnelAttachment,
  ProviderTunnelNetworkOverlapError,
  type ProviderTunnelCreateResult,
  type RestoreOptions,
  type SecretBytes,
  type SnapshotRef,
  type VmEdgeRule,
  type VMHandle,
  type VMPrivateNetworking,
  type VMProvider,
  type VMResizeOptions,
  type VMStats,
  type VMResourceStatsResult,
  type VMStatus,
  type ProviderReadOptions,
  type VmPauseState,
  type VmHealthInventory,
} from "./types";
import {
  DEVBOX_DESKTOP_NOVNC_PORT,
  DEVBOX_DESKTOP_START_SCRIPT,
  DEVBOX_DESKTOP_UNIT,
  devboxDesktopOpenUrl,
} from "../images/desktop";
import {
  DESKTOP_TRANSPORT_ENV,
  type DesktopTransport,
  desktopEndpoint,
  desktopListenPort,
  desktopReadyProbe,
  resolveDesktopTransport,
} from "../images/desktopTransport";
import { devboxForkDaemonReadyCommand, devboxForkReadinessStage } from "../images/remoteState";
import { recordSpanError, setSpanAttributes, withVmSpan } from "../telemetry";
import { VM_PROVIDER_CREATE_TIMEOUT_MS } from "../operationTimeouts";
import { parseSshPublicKey, scpPrepareCommand, SCP_KEY_TTL_SECONDS } from "./scp";
import {
  CMUX_TUI_PORT,
  CMUX_TUI_SESSION,
  approveCmuxTuiEnrollment,
  cmuxTuiRunCommand,
  mintCmuxTuiInvitation,
  type CmuxTuiCommandRunner,
  type CmuxTuiInvoke,
} from "./cmuxTuiDaemon";
import { cloudClientGrantRequired } from "../clientGrant";
import { cloudRemoteAuthMode } from "../clientGrant";
import { findVmImageManifestEntry } from "../images/resolver";
export { preconnectFreestyle } from "./freestyleWarmup";
export type { FreestylePreconnectOptions } from "./freestyleWarmup";

function freestyleRemoteAuthPlan(
  metadata: Record<string, unknown> | undefined,
  deviceFingerprint: string | undefined,
): { readonly fingerprint?: string; readonly mintInvitation: boolean; readonly trustedCarrier: boolean } {
  const authMode = cloudRemoteAuthMode(metadata);
  const fingerprint = deviceFingerprint?.trim() || undefined;
  return {
    ...(fingerprint ? { fingerprint } : {}),
    mintInvitation: fingerprint === undefined &&
      (authMode === "client-grant" || cloudClientGrantRequired()),
    trustedCarrier: authMode === "trusted-carrier" && fingerprint === undefined,
  };
}

async function freestyleInvitationForAuth(
  auth: ReturnType<typeof freestyleRemoteAuthPlan>,
  mint: () => Promise<NonNullable<CmuxRemoteEndpoint["invitation"]>>,
  vmId: string,
): Promise<CmuxRemoteEndpoint["invitation"] | undefined> {
  if (!auth.mintInvitation) return undefined;
  try {
    return await mint();
  } catch (error) {
    if (!auth.trustedCarrier) throw error;
    // The old listener remains an authenticated compatibility path. Never log
    // the provider error: it may include guest output from invitation minting.
    console.warn(`[freestyle] enrollment invitation unavailable on trusted-carrier VM ${vmId}; using compatibility auth`);
    return undefined;
  }
}

// The Freestyle driver, on the public platform (api.freestyle.sh /v5, SDK
// freestyle@0.2.x). This is the only Freestyle arm: the legacy 0.1.x platform
// (SSH gateway, cmuxd-remote WebSocket PTY on 7777) has been removed,
// so every Freestyle machine now attaches the same way every other cmux Cloud
// machine does.
//
// Machines attach through the cmux-tui remote daemon (transport `cmux-remote`,
// docs/cloud-cmux-tui-daemon.md). The API has
// no HTTP ingress proxy to arbitrary VM ports (TLS edge rules need a
// customer-verified domain), so the route addresses the daemon directly.
//
// Every machine joins the one VPC that belongs to its owner, and the owner's
// Mac joins the same VPC over a WireGuard tunnel, so the route is the VM's
// *private* address: `ws://[<vpc ipv6>]:1337/v1/link`. Nothing on that path is
// public — the machine opens no inbound port at all, and a caller with no
// tunnel up simply cannot reach it. Machines created before private networking
// (and any created while CMUX_VM_PRIVATE_NETWORK_ENABLED=0 rolls it back) keep
// the older posture: inbound 1337 open to the Internet and the route pointed at
// the stable public IPv6. Which posture a machine has is read from the machine
// itself, never from the flag, so a rollback cannot strand a machine that is
// already on a network.
//
// The daemon's Noise handshake encrypts and authenticates the session end to
// end either way (carrier TLS is not required and the route token only feeds
// the lease ledger). The daemon must bind dual-stack: the baked systemd unit
// sets CMUX_TUI_REMOTE_WS_BIND=[::]:1337, which is also what makes a VPC
// address reachable, since it is neither loopback nor the public NIC. The
// driver never re-asserts it; a wrong bind is an image bug, fixed by a rebake.
//
// Creates take NO ports field, NO create-time env, and NO systemd injection;
// `firewall` is mandatory. The model-plane env is baked into the snapshot at
// /etc/cmux/model-plane.env (services/coderouter/vmGuestEnv.ts): the same
// bytes for every machine, so create writes nothing into the guest, and
// /etc/cmux/agent-config.sh sources it in every shell whatever user it runs as.
//
// Create runs no guest bootstrap. The devbox snapshot carries the pinned
// cmux-tui build, guest CLI integration, resource reporter, prompt sync, and
// cmux-tui-daemon systemd unit. Its supervisor starts the daemon with a fresh
// identity as soon as the machine resumes, keyed on the platform instance id.
// Create and an already-enrolled attach use provider metadata and the immutable
// image contract with no guest exec or filesystem upload. A first grant attach
// performs only the bounded invitation-mint/approval guest calls.
//
// NO-WORK INVARIANT (read before adding a provider call to create, restore, or
// resume). These paths are on the user's New Machine critical path, and every
// provider round trip here is paid on every create:
//   - create: one `vms.create` with VPC and TLS rules inline. No resize (each
//     size has its own snapshot), no `vm.exec`, no `vm.fs` write, no
//     readiness poll, no second provider read.
//   - restore/resume: no guest exec; the baked supervisor owns the daemon.
//   - openCmuxRemote: providerMetadata chooses the immutable auth mode. A
//     remembered enrolled fingerprint is exec-free; a first client may mint
//     one five-minute invitation and approve its exact pending claim. It never
//     installs, heals or restarts the daemon.
// If the guest needs a new binary, file, hook, package, or setting, bake it
// into the devbox snapshot (web/scripts/build-devbox-freestyle.ts, the boot
// supervisor in services/vms/images/devbox/cmux-devbox-boot) and bump
// images/manifest.json. If it needs per-machine identity, derive it in the
// guest at boot from the platform instance id, or fetch it asynchronously
// from the guest (cmux-prompt-sync) without gating terminal access. Rows
// without `cmuxTuiContract: "snapshot-v2"` are refused; do not reintroduce
// create- or attach-time healing to support them. Running machines are
// brought onto the contract out of band instead (an in-place cmux-tui upgrade
// plus a guarded backfill): docs/cloud-guest-upgrades.md.
// Explicit user operations (`exec`, `resize`, file push/pull) are separate
// and stay. The one sanctioned guest exec around create is the prompt-name
// push in workflows.ts (schedulePromptIdentityPush): display-only, run after
// the response, never awaited by create. Do not add anything else to it.
// Attach has one opt-in counterpart: a machine with agentUpdates "latest"
// gets the coding-agent updater exec (scheduleGuestAgentUpdates in
// workflows.ts), also after the response and never awaited by attach.
//
// The coderouter model plane is edge-injected: the create carries an inline
// `tls` rule for the coderouter host whose transform overwrites the signed
// `x-cmux-authorization` plus compatibility bearer/VM headers on every request
// the guest makes there. The platform steers the host to its edge (/etc/hosts) and
// installs its CA at boot; rules added after boot never reach a running
// guest, so the rule must be inline. The baked env file holds only base
// URLs and placeholder keys: no token is ever written into the guest, and
// create runs no exec and writes no file there (vms.create and a delete on
// rollback are its only provider calls). Injection
// becomes active 20-30 s after boot; the first agent request before that
// reaches the origin without the header and is rejected, then succeeds.
//
// The desktop and forwarded ports (`openPort`) travel the same private path
// as the daemon: the URL is the machine's VPC address, reachable only through
// the owner's tunnel, and the platform is never asked for a public ingress.
// The devbox desktop serves noVNC on 6901 with no VNC-level auth (the
// network is the gate, exactly as it is for the daemon port), so a machine
// that is not on a private network gets no desktop URL at all rather than a
// public one.

export const FREESTYLE_REMOTE_WS_BIND = `[::]:${CMUX_TUI_PORT}`;
/** The lease ledger's record of a port open; the private address itself never expires. */
export const PORT_OPEN_LEASE_TTL_SECONDS = 7 * 24 * 60 * 60;
/** Bounds the blocking `systemctl start` of the desktop unit (its own TimeoutStartSec is 120 s). */
const DESKTOP_HEAL_TIMEOUT_MS = 90_000;
export const FREESTYLE_ATTACH_TRANSPORT: AttachTransport = "cmux-remote";
/** The cmux devbox work user (uid 1000); scoped SSH identities may act only as it. */
export const FREESTYLE_WORK_LINUX_USER = "cmux";
/** Freestyle's SSH proxy: `ssh <vm>+<user>@host`, the identity token as the password. */
export const FREESTYLE_SSH_PROXY_HOST = "beta-ssh.freestyle.sh";
/**
 * Every guest command the driver runs is administrative — systemd, sudoers, the
 * daemon install — so it runs as root. The 0.2 API's `linuxUser` default is
 * "the account holding uid 1000, or root in an image with no such account",
 * which on a cmux devbox image is the work user; leaving this off would run
 * the driver's own maintenance unprivileged. Sessions are a different thing:
 * the daemon drops to the work user itself (cmuxTuiLayoutSelector).
 */
const GUEST_LINUX_USER = "root";

const DEFAULT_TIMEOUT_MS = 60_000;
const CREATE_TIMEOUT_MS = VM_PROVIDER_CREATE_TIMEOUT_MS;
const SNAPSHOT_TIMEOUT_MS = VM_PROVIDER_CREATE_TIMEOUT_MS;
/** Page size and ceiling for `listSnapshots`; a machine rarely has more than a handful. */
const SNAPSHOT_LIST_PAGE = 100;
const SNAPSHOT_LIST_MAX = 1_000;
const EXEC_DEFAULT_TIMEOUT_MS = 30_000;
/**
 * The SCP setup command (start sshd, authorize a key, read the host key)
 * finishes in well under a second on a healthy guest. Its exec is bounded
 * well inside the route's answer budget (SCP_ANSWER_BUDGET_MS).
 */
const SCP_PREPARE_EXEC_TIMEOUT_MS = 20_000;
/** Cloud machines are durable boxes; only an explicit pause/stop should put one to sleep. */
export const FREESTYLE_PERSISTENT_IDLE_TIMEOUT_SECONDS = -1;
/** The exec API rejects timeoutMs above 300000 (5 minutes per exec). */
const MAX_EXEC_TIMEOUT_MS = 300_000;
const EXEC_OVERHEAD_TIMEOUT_MS = 15_000;
const FORK_DAEMON_LISTEN_TIMEOUT_SECONDS = 30;
const ROUTE_TOKEN_TTL_SECONDS = 12 * 60 * 60;
const EDGE_DOMAIN = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/i;

/**
 * The seam tests replace: the SDK client. There is deliberately no daemon
 * manifest resolver here; the driver never installs or repairs cmux-tui (the
 * snapshot owns it, see NO-WORK INVARIANT above).
 */
export type FreestyleProviderDependencies = {
  /** `signal` aborts every request of a bounded read (an uncached client). */
  readonly client: (timeoutMs?: number, signal?: AbortSignal) => Freestyle;
  /**
   * The desktop transport (images/desktopTransport.ts). Absent: read once from
   * `CMUX_VM_DESKTOP_TRANSPORT` at construction; anything but `screen` is noVNC.
   */
  readonly desktopTransport?: DesktopTransport;
};

const FREESTYLE_CLIENT_CACHE_LIMIT = 8;

const globalForFreestyle = globalThis as typeof globalThis & {
  __cmuxFreestyleClients?: Map<string, Freestyle>;
};

/**
 * FREESTYLE_API_URL stays as an operator escape hatch (a staging edge); unset,
 * the SDK's own default — the public api.freestyle.sh — is used. The
 * stack-token pair mirrors build-devbox-freestyle.ts for interactive use.
 */
/**
 * Open the TCP+TLS connection to the Freestyle API before it is needed. The
 * first Freestyle call of a function invocation paid about 130 ms of DNS, TCP,
 * and TLS in production (vpc.get: 150 ms from pdx1, 12 ms warm); a route fires
 * this while it is still verifying the caller so the real call finds the
 * connection in undici's pool. Concurrent route requests share one in-flight
 * warm-up, and a failed probe is best-effort so provider errors remain typed.
 */
/** Exported for the publication provider, which shares this account-wide client. */
export function freestyleClient(timeoutMs = DEFAULT_TIMEOUT_MS, signal?: AbortSignal): Freestyle {
  // A bounded read's own client: its requests end when the route answers, so
  // it belongs to that read and is never cached.
  if (signal) return buildFreestyleClient(timeoutMs, signal);
  const cacheKey = `${freestyleApiBaseUrl() ?? "https://api.freestyle.sh"}|${freestyleCredentialKind()}|${timeoutMs}`;
  const clients = globalForFreestyle.__cmuxFreestyleClients ??= new Map<string, Freestyle>();
  const cached = clients.get(cacheKey);
  if (cached) return cached;
  const client = buildFreestyleClient(timeoutMs);
  // Exec accepts a caller-selected timeout; bound the account-wide wrapper
  // cache so arbitrary timeout values cannot retain clients indefinitely.
  if (clients.size >= FREESTYLE_CLIENT_CACHE_LIMIT) {
    const oldest = clients.keys().next().value;
    if (oldest !== undefined) clients.delete(oldest);
  }
  clients.set(cacheKey, client);
  return client;
}

function freestyleApiBaseUrl(): string | undefined {
  return process.env.FREESTYLE_API_URL?.trim() || undefined;
}

function freestyleCredentialKind(): "api-key" | "stack" | "missing" {
  if (process.env.FREESTYLE_API_KEY?.trim()) return "api-key";
  return process.env.FREESTYLE_STACK_ACCESS_TOKEN?.trim() && process.env.FREESTYLE_TEAM_ID?.trim() ? "stack" : "missing";
}

function buildFreestyleClient(timeoutMs: number, signal?: AbortSignal): Freestyle {
  const baseUrl = freestyleApiBaseUrl();
  const apiKey = process.env.FREESTYLE_API_KEY?.trim();
  const stackAccessToken = process.env.FREESTYLE_STACK_ACCESS_TOKEN?.trim();
  const teamId = process.env.FREESTYLE_TEAM_ID?.trim();
  const longFetch = freestyleRequestFetch({
    timeoutMs,
    ...(signal ? { signal } : {}),
    record: process.env.NODE_ENV === "development" ? (event) => {
      const traceId = currentVmRequestContext()?.traceId;
      console.info("cmux.vm.freestyle.request", JSON.stringify({
        ...event, traceId: traceId && /^[0-9a-f]{32}$/.test(traceId) ? traceId : undefined,
      }));
    } : undefined,
  });
  if (apiKey) return new Freestyle({ apiKey, baseUrl, fetch: longFetch });
  if (stackAccessToken && teamId) return new Freestyle({ stackAccessToken, teamId, baseUrl, fetch: longFetch });
  throw new ProviderError(
    "freestyle",
    "freestyle requires FREESTYLE_API_KEY (or FREESTYLE_STACK_ACCESS_TOKEN + FREESTYLE_TEAM_ID)",
  );
}

/**
 * The machine's own rules. The mandatory `firewall` field defaults to NOTHING —
 * no outbound, no inbound — so every rule is stated here.
 *
 * Outbound follows the machine's network policy (freestyleNetworkPolicy.ts);
 * without one it is the whole public Internet, the historical default. Inbound:
 *
 * - On a machine attached to its owner's VPC, **no inbound rule is written at
 *   all**. Reaching the daemon is admitted by the VPC's own members-reach-each-
 *   other rule (see `FREESTYLE_NETWORK_FIREWALL_RULES`), which covers the
 *   owner's other machines and the owner's attached tunnel and nothing else.
 *   Opening 1337 to the Internet as well would hand back exactly the exposure
 *   the VPC exists to remove.
 * - Without a VPC — a machine created before private networking, or one
 *   created while CMUX_VM_PRIVATE_NETWORK_ENABLED=0 rolls the feature back —
 *   inbound 1337 is opened publicly, because that is the only way such a
 *   machine is reachable at all. Session auth is the daemon's Noise device
 *   enrollment, the same posture the e2b driver builds by hand with iptables.
 */
export function freestyleFirewallRules(options?: {
  publicDaemonIngress?: boolean;
  memberIngressNetworkId?: string;
  networkRules?: NetworkRulePlan;
}) {
  const rules: Array<{
    action: "allow";
    source: { public?: true; vpcId?: string };
    destination: { public?: true; cidr?: string; port?: number; protocol?: "tcp" | "udp" };
    description?: string;
  }> = options?.networkRules
    ? inlineEgressFirewallRules(options.networkRules)
    : [{ action: "allow", source: {}, destination: { public: true } }];
  if (options?.publicDaemonIngress) {
    rules.push({
      action: "allow",
      source: { public: true },
      destination: { port: CMUX_TUI_PORT, protocol: "tcp" },
    });
  }
  if (options?.memberIngressNetworkId) {
    rules.push({ action: "allow", source: { vpcId: options.memberIngressNetworkId }, destination: {} });
  }
  return rules;
}

/**
 * The rules created with an owner's VPC and deleted with it: members reach each
 * other, and nothing else is implied. An attached tunnel counts as a member, so
 * this one rule is what admits the owner's Mac to their machines' daemon port.
 *
 * Machines still state their own outbound rule; a network rule cannot grant it,
 * because a bare endpoint inside a network's `firewall` block means the network
 * being created rather than the Internet.
 */
export const FREESTYLE_NETWORK_FIREWALL_RULES = [
  { action: "allow" as const, source: {}, destination: {} },
];

/** The addresses a route can be built from — the shape `vm.data()` returns. */
export type FreestyleRouteAddresses = {
  readonly publicIpv6?: string | null;
  readonly vpcs?: readonly FreestyleNetworkAddress[] | null;
  /** The deprecated alias for `vpcs`; read when an older response omits it. */
  readonly networks?: readonly FreestyleNetworkAddress[] | null;
};

type FreestyleNetworkAddress = {
  readonly ipv4?: string | null;
  readonly ipv6?: string | null;
};

/**
 * Where to dial the machine's daemon: its private VPC address when it has one,
 * otherwise its stable public IPv6.
 *
 * Private wins unconditionally, and deliberately never falls back: a machine on
 * a VPC has no public inbound rule, so a public route for it would not be a
 * degraded path but a guaranteed timeout with a misleading address in the
 * error.
 *

 * Within the network, IPv4 is preferred, because only the v4 path is reliable
 * over the WireGuard tunnel. The tunnel routes the VPC's v4 prefix as a subnet,
 * so it reaches any member the moment that member exists; its v6 path does not
 * pick up members created after the tunnel came up. A VM created into an
 * established tunnel therefore answers on its private v4 and blackholes on its
 * private v6 from the same Mac, while both work VM-to-VM inside the VPC. With
 * v6 first, every freshly created machine spent the full 60s connect timeout
 * and surfaced as "Command timed out"; only machines predating the tunnel
 * connected. Preferring v4 also matches the app's own `preferredPrivateAddress`
 * (v4 then v6), so the address a person copies from the sidebar is the address
 * the daemon is dialed on. The public fallback below stays v6 — Freestyle
 * allocates no public v4 at all.
 */
export function freestyleCmuxRemoteRoute(addresses: FreestyleRouteAddresses, vmId: string): string {
  const networks = addresses.vpcs ?? addresses.networks ?? [];
  for (const network of networks) {
    const ipv4 = network.ipv4?.trim();
    if (ipv4) return `ws://${ipv4}:${CMUX_TUI_PORT}/v1/link`;
  }
  for (const network of networks) {
    const ipv6 = network.ipv6?.trim();
    if (ipv6) return `ws://[${ipv6}]:${CMUX_TUI_PORT}/v1/link`;
  }
  if (networks.length > 0) {
    throw new ProviderError(
      "freestyle",
      `VM ${vmId} is attached to a private network but holds no address on it, so its cmux-tui daemon is unreachable`,
    );
  }
  const ipv6 = addresses.publicIpv6?.trim();
  if (!ipv6) {
    throw new ProviderError(
      "freestyle",
      `VM ${vmId} has no private network address and no public IPv6 address, so its cmux-tui daemon is unreachable (the platform has no HTTP ingress to arbitrary ports)`,
    );
  }
  return `ws://[${ipv6}]:${CMUX_TUI_PORT}/v1/link`;
}

/**
 * The address a machine's HTTP ports are opened at: its private VPC address,
 * v4 first for the same tunnel-routing reason the daemon route prefers it.
 * There is deliberately no public fallback, unlike the daemon route: the
 * daemon authenticates every session itself (Noise device enrollment), the
 * desktop and a dev server do not, so only the network may gate them. A
 * machine without a private network therefore has no port to open.
 */
export function freestylePortAddress(addresses: FreestyleRouteAddresses, vmId: string): string {
  const networks = addresses.vpcs ?? addresses.networks ?? [];
  for (const network of networks) {
    const ipv4 = network.ipv4?.trim();
    if (ipv4) return ipv4;
  }
  for (const network of networks) {
    const ipv6 = network.ipv6?.trim();
    if (ipv6) return ipv6;
  }
  throw new ProviderError(
    "freestyle",
    networks.length > 0
      ? `VM ${vmId} is attached to a private network but holds no address on it, so its ports cannot be opened`
      : `VM ${vmId} is not on a private network: its desktop and ports are reachable only over the owner's private network (a machine created before private networking must be recreated), and the platform has no ingress to arbitrary ports`,
  );
}

/**
 * The URLs a port open returns: `url` is the bare origin at the private
 * address, `openUrl` what a pane navigates to. For the desktop port that is
 * the noVNC page (web/services/vms/images/desktop.ts), with a query for the
 * app to append its display options to. Under the default-off `screen`
 * transport (images/desktopTransport.ts) the desktop port is the cmux-screen
 * signaling WebSocket, opened as a native remote-view tab, and 6901 is an
 * ordinary port.
 */
export function freestylePortUrls(
  addresses: FreestyleRouteAddresses,
  vmId: string,
  port: number,
  transport: DesktopTransport = "novnc",
): { url: string; openUrl: string } {
  const address = freestylePortAddress(addresses, vmId);
  if (transport === "screen" && port === desktopListenPort(transport)) {
    const endpoint = desktopEndpoint(transport, address);
    return { url: endpoint.url, openUrl: endpoint.openUrl };
  }
  const host = address.includes(":") ? `[${address}]` : address;
  const url = `http://${host}:${port}/`;
  const novncDesktop = transport === "novnc" && port === DEVBOX_DESKTOP_NOVNC_PORT;
  return { url, openUrl: novncDesktop ? devboxDesktopOpenUrl(address) : url };
}

/**
 * Guest-side desktop heal, one exec, no polling: `systemctl start` on the
 * cmux-desktop unit returns when the unit is active, and the unit is
 * Type=notify, so "active" means start-vnc.sh has reported READY (the display
 * accepts connections, noVNC is bound on 6901, the session env is published).
 * On a healthy machine the start is a no-op; after a cold boot or an operator
 * stop it blocks on the owner's signal, bounded by the unit's start timeout
 * and the exec's own. Exit 3 means the image carries no desktop layer at all
 * (a base machine); any other failure means the desktop did not come up.
 */
export function freestyleDesktopHealCommand(transport: DesktopTransport = "novnc"): string {
  return (
    `[ -x ${DEVBOX_DESKTOP_START_SCRIPT} ] || exit 3; ` +
    `if [ -d /run/systemd/system ]; then systemctl start ${DEVBOX_DESKTOP_UNIT} || exit 1; fi; ` +
    desktopReadyProbe(transport)
  );
}

/**
 * The machine's private-network addresses as persistable metadata. Addresses
 * are allocated at create, so the create response already carries them; a
 * response without any (no network) contributes nothing.
 */
/**
 * The persisted network addresses (see {@link freestyleNetworkAddressMetadata})
 * re-shaped for {@link freestyleCmuxRemoteRoute}, so attach on a private
 * machine needs no provider read. Null when the row carries none (a public
 * ingress machine, whose public IPv6 is only known to the provider).
 */
export function freestyleRouteAddressesFromMetadata(
  metadata: Record<string, unknown> | undefined,
): FreestyleRouteAddresses | null {
  const ipv4 = typeof metadata?.networkIpv4 === "string" ? metadata.networkIpv4.trim() : "";
  const ipv6 = typeof metadata?.networkIpv6 === "string" ? metadata.networkIpv6.trim() : "";
  if (!ipv4 && !ipv6) return null;
  return { vpcs: [{ ...(ipv4 ? { ipv4 } : {}), ...(ipv6 ? { ipv6 } : {}) }] };
}

export function freestyleNetworkAddressMetadata(
  data: FreestyleRouteAddresses,
): { networkIpv4?: string; networkIpv6?: string } {
  const network = (data.vpcs ?? data.networks ?? [])[0];
  const ipv4 = network?.ipv4?.trim();
  const ipv6 = network?.ipv6?.trim();
  return {
    ...(ipv4 && isIP(ipv4) === 4 ? { networkIpv4: ipv4 } : {}),
    ...(ipv6 && isIP(ipv6) === 6 ? { networkIpv6: ipv6 } : {}),
  };
}

/** The Freestyle VPC/tunnel records mapped onto the driver-neutral shapes. */
export function mapFreestyleNetwork(data: VpcData): ProviderNetwork {
  return {
    id: data.id,
    slug: data.slug ?? null,
    cidr: data.cidr ?? null,
    cidrV6: data.cidrV6,
  };
}

export function mapFreestyleTunnel(data: TunnelData, networkId: string): ProviderTunnel {
  const attachment = data.attachments.find((entry) => entry.vpcId === networkId);
  return {
    id: data.tunnelId ?? data.id,
    clientConfig: data.clientConfig,
    clientPublicKey: data.clientPublicKey,
    serverPublicKey: data.serverPublicKey,
    endpointHost: data.endpointHost ?? null,
    endpointPort: data.endpointPort,
    routes: data.routes ?? [],
    addressV4: attachment?.ipv4 ?? null,
    addressV6: attachment?.ipv6 ?? null,
    attachments: data.attachments.map((entry) => ({
      networkId: entry.vpcId,
      addressV4: entry.ipv4 ?? null,
      addressV6: entry.ipv6 ?? null,
    })),
  };
}

/**
 * Inline `tls` rules for a create: egress from the new VM (`source: {}`) to
 * the domain's real origin, with the edge injecting the rule's headers into
 * every request. Header values are write-only at the platform (read back as
 * `***`). Returns undefined for no rules so the create omits the block.
 */
export function freestyleEdgeRules(edgeRules: readonly VmEdgeRule[] | undefined) {
  if (!edgeRules || edgeRules.length === 0) return undefined;
  return edgeRules.map((rule) => {
    if (!EDGE_DOMAIN.test(rule.domain)) {
      throw new ProviderError("freestyle", `edge rule domain ${JSON.stringify(rule.domain)} is not a bare host name`);
    }
    if (rule.destinationHost !== undefined && !EDGE_DOMAIN.test(rule.destinationHost)) {
      throw new ProviderError("freestyle", `edge rule destination ${JSON.stringify(rule.destinationHost)} is not a bare host name`);
    }
    return {
      action: "allow" as const,
      domain: rule.domain,
      source: {},
      destination: rule.destinationHost ? { host: rule.destinationHost, port: 443 } : { public: true as const },
      transform: [{ headers: { ...rule.headers } }],
    };
  });
}

/** Edge header-injection rules plus the policy's domain-steering rules, for one create. */
function freestyleCreateTlsRules(edgeRules: readonly VmEdgeRule[] | undefined, networkRules: NetworkRulePlan | undefined) {
  const rules = [...(freestyleEdgeRules(edgeRules) ?? []), ...(networkRules ? inlineEgressTlsRules(networkRules) : [])];
  return rules.length > 0 ? rules : undefined;
}

/**
 * Generated capability-domain suffixes retained for legacy preview leases.
 * Public VM publications use the account-managed publication workflow; these
 * helpers only recognize the older driver-minted capability URL format.
 */
export const FREESTYLE_PORT_RULE_DOMAIN_SUFFIXES = ["cmux.sh", "style.dev"] as const;

/** Matches a driver-minted, 96-bit capability-domain preview hostname. */
export const FREESTYLE_PORT_RULE_DOMAIN_RE = /^cmux-([0-9a-f]{24})\.((?:cmux\.sh)|(?:cmux\.site)|(?:style\.dev))$/;

/** Returns the configured legacy preview suffix first, then the safe fallback. */
export function freestylePortRuleDomainSuffixes(env: NodeJS.ProcessEnv = process.env): readonly string[] {
  const pinned = env.CMUX_VM_PORT_PREVIEW_DOMAIN?.trim().toLowerCase();
  if (pinned && FREESTYLE_PORT_RULE_DOMAIN_RE.test(`cmux-${"0".repeat(24)}.${pinned}`)) {
    return [pinned, ...FREESTYLE_PORT_RULE_DOMAIN_SUFFIXES.filter((suffix) => suffix !== pinned)];
  }
  return FREESTYLE_PORT_RULE_DOMAIN_SUFFIXES;
}

/** Mints a fresh legacy capability-domain hostname. */
export function mintFreestylePortRuleDomain(suffix: string = FREESTYLE_PORT_RULE_DOMAIN_SUFFIXES[0]): string {
  return `cmux-${randomBytes(12).toString("hex")}.${suffix}`;
}

/** Why a stdin exec failed, without the provider's text (which could quote the request). */
export class FreestyleStdinExecError extends Error {
  constructor(public readonly status: number | null, public readonly reason: "http" | "body" | "network") {
    super(`stdin exec failed (${reason}${status === null ? "" : ` ${status}`})`);
    this.name = "FreestyleStdinExecError";
  }
}

/**
 * `exec-await` with stdin (cx-psxg), through the SDK's plain `fetch`, which
 * sends no background header: the provider answers inline and stores no
 * background result of the call, so the stdin (a person key) exists only in
 * this one request. The caller keeps `timeoutMs` under the provider's
 * background window. No error carries the request, the response text or the
 * provider's message: only the HTTP status.
 */
async function execWithStdin(fs: Freestyle, vmId: string, command: string, timeoutMs: number, stdin: SecretBytes): Promise<ExecResult> {
  let response: Response;
  try {
    response = await fs.fetch(`/v5/vms/${encodeURIComponent(vmId)}/exec-await`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ command, timeoutMs, linuxUser: GUEST_LINUX_USER, stdin: stdin.base64() }),
      // A 3xx is not followed: it fails as not-ok, so the stdin is never sent to a Location host.
      redirect: "manual",
    });
  } catch {
    throw new FreestyleStdinExecError(null, "network");
  }
  // 202 is the provider's background answer, which it stores: never accepted for a stdin call.
  if (!response.ok || response.status === 202) {
    void response.body?.cancel();
    throw new FreestyleStdinExecError(response.status, "http");
  }
  let r: { stdout?: unknown; stderr?: unknown; statusCode?: unknown };
  try {
    r = await response.json() as typeof r;
  } catch {
    throw new FreestyleStdinExecError(response.status, "body");
  }
  return {
    // statusCode is null when the guest killed the command at its timeout.
    exitCode: typeof r.statusCode === "number" ? r.statusCode : 124,
    stdout: typeof r.stdout === "string" ? r.stdout : "",
    stderr: typeof r.stderr === "string" ? r.stderr : "",
  };
}

export function normalizeFreestyleExecTimeout(timeoutMs: number | undefined): number {
  if (typeof timeoutMs !== "number" || !Number.isFinite(timeoutMs) || timeoutMs <= 0) {
    return EXEC_DEFAULT_TIMEOUT_MS;
  }
  return Math.min(Math.floor(timeoutMs), MAX_EXEC_TIMEOUT_MS);
}

/**
 * `stopped` maps to paused, not destroyed: a stopped VM still exists and
 * `start()` boots it again (poweroff, an idle timeout, or a failure with
 * automaticRestart off all leave a recoverable machine).
 */
export function mapFreestyleState(state: VmData["state"] | null | undefined): VMStatus {
  switch (state) {
    case "starting":
      return "creating";
    case "running":
      return "running";
    case "pausing":
    case "paused":
    case "stopped":
      return "paused";
    default:
      return "running";
  }
}

/** Freestyle's raw state as a pause observation (see FreestyleProvider.getPauseState). */
export function freestylePauseState(state: VmData["state"] | null | undefined): VmPauseState {
  if (state === "paused") return "paused";
  if (state === "pausing" || state === "starting") return "in_progress";
  // Powered off: not pausable (Freestyle refuses), and recorded as our
  // `paused` row state, as getStatus already does. Resume calls start() for
  // both, which cold-boots a stopped machine (the systemd units bring the
  // daemon back); only memory and running sessions differ.
  if (state === "stopped") return "stopped";
  return "not_paused";
}

/**
 * Tunnel creates finish in ~150 ms at the median and ~2.2 s at the slowest
 * seen in production (30 days); 10 s leaves room while cutting a hung create
 * well short of the 30 s route budget.
 */
const TUNNEL_CREATE_TIMEOUT_MS = 10_000;

/**
 * A create that may have made the tunnel even though it did not return it:
 * a slug conflict, a provider 5xx (a measured 503 still created the tunnel),
 * or no answer at all (timeout, reset). A 4xx other than the conflict is a
 * definite refusal, so it is not worth a recovery read.
 */
export function tunnelCreateMayHaveSucceeded(err: unknown): boolean {
  // Our own configuration failures (no credentials) never reached the provider.
  if (err instanceof ProviderError) return false;
  // A full network is a definite refusal that shares the slug conflict's code.
  if (isFreestyleNetworkFull(err)) return false;
  if (err instanceof FreestyleApiError) {
    return (err.status === 409 && err.code === "CONFLICT") || err.status >= 500;
  }
  return true;
}

/**
 * Freestyle's 409 when every address in a VPC is assigned. It shares the
 * generic CONFLICT code with slug conflicts and network overlap, so only the
 * message tells them apart.
 */
export function isFreestyleNetworkFull(err: unknown): boolean {
  return err instanceof FreestyleApiError && err.status === 409 && /no free addresses/i.test(err.message);
}

/** Wraps a provider failure, keeping a full network distinguishable from an outage. */
/**
 * Freestyle's answer when an exec outlived its timeout and the guest reported
 * no exit for it: 409 VM_NON_RESPONSIVE, "exec produced no exit within <t>".
 * The machine itself still answers (the next exec returns at once), so this
 * is the command's timeout, the same outcome as a null status (exit 124), not
 * a provider outage. Other VM_NON_RESPONSIVE answers stay provider errors.
 */
function isFreestyleExecNoExit(err: unknown): boolean {
  return err instanceof FreestyleApiError
    && err.status === 409
    && err.code === "VM_NON_RESPONSIVE"
    && /exec produced no exit/i.test(err.message);
}

function freestyleOperationError(operation: string, err: unknown): ProviderError {
  return isFreestyleNetworkFull(err)
    ? new ProviderNetworkFullError("freestyle", `${operation}: private network has no free addresses`, err)
    : new ProviderError("freestyle", operation, err);
}

function tunnelRecoveryReason(err: unknown): string {
  if (!(err instanceof FreestyleApiError)) return "no_response";
  return err.status === 409 ? "conflict" : "server_error";
}

function isNotFound(err: unknown): boolean {
  return err instanceof FreestyleApiError && (err.status === 404 || err.code === "NOT_FOUND");
}

/**
 * The Freestyle-side half of cmux private networking: one VPC per owner, and
 * one WireGuard tunnel per owner's computer attached to it.
 *
 * These are account-scoped resources, not machine-scoped ones — they outlive
 * every machine on them — so nothing here takes a VM id. The control plane
 * owns the mapping from cmux user to slug; this class only knows how to make
 * the provider match what it is asked for.
 */
class FreestylePrivateNetworking implements VMPrivateNetworking {
  constructor(private readonly client: (timeoutMs?: number) => Freestyle = freestyleClient) {}

  /**
   * Create-first: a returning user's network id lives in our row, so this runs
   * for an account's first machine (or a heal). The create is the one call
   * that has to happen; a slug conflict means another create won the race or
   * a row went missing, and the read recovers the winner. `heal` (the
   * reconcile cron) reads by slug and re-creates the members rule instead;
   * it is off the request path because a rule deleted out of band is an
   * operator event, not something every create should pay to re-check.
   */
  async ensureNetwork(options: EnsureProviderNetworkOptions): Promise<ProviderNetwork> {
    const slug = options.slug.trim();
    if (!slug) throw new ProviderError("freestyle", "ensureNetwork requires a slug");
    return withVmSpan(
      "cmux.vm.provider.ensure_network",
      "tunnel",
      { "cmux.vm.provider": "freestyle", "cmux.vm.operation": "ensure_network", "cmux.vm.network.slug": slug, "cmux.vm.network.heal": options.heal === true },
        async (span) => {
        const fs = this.client();
        if (options.heal) {
          const existing = await this.readNetworkBySlug(fs, slug);
          if (!existing) throw new ProviderError("freestyle", `ensureNetwork(${slug}): no network to heal`);
          if (options.membersRule !== false) await this.ensureMembersRule(fs, existing.id);
          setSpanAttributes(span, { "cmux.vm.network.id": existing.id, "cmux.vm.network.created": false });
          return existing;
        }
        try {
          // Without a cidr the platform derives a /24 out of 10.0.0.0/8 (254
          // members, fixed for the network's life). Callers that need more
          // name a larger range inside the tunnels' default 10.0.0.0/8 route.
          // The IPv6 /64 is always derived.
          const { data } = await fs.vpc.create({
            slug,
            displayName: options.displayName,
            ...(options.cidr ? { cidr: options.cidr } : {}),
            firewall: { rules: options.membersRule === false ? [] : FREESTYLE_NETWORK_FIREWALL_RULES },
          });
          setSpanAttributes(span, { "cmux.vm.network.id": data.id, "cmux.vm.network.created": true });
          return mapFreestyleNetwork(data);
        } catch (err) {
          // Only the provider's explicit slug conflict permits reconciliation;
          // auth, transport and server errors retain their original failure.
          if (!(err instanceof FreestyleApiError && err.status === 409 && err.code === "CONFLICT")) {
            throw new ProviderError("freestyle", `ensureNetwork(${slug})`, err);
          }
          const existing = await this.readNetworkBySlug(fs, slug);
          if (existing) {
            if (options.membersRule !== false) await this.ensureMembersRule(fs, existing.id);
            setSpanAttributes(span, { "cmux.vm.network.id": existing.id, "cmux.vm.network.created": false });
            return existing;
          }
          throw new ProviderError("freestyle", `ensureNetwork(${slug})`, err);
        }
      },
    );
  }

  async getNetwork(networkIdOrSlug: string): Promise<ProviderNetwork | null> {
    try {
      return mapFreestyleNetwork(await this.client().vpc.get(networkIdOrSlug));
    } catch (err) {
      if (isNotFound(err)) return null;
      throw new ProviderError("freestyle", `getNetwork(${networkIdOrSlug})`, err);
    }
  }

  async deleteNetwork(networkId: string): Promise<void> {
    try {
      await this.client().vpc.delete(networkId);
    } catch (err) {
      if (isNotFound(err)) return; // already gone; delete is idempotent
      throw new ProviderError("freestyle", `deleteNetwork(${networkId})`, err);
    }
  }

  async createTunnel(options: CreateProviderTunnelOptions): Promise<ProviderTunnelCreateResult> {
    const clientPublicKey = options.clientPublicKey.trim();
    if (!clientPublicKey) {
      throw new ProviderError("freestyle", "createTunnel requires the client's public key");
    }
    return withVmSpan(
      "cmux.vm.provider.create_tunnel",
      "tunnel",
      {
        "cmux.vm.provider": "freestyle",
        "cmux.vm.operation": "create_tunnel",
        "cmux.vm.network.id": options.networkId,
      },
        async (span) => {
        try {
          // clientPublicKey is always supplied, so the platform never mints or
          // holds a private key: the config comes back with a blank PrivateKey
          // for the Mac to fill in from its own Keychain. The short timeout
          // bounds a hung create (a measured 503 arrived after ~25 s); the
          // recovery read below finds a tunnel the provider made anyway.
          const data = await this.client(TUNNEL_CREATE_TIMEOUT_MS).tunnels.create({
            slug: options.slug,
            displayName: options.displayName,
            clientPublicKey,
            vpcs: [{ vpcId: options.networkId }],
          });
          const tunnel = mapFreestyleTunnel(data, options.networkId);
          setSpanAttributes(span, { "cmux.vm.tunnel.id": tunnel.id });
          return { tunnel, created: true, rotated: false };
        } catch (err) {
          if (!tunnelCreateMayHaveSucceeded(err)) {
            throw freestyleOperationError(`createTunnel(${options.slug})`, err);
          }
          span.setAttribute("cmux.vm.tunnel.recovery_reason", tunnelRecoveryReason(err));
          // A duplicate create may reuse only the exact same client identity.
          // Key rotation belongs to explicit enrollment of an existing row;
          // recovery must never evict a concurrent client's working key.
          const recovered = await this.recoverExistingTunnel(
            options.slug,
            clientPublicKey,
            options.networkId,
          );
          if (recovered) {
            setSpanAttributes(span, {
              "cmux.vm.tunnel.id": recovered.id,
              "cmux.vm.tunnel.recovered": true,
            });
            return { tunnel: recovered, created: false, rotated: false };
          }
          throw new ProviderError("freestyle", `createTunnel(${options.slug})`, err);
        }
      },
    );
  }

  /** Reconciles a provider tunnel left behind when the control-plane row disappeared. */
  private async recoverExistingTunnel(
    slug: string,
    clientPublicKey: string,
    networkId: string,
  ): Promise<ProviderTunnel | null> {
    const normalizedSlug = slug.trim();
    if (!normalizedSlug) return null;
    try {
      const fs = this.client();
      const listed = await fs.tunnels.list();
      const existing = listed.tunnels.find((tunnel) => tunnel.slug?.trim() === normalizedSlug);
      if (!existing) return null;

      const tunnelID = existing.tunnelId ?? existing.id;
      let current: TunnelData = existing;
      if (current.clientPublicKey.trim() !== clientPublicKey) return null;
      if (!current.attachments.some((attachment) => attachment.vpcId === networkId)) {
        current = await fs.tunnels.attachVpc(tunnelID, networkId);
      }
      if (current.clientPublicKey.trim() !== clientPublicKey ||
          !current.attachments.some((attachment) => attachment.vpcId === networkId)) return null;
      return mapFreestyleTunnel(current, networkId);
    } catch {
      // Preserve the original create failure. A failed reconciliation attempt
      // must not hide a provider outage or turn it into an unrelated error.
      return null;
    }
  }

  async getTunnel(tunnelId: string, networkId: string): Promise<ProviderTunnel | null> {
    try {
      const fs = this.client();
      let data = await fs.tunnels.get(tunnelId);
      if (!data.attachments.some((entry) => entry.vpcId === networkId)) {
        // The tunnel outlives its attachments, so a network detached by hand
        // (or replaced after a network delete) leaves a live tunnel that routes
        // nowhere. Re-attaching is what makes the config the caller already
        // holds start working again, with nothing to re-download.
        data = await fs.tunnels.attachVpc(tunnelId, networkId);
      }
      return mapFreestyleTunnel(data, networkId);
    } catch (err) {
      if (isNotFound(err)) return null;
      throw freestyleOperationError(`getTunnel(${tunnelId})`, err);
    }
  }

  async rotateTunnelKey(tunnelId: string, clientPublicKey: string, networkId: string): Promise<ProviderTunnel> {
    const key = clientPublicKey.trim();
    if (!key) throw new ProviderError("freestyle", "rotateTunnelKey requires the client's public key");
    try {
      const data = await this.client().tunnels.rotateKey(tunnelId, { clientPublicKey: key });
      return mapFreestyleTunnel(data, networkId);
    } catch (err) {
      throw new ProviderError("freestyle", `rotateTunnelKey(${tunnelId})`, err);
    }
  }

  async deleteTunnel(tunnelId: string): Promise<void> {
    try {
      await this.client().tunnels.delete(tunnelId);
    } catch (err) {
      if (isNotFound(err)) return; // already gone; delete is idempotent
      throw new ProviderError("freestyle", `deleteTunnel(${tunnelId})`, err);
    }
  }

  async attachTunnelNetwork(tunnelId: string, networkId: string): Promise<ProviderTunnelAttachment> {
    try {
      const data = await this.client().tunnels.attachVpc(tunnelId, networkId);
      const attachment = data.attachments.find((entry) => entry.vpcId === networkId);
      if (!attachment) throw new Error("missing attachment");
      return { networkId, addressV4: attachment.ipv4 ?? null, addressV6: attachment.ipv6 ?? null };
    } catch (err) {
      if (isFreestyleNetworkFull(err)) throw freestyleOperationError(`attachTunnelNetwork(${tunnelId})`, err);
      // Freestyle uses generic CONFLICT for 409s; apart from a full network, overlap is the only reachable 409 without remoteCidrs or pinned addresses.
      if (err instanceof FreestyleApiError && err.status === 409 && err.code === "CONFLICT") {
        throw new ProviderTunnelNetworkOverlapError(`Freestyle refused overlapping tunnel network ${networkId}`);
      }
      throw new ProviderError("freestyle", `attachTunnelNetwork(${tunnelId})`, err);
    }
  }

  async detachTunnelNetwork(tunnelId: string, networkId: string): Promise<void> {
    try {
      await this.client().tunnels.detachVpc(tunnelId, networkId);
    } catch (err) {
      if (isNotFound(err)) return;
      throw new ProviderError("freestyle", `detachTunnelNetwork(${tunnelId})`, err);
    }
  }

  async listNetworkTunnelIds(networkId: string): Promise<string[]> {
    try {
      const { tunnels } = await this.client().vpc.ref(networkId).tunnels.list();
      return tunnels.map((tunnel) => tunnel.tunnelId ?? tunnel.id);
    } catch (err) {
      throw new ProviderError("freestyle", `listNetworkTunnelIds(${networkId})`, err);
    }
  }

  async listFirewallRules(options?: { vmId?: string; vpcId?: string; tunnelId?: string }): Promise<VMFirewallRule[]> {
    const result = await this.client().firewall.rules.list(options);
    return result.rules as VMFirewallRule[];
  }

  async getFirewallRule(ruleId: string): Promise<VMFirewallRule> {
    return await this.client().firewall.rules.get(ruleId) as VMFirewallRule;
  }

  async createFirewallRule(options: VMFirewallRuleInput): Promise<VMFirewallRule> {
    return await this.client().firewall.rules.create({ action: "allow", ...options }) as VMFirewallRule;
  }

  async deleteFirewallRule(ruleId: string): Promise<void> {
    await this.client().firewall.rules.delete(ruleId);
  }

  /**
   * Guarantee the network's members-reach-each-other rule (all ports, all
   * protocols — the rule created with the network). Missing means someone
   * removed it; re-create rather than fail, because nothing on the network
   * works without it.
   */
  private async ensureMembersRule(fs: Freestyle, networkId: string): Promise<void> {
    try {
      const { rules } = await fs.firewall.rules.list({ vpcId: networkId });
      const present = rules.some((rule) =>
        rule.source.vpcId === networkId &&
        rule.destination.vpcId === networkId &&
        rule.destination.port === undefined &&
        rule.destination.protocol === undefined
      );
      if (present) return;
      await fs.firewall.rules.create({
        action: "allow",
        source: { vpcId: networkId },
        destination: { vpcId: networkId },
        description: "cmux: members reach each other (healed)",
      });
    } catch (err) {
      throw new ProviderError("freestyle", `members-rule heal failed for ${networkId}`, err);
    }
  }

  /** A network by slug, or null when the account has none under that name. */
  private async readNetworkBySlug(fs: Freestyle, slug: string): Promise<ProviderNetwork | null> {
    try {
      return mapFreestyleNetwork(await fs.vpc.get(slug));
    } catch (err) {
      if (isNotFound(err)) return null;
      throw new ProviderError("freestyle", `getNetwork(${slug})`, err);
    }
  }
}

function spanAttributes(vmId: string, operation: string, extra: Record<string, string | number | boolean> = {}) {
  return {
    "cmux.vm.provider": "freestyle",
    "cmux.vm.operation": operation,
    "cmux.vm.id": vmId,
    ...extra,
  };
}

/**
 * A snapshot that does not exist, or was not taken from the machine named in
 * the request. `code` and `status` are what `isProviderNotFoundError` reads, so
 * the workflow answers 404 vm_snapshot_not_found instead of a provider failure.
 */
export class FreestyleSnapshotNotFoundError extends Error {
  readonly code = "not_found";
  readonly status = 404;

  constructor(readonly snapshotId: string, readonly vmId: string) {
    super(`snapshot ${snapshotId} not found for vm ${vmId}`);
    this.name = "FreestyleSnapshotNotFoundError";
  }
}

/** The provider's snapshot record in the driver contract's shape. */
export function freestyleSnapshotRef(snapshot: SnapshotData): SnapshotRef {
  const createdAt = Date.parse(snapshot.createdAt);
  const name = snapshot.displayName?.trim() || snapshot.slug?.trim() || undefined;
  return {
    id: snapshot.id,
    createdAt: Number.isFinite(createdAt) ? createdAt : 0,
    ...(name ? { name } : {}),
  };
}

/** Span attributes for the machine shape a create asked for, else the one the provider reported. */
function freestyleCreateResourceAttributes(
  imageSize: CreateOptions["imageSize"],
  data: { resources?: { cpu?: number; memory?: number; storage?: number } | null },
): Record<string, string | number | boolean> {
  if (imageSize) {
    return {
      "cmux.vm.image_size": imageSize.name,
      "cmux.vm.resources.cpu": imageSize.cpu,
      "cmux.vm.resources.memory_mb": imageSize.memoryMb,
      "cmux.vm.resources.storage_mb": imageSize.storageMb,
      "cmux.vm.resize.requested": false,
    };
  }
  return {
    "cmux.vm.resources.cpu": data.resources?.cpu ?? 0,
    "cmux.vm.resources.memory_mb": data.resources?.memory ?? 0,
    "cmux.vm.resources.storage_mb": data.resources?.storage ?? 0,
    "cmux.vm.resize.requested": false,
  };
}

export class FreestyleProvider implements VMProvider {
  readonly id = "freestyle" as const;

  /** The normal terminal transport. SSH is an explicit legacy attach verb, not the default. */
  readonly attachTransports: readonly AttachTransport[] = ["cmux-remote"];

  /** ``create`` honors requested memory through the grow-only size ladder. */
  /// Freestyle exposes live resource statistics and grow-only resizing.
  // `fork` stays derived (no native fork): forkVm takes the snapshot path, and
  // clients offer Fork from snapshot + restore (VMCapabilities.canFork).
  readonly capabilities = { stats: true, sizing: true, desktop: true } as const;

  readonly privateNetworking: VMPrivateNetworking;
  /** Which desktop this provider opens: noVNC (default) or the cmux-screen host. */
  private readonly desktopTransport: DesktopTransport;
  private readonly resourceStats: FreestyleResourceStatsReader;
  readonly healthInventory: VmHealthInventory;

  constructor(
    private readonly deps: FreestyleProviderDependencies = {
      client: freestyleClient,
    },
  ) {
    this.desktopTransport = this.deps.desktopTransport ?? resolveDesktopTransport(process.env[DESKTOP_TRANSPORT_ENV]);
    this.privateNetworking = new FreestylePrivateNetworking(this.deps.client);
    this.resourceStats = new FreestyleResourceStatsReader(this.deps.client);
    this.healthInventory = freestyleHealthInventory(this.deps.client);
  }

  /**
   * A provider SSH credential for exactly this VM and the work user: a new
   * Freestyle identity, granted only `vmId` as FREESTYLE_WORK_LINUX_USER, with
   * one access token (freestyle.sh/docs/vms/client-sessions). The token is the
   * proxy password; the identity id is the opaque handle the workflow stores
   * and passes to revokeSSHIdentity on destroy, lease revoke and sign-out.
   * Never the team key. SSH is not an advertised transport (attachTransports).
   */
  async openSSH(vmId: string): Promise<SSHEndpoint> {
    return withVmSpan("cmux.vm.provider.open_ssh", "provider", spanAttributes(vmId, "open_ssh"), async () => {
      const client = this.deps.client();
      let created: Awaited<ReturnType<Freestyle["identities"]["create"]>>;
      try {
        created = await client.identities.create();
      } catch (err) {
        throw new ProviderError("freestyle", `openSSH(${vmId}): identity`, err);
      }
      try {
        await created.identity.permissions.vm.grant({ vmId, allowedLinuxUsers: [FREESTYLE_WORK_LINUX_USER] });
        const { token } = await created.identity.tokens.create();
        return {
          transport: "ssh",
          host: FREESTYLE_SSH_PROXY_HOST,
          port: 22,
          username: `${vmId}+${FREESTYLE_WORK_LINUX_USER}`,
          publicKeyFingerprint: null,
          credential: { kind: "password", value: token },
          identityHandle: created.identityId,
        };
      } catch (err) {
        // Nothing half-made survives: an identity without its grant or token is deleted again.
        await created.identity.delete().catch(() => undefined);
        throw new ProviderError("freestyle", `openSSH(${vmId})`, err);
      }
    });
  }

  /** Deletes the identity (its token and grant with it). Unknown, revoked or blank handles are a no-op. */
  async revokeSSHIdentity(identityHandle: string): Promise<void> {
    const handle = identityHandle.trim();
    if (!handle) return;
    try {
      await this.deps.client().identities.delete(handle);
    } catch (err) {
      // 404: already gone. 400: not an identity this driver can delete (a managed one, or a foreign handle).
      if (err instanceof FreestyleApiError && (err.status === 404 || err.status === 400)) return;
      throw new ProviderError("freestyle", "revokeSSHIdentity", err);
    }
  }

  async prepareSCP(vmId: string, publicKey: string): Promise<import("./types").SCPEndpoint> {
    return withVmSpan("cmux.vm.provider.prepare_scp", "provider", spanAttributes(vmId, "prepare_scp"), async () => {
      const key = parseSshPublicKey(publicKey);
      const vm = this.deps.client().vms.ref(vmId);
      const data = await vm.data();
      const host = freestylePortAddress(data, vmId);
      const expires = new Date(Date.now() + SCP_KEY_TTL_SECONDS * 1000);
      let result: Awaited<ReturnType<Vm["exec"]>>;
      try {
        result = await this.deps.client(SCP_PREPARE_EXEC_TIMEOUT_MS + EXEC_OVERHEAD_TIMEOUT_MS).vms.ref(vmId)
          .exec({ command: scpPrepareCommand(key, expires), timeoutMs: SCP_PREPARE_EXEC_TIMEOUT_MS, linuxUser: GUEST_LINUX_USER });
      } catch (err) {
        // The command never ran or its answer was lost: nothing is known about sshd.
        if (isProviderHangCause(err)) {
          throw new ProviderGuestUnresponsiveError("freestyle", `SCP preparation in ${vmId}: the machine did not answer the setup command`, err);
        }
        throw new ProviderError("freestyle", `prepareSCP(${vmId})`, err);
      }
      if (result.statusCode === null || result.statusCode === undefined || result.statusCode === 124) {
        throw new ProviderGuestUnresponsiveError("freestyle", `SCP preparation in ${vmId}: the setup command did not exit within ${SCP_PREPARE_EXEC_TIMEOUT_MS / 1000}s`);
      }
      if (result.statusCode !== 0) {
        const detail = (result.stderr ?? "").trim() || `exit ${result.statusCode} with no error output`;
        throw new ProviderError("freestyle", `SCP preparation failed in ${vmId}: ${detail.slice(0, 500)}`);
      }
      let hostPublicKey: string;
      try { hostPublicKey = parseSshPublicKey(result.stdout ?? ""); }
      catch { throw new ProviderError("freestyle", "SCP preparation returned an invalid guest host key."); }
      return { host, port: 22, username: "cmux", hostPublicKey, expiresAtUnix: Math.floor(expires.getTime() / 1000) };
    });
  }

  async create(options: CreateOptions): Promise<VMHandle> {
    const image = options.image.trim();
    if (!image) {
      throw new ProviderError("freestyle", "create requires a resolved image");
    }
    const tlsRules = freestyleCreateTlsRules(options.edgeRules, options.networkRules);
    return withVmSpan(
      "cmux.vm.provider.create",
      "provider",
      {
        "cmux.vm.provider": "freestyle",
        "cmux.vm.operation": "create",
        "cmux.vm.image": image,
        "cmux.vm.edge_rules": tlsRules?.length ?? 0,
        "cmux.timeout_ms": CREATE_TIMEOUT_MS,
      },
      async (span) => {
        try {
          const clientStartedAt = performance.now();
          const fs = this.deps.client(CREATE_TIMEOUT_MS);
          const clientInitMs = Math.round((performance.now() - clientStartedAt) * 100) / 100;
          setSpanAttributes(span, { "cmux.vm.provider.client_init_ms": clientInitMs });
          const networkId = options.network?.id;
          const providerStartedAt = performance.now();
          const { vm, vmId, data } = await fs.vms.create({
            snapshotId: image,
            displayName: "cmux Cloud VM",
            // Do not let an account/provider idle default turn a persistent
            // machine into a one-shot box. Explicit pause/stop still works.
            idleTimeoutSeconds: FREESTYLE_PERSISTENT_IDLE_TIMEOUT_SECONDS,
            // Be explicit even for normal machines: images created under an
            // account default with automatic restart disabled must not remain
            // unrecoverable after a provider/VMM failure.
            automaticRestart: options.runtimeBudgetSeconds === undefined,
            ...(options.runtimeBudgetSeconds !== undefined
              ? { maxRunTotalSeconds: Math.max(0, Math.floor(options.runtimeBudgetSeconds)) }
              : {}),
            metadata: { cmux: "cloud" },
            ...freestyleCustomer(options.customerId),
            firewall: { rules: freestyleFirewallRules({ publicDaemonIngress: !networkId, memberIngressNetworkId: options.network?.memberIngress ? networkId : undefined, networkRules: options.networkRules }) },
            ...(networkId ? { vpcs: [{ vpcId: networkId, ipv4: true, ipv6: true }] } : {}),
            ...(tlsRules ? { tls: { rules: tlsRules } } : {}),
          });
          const providerMs = Math.round((performance.now() - providerStartedAt) * 100) / 100;
          setSpanAttributes(span, {
            "cmux.vm.id": vmId,
            "cmux.vm.network.private": !!networkId,
            "cmux.vm.provider.api_provision_ms": providerMs,
            // `vms.create` resolves only after the SDK has decoded the id;
            // retain its wall-clock receipt as an explicit correlation point.
            "cmux.vm.provider.machine_id_received": true,
            "cmux.vm.provider.machine_id_received_at_ms": Date.now(),
          });
          try {
            if (options.forked) await this.awaitForkDaemon(vm);
            // Validate the provider-assigned VPC address without issuing the
            // guest-side announcement exec. The baked supervisor announces on
            // clone boot; attach performs the strict announcement before
            // handing out the private daemon route.
            if (networkId) await this.announcePrivateAddresses(vm, data, { validateOnly: true });
            // Every production create resolves to a size-specific snapshot. The
            // snapshot owns the guest CLI, browser integration, resource
            // reporter, prompt templates, hooks, and daemon. A create must only
            // allocate that immutable image and attach its account network.
            // Per-machine prompt identity is refreshed asynchronously by the
            // boot contract; no guest exec or filesystem upload belongs here.
            setSpanAttributes(span, freestyleCreateResourceAttributes(options.imageSize, data));
            // The baked supervisor announces the VPC interface on clone boot
            // and every 30 seconds. Waiting for a second guest-side `ip` probe
            // here made create pay a redundant network round trip and turned
            // a transient netlink timeout into a destructive rollback. The
            // attach path performs the strict announcement/readiness check
            // before handing out the private daemon route.
          } catch (err) {
            // A VM that failed to size or configure must not survive as an
            // orphan, and an undersized machine must not ship as if it were
            // the plan machine.
            await vm.delete().catch((cleanupErr) => {
              console.error(`[freestyle] create rollback failed; VM ${vmId} may be orphaned`, cleanupErr);
            });
            throw err;
          }
          return {
            provider: "freestyle" as const,
            providerVmId: vmId,
            status: "running" as const,
            image,
            createdAt: Date.now(),
            // The network id and addresses are persisted so listings can show a
            // machine's private IP, and attach dials the recorded address
            // without a provider round trip (openCmuxRemote).
            providerMetadata: {
              ...(options.providerMetadata ?? {}),
              cmuxTuiContract: "snapshot-v2",
              cmuxRemoteAuth: cloudRemoteAuthMode(
                options.providerMetadata,
                findVmImageManifestEntry("freestyle", image)?.cmuxRemoteAuth ?? "trusted-carrier",
              ),
              ...(networkId ? { networkId } : {}),
              ...(freestyleNetworkAddressMetadata(data)),
            },
          };
        } catch (err) {
          if (err instanceof ProviderError) throw err;
          throw freestyleOperationError(`create(${image}) failed`, err);
        }
      },
    );
  }

  async applyNetworkPolicy(vmId: string, plan: NetworkRulePlan): Promise<void> {
    return withVmSpan(
      "cmux.vm.provider.apply_network_policy",
      "provider",
      spanAttributes(vmId, "applyNetworkPolicy", {
        "cmux.vm.network.public_egress": plan.publicEgress,
        "cmux.vm.network.ranges": plan.ranges.length,
        "cmux.vm.network.domains": plan.domains.length,
        "cmux.vm.network.dns": plan.dns,
      }),
      async (span) => {
        try {
          const result = await reconcileFreestyleEgress(this.deps.client(), vmId, plan);
          setSpanAttributes(span, {
            "cmux.vm.network.firewall_created": result.firewallCreated,
            "cmux.vm.network.firewall_deleted": result.firewallDeleted,
            "cmux.vm.network.tls_created": result.tlsCreated,
            "cmux.vm.network.tls_deleted": result.tlsDeleted,
          });
        } catch (err) {
          if (isFreestyleTlsRuleLimit(err)) {
            span.setAttribute("cmux.vm.network.tls_rule_limit", true);
            if (err instanceof FreestyleTlsRuleLimitRestoreError) {
              span.setAttribute("cmux.vm.network.tls_restored", err.restored);
              span.setAttribute("cmux.vm.network.tls_unrestored", err.unrestored.length);
              if (err.unrestored.length > 0) {
                console.error("[freestyle] TLS rule limit: retired rules not restored", JSON.stringify({ vmId, unrestored: err.unrestored }));
              }
            }
            throw new ProviderTlsRuleLimitError("freestyle", `applyNetworkPolicy(${vmId}): account TLS rule limit reached`, err);
          }
          throw new ProviderError("freestyle", `applyNetworkPolicy(${vmId})`, err);
        }
      },
    );
  }

  async destroy(vmId: string, _credential?: ProviderCredential, options?: { readonly strict?: boolean }): Promise<void> {
    return withVmSpan(
      "cmux.vm.provider.destroy",
      "provider",
      spanAttributes(vmId, "destroy"),
      async () => {
        try {
          await this.deps.client().vms.ref(vmId).delete();
        } catch (err) {
          // Already gone; destroy is idempotent. Strict: only Freestyle's own NOT_FOUND says so.
          if (options?.strict ? err instanceof FreestyleApiError && err.code === "NOT_FOUND" : isNotFound(err)) return;
          throw new ProviderError("freestyle", `destroy(${vmId})`, err);
        }
      },
    );
  }

  async getStatus(vmId: string, options?: ProviderReadOptions): Promise<VMStatus> {
    return withVmSpan(
      "cmux.vm.provider.get_status",
      "provider",
      spanAttributes(vmId, "get_status"),
      async (span) => {
        try {
          const data = await this.deps.client(undefined, options?.signal).vms.get(vmId);
          const status = mapFreestyleState(data.state);
          setSpanAttributes(span, { "cmux.vm.provider_state": data.state, "cmux.vm.status": status });
          return status;
        } catch (err) {
          if (isNotFound(err)) return "destroyed";
          throw new ProviderError("freestyle", `getStatus(${vmId})`, err);
        }
      },
    );
  }

  /**
   * The raw pause state: only `paused` is a finished pause. `pausing` and
   * `starting` are transitions; `stopped` is powered off, which a pause does
   * not produce (memory is lost), so it is not a finished pause.
   */
  async getPauseState(vmId: string): Promise<VmPauseState> {
    return withVmSpan(
      "cmux.vm.provider.get_pause_state",
      "provider",
      spanAttributes(vmId, "get_pause_state"),
      async (span) => {
        try {
          const data = await this.deps.client().vms.get(vmId);
          const state = freestylePauseState(data.state);
          setSpanAttributes(span, { "cmux.vm.provider_state": data.state, "cmux.vm.pause_state": state });
          return state;
        } catch (err) {
          if (isNotFound(err)) return "destroyed";
          throw new ProviderError("freestyle", `getPauseState(${vmId})`, err);
        }
      },
    );
  }

  /** Pause freezes memory, so a later start resumes the daemon in place. */
  async pause(vmId: string): Promise<void> {
    return withVmSpan(
      "cmux.vm.provider.pause",
      "provider",
      spanAttributes(vmId, "pause"),
      async () => {
        try {
          await this.deps.client(CREATE_TIMEOUT_MS).vms.ref(vmId).pause();
        } catch (err) {
          throw new ProviderError("freestyle", `pause(${vmId})`, err);
        }
      },
    );
  }

  // Hard restart is deliberately unavailable. The documented provider API
  // can pause/start, which resumes the same memory and cannot recover a frozen
  // guest. Do not advertise restart or call an undocumented endpoint until a
  // memory-discarding operation with completion/retry semantics is available.

  async setRuntimeBudget(vmId: string, remainingSeconds: number | null): Promise<void> {
    const vm = this.deps.client(CREATE_TIMEOUT_MS).vms.ref(vmId);
    if (remainingSeconds === null) {
      await vm.update({ maxRunTotalSeconds: -1, automaticRestart: true });
      return;
    }
    const data = await vm.data();
    const used = data.totalRunSeconds;
    if (typeof used !== "number" || !Number.isFinite(used) || used < 0 || !Number.isFinite(remainingSeconds) || remainingSeconds < 0) {
      throw new ProviderError("freestyle", "setRuntimeBudget", new Error("Provider runtime counter is unavailable"));
    }
    await vm.update({ maxRunTotalSeconds: Math.floor(used + remainingSeconds), automaticRestart: false });
  }

  async resume(vmId: string): Promise<VMHandle> {
    return withVmSpan(
      "cmux.vm.provider.resume",
      "provider",
      spanAttributes(vmId, "resume"),
      async (span) => {
        try {
          const fs = this.deps.client(CREATE_TIMEOUT_MS);
          const vm = fs.vms.ref(vmId);
          const data = await vm.start();
          // The wake already succeeded: the machine is running and, unlike
          // create and restore, there is no fresh allocation to roll back. A
          // start payload can also name the network a VM is on before the
          // platform fills in the address assigned on it, so an unusable
          // address here is not a verdict on the machine. Prepare the route
          // best-effort and leave readiness to openCmuxRemote, which reads the
          // authoritative addresses and fails closed on them.
          try {
            await this.announcePrivateAddresses(vm, data);
          } catch (announceError) {
            recordSpanError(span, announceError);
          }
          // Older cmux machines were created while the provider's account
          // default supplied a finite idle timeout. Clear that legacy policy
          // the first time the user wakes one so the box stays available after
          // this explicit wake. A provider rejection is non-fatal: the VM is
          // still awake and the next attach can retry the policy update.
          if (typeof data.idleTimeoutSeconds === "number" && data.idleTimeoutSeconds >= 0) {
            try {
              await vm.update({ idleTimeoutSeconds: FREESTYLE_PERSISTENT_IDLE_TIMEOUT_SECONDS });
              span.setAttribute("cmux.vm.idle_timeout_seconds", FREESTYLE_PERSISTENT_IDLE_TIMEOUT_SECONDS);
            } catch (policyError) {
              recordSpanError(span, policyError);
            }
          }
          const status = mapFreestyleState(data.state);
          setSpanAttributes(span, { "cmux.vm.provider_state": data.state, "cmux.vm.status": status });
          // A memory-preserving pause keeps the daemon; a cold boot (the VM had
          // stopped) relies on the baked systemd unit. Resume does no guest
          // work (see NO-WORK INVARIANT at the top of this file). The client's
          // link retry covers the short window before the unit is listening.
          return {
            provider: "freestyle" as const,
            providerVmId: data.id,
            status,
            image: data.snapshotId ?? "freestyle:resumed",
            createdAt: Date.now(),
          };
        } catch (err) {
          throw new ProviderError("freestyle", `resume(${vmId})`, err);
        }
      },
    );
  }

  async exec(vmId: string, command: string, opts?: ExecOptions): Promise<ExecResult> {
    const timeoutMs = normalizeFreestyleExecTimeout(opts?.timeoutMs);
    return withVmSpan(
      "cmux.vm.provider.exec",
      "provider",
      spanAttributes(vmId, "exec", {
        "cmux.command_length": command.length,
        "cmux.timeout_ms": timeoutMs,
      }),
      async (span) => {
        try {
          // A caller's signal (ExecOptions.signal) ends the request with it.
          const fs = this.deps.client(timeoutMs + EXEC_OVERHEAD_TIMEOUT_MS, opts?.signal);
          if (opts?.stdin) {
            const r = await execWithStdin(fs, vmId, command, timeoutMs, opts.stdin);
            setSpanAttributes(span, { "cmux.exec.exit_code": r.exitCode });
            return r;
          }
          const vm = fs.vms.ref(vmId);
          // Public `vm exec` commands belong to the same account as Cloud
          // terminals and coding agents. Leaving `linuxUser` unset asks the
          // provider for its uid-1000 account (`cmux` on current images), while
          // preserving the provider's legacy fallback to root on older images.
          // Driver maintenance stays explicitly root below, as does cmux's own
          // guest maintenance that asks for it.
          const r = await vm.exec({ command, timeoutMs, ...(opts?.asRoot ? { linuxUser: GUEST_LINUX_USER } : {}) });
          // statusCode is null when the guest killed the command at its timeout.
          const exitCode = r.statusCode ?? 124;
          setSpanAttributes(span, { "cmux.exec.exit_code": exitCode });
          return { exitCode, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
        } catch (err) {
          if (isFreestyleExecNoExit(err)) {
            setSpanAttributes(span, { "cmux.exec.exit_code": 124, "cmux.exec.no_exit_reported": true });
            return {
              exitCode: 124,
              stdout: "",
              stderr: `cmux: the command did not exit within ${Math.round(timeoutMs / 1000)}s and its output was lost; it may still be running on the machine.\n`,
            };
          }
          throw new ProviderError("freestyle", `exec(${vmId})`, err);
        }
      },
    );
  }

  async listFiles(vmId: string, path: string, options?: ProviderReadOptions): Promise<VMFileEntry[]> {
    const entries = await this.deps.client(undefined, options?.signal).vms.ref(vmId).fs.readDir(path);
    return entries.map((entry) => ({
      name: entry.name,
      kind: entry.kind === "directory" || entry.kind === "symlink" ? entry.kind : "file",
    }));
  }

  async readFile(vmId: string, path: string, options?: ProviderReadOptions): Promise<VMFileContents> {
    const data = await this.deps.client(undefined, options?.signal).vms.ref(vmId).fs.readFile(path);
    return { path, data: new Uint8Array(data), size: data.byteLength };
  }

  async writeFile(vmId: string, path: string, data: Uint8Array, mode?: number): Promise<void> {
    await this.deps.client().vms.ref(vmId).fs.writeFile(path, data, mode === undefined ? {} : { mode });
  }

  async makeDirectory(vmId: string, path: string): Promise<void> {
    await this.deps.client().vms.ref(vmId).fs.mkdir(path);
  }

  async removeFile(vmId: string, path: string): Promise<void> {
    await this.deps.client().vms.ref(vmId).fs.remove(path);
  }

  async statFile(vmId: string, path: string, options?: ProviderReadOptions): Promise<VMFileStat> {
    const stat = await this.deps.client(undefined, options?.signal).vms.ref(vmId).fs.stat(path);
    const raw = stat as unknown as Record<string, unknown>;
    const kind = raw.isDirectory === true ? "directory" : raw.isSymlink === true ? "symlink" : "file";
    const permissions = typeof raw.permissions === "string" ? Number.parseInt(raw.permissions, 8) : undefined;
    const modified = typeof raw.modified === "string" ? Date.parse(raw.modified) : NaN;
    return {
      path,
      kind,
      size: typeof raw.size === "number" ? raw.size : undefined,
      mode: permissions !== undefined && Number.isFinite(permissions) ? permissions : undefined,
      modifiedAt: Number.isFinite(modified) ? modified : undefined,
    };
  }

  /** Read provisioned dimensions without waking the guest or inventing usage gauges. */
  async getStats(vmId: string, options?: ProviderReadOptions): Promise<VMStats> {
    return withVmSpan(
      "cmux.vm.provider.get_stats",
      "provider",
      spanAttributes(vmId, "getStats"),
      async () => {
        try {
          const data = await this.deps.client(undefined, options?.signal).vms.get(vmId);
          return {
            state: data.state === "running"
              ? "awake"
              : data.state === "paused" || data.state === "pausing" || data.state === "stopped"
                ? "asleep"
                : "unknown",
            sampledAt: Date.now(),
            cpus: data.resources.cpu,
            memoryTotalMb: data.resources.memory,
            diskTotalMb: data.resources.storage,
          };
        } catch (err) {
          throw new ProviderError("freestyle", `getStats(${vmId})`, err);
        }
      },
    );
  }

  /** Read guest gauges without the general exec path's CLI installation/heal. */
  getResourceStats(vmId: string): Promise<VMResourceStatsResult | null> {
    return this.resourceStats.read(vmId);
  }

  async resize(vmId: string, options: VMResizeOptions): Promise<void> {
    return withVmSpan(
      "cmux.vm.provider.resize",
      "provider",
      spanAttributes(vmId, "resize", {
        "cmux.vm.resize.storage_mb": options.storageMb ?? 0,
      }),
      async () => {
        try {
          const request: ResizeVmOptions = {
            ...(options.cpu === undefined ? {} : { cpu: options.cpu }),
            ...(options.memoryMb === undefined ? {} : { memory: options.memoryMb }),
            ...(options.storageMb === undefined ? {} : { storage: options.storageMb }),
          };
          if (Object.keys(request).length === 0) return;
          const fs = this.deps.client(CREATE_TIMEOUT_MS);
          await fs.vms.ref(vmId).resize(request);
        } catch (err) {
          throw new ProviderError("freestyle", `resize(${vmId})`, err);
        }
      },
    );
  }

  async snapshot(vmId: string, name?: string): Promise<SnapshotRef> {
    return withVmSpan(
      "cmux.vm.provider.snapshot",
      "provider",
      spanAttributes(vmId, "snapshot", {
        "cmux.snapshot.named": !!name,
        "cmux.timeout_ms": SNAPSHOT_TIMEOUT_MS,
      }),
      async (span) => {
        try {
          const fs = this.deps.client(SNAPSHOT_TIMEOUT_MS);
          // Snapshots capture memory + disk of a running or paused VM. The
          // caller's name goes to displayName only: slugs are unique per account
          // and a collision would fail the snapshot for a cosmetic label.
          const out = await fs.vms.ref(vmId).snapshot(name ? { displayName: name } : undefined);
          if (!out.snapshotId) throw new Error("snapshot response missing snapshotId");
          setSpanAttributes(span, { "cmux.snapshot.id": out.snapshotId });
          return { id: out.snapshotId, createdAt: Date.now(), name };
        } catch (err) {
          throw new ProviderError("freestyle", `snapshot(${vmId})`, err);
        }
      },
    );
  }

  async listSnapshots(vmId: string, options?: ProviderReadOptions): Promise<SnapshotRef[]> {
    return withVmSpan(
      "cmux.vm.provider.list_snapshots",
      "provider",
      spanAttributes(vmId, "listSnapshots"),
      async (span) => {
        try {
          const fs = this.deps.client(undefined, options?.signal);
          const snapshots: SnapshotData[] = [];
          for (let offset = 0; offset < SNAPSHOT_LIST_MAX; offset += SNAPSHOT_LIST_PAGE) {
            const page = await fs.vms.snapshots.list({ sourceVmId: vmId, limit: SNAPSHOT_LIST_PAGE, offset });
            snapshots.push(...page.snapshots);
            if (page.snapshots.length < SNAPSHOT_LIST_PAGE || snapshots.length >= page.totalCount) break;
          }
          setSpanAttributes(span, { "cmux.snapshot.count": snapshots.length });
          return snapshots
            // The filter is the provider's; the guard keeps a lax answer from
            // ever listing another machine's snapshots under this one.
            .filter((snapshot) => (snapshot.sourceVmId ?? vmId) === vmId)
            .map(freestyleSnapshotRef)
            .sort((a, b) => b.createdAt - a.createdAt);
        } catch (err) {
          throw new ProviderError("freestyle", `listSnapshots(${vmId})`, err);
        }
      },
    );
  }

  async deleteSnapshot(vmId: string, snapshotId: string): Promise<void> {
    return withVmSpan(
      "cmux.vm.provider.delete_snapshot",
      "provider",
      spanAttributes(vmId, "deleteSnapshot", { "cmux.snapshot.id": snapshotId }),
      async () => {
        try {
          const fs = this.deps.client();
          // Ownership is per machine: only a snapshot taken from this VM goes.
          // A missing snapshot surfaces here as the SDK's 404.
          const snapshot = await fs.vms.snapshots.get(snapshotId);
          if (snapshot.sourceVmId !== vmId) {
            throw new FreestyleSnapshotNotFoundError(snapshotId, vmId);
          }
          await fs.vms.snapshots.delete(snapshotId);
        } catch (err) {
          throw new ProviderError("freestyle", `deleteSnapshot(${snapshotId})`, err);
        }
      },
    );
  }

  async restore(snapshotId: string, options?: RestoreOptions): Promise<VMHandle> {
    const tlsRules = freestyleCreateTlsRules(options?.edgeRules, options?.networkRules);
    return withVmSpan(
      "cmux.vm.provider.restore",
      "provider",
      {
        "cmux.vm.provider": "freestyle",
        "cmux.vm.operation": "restore",
        "cmux.snapshot.id": snapshotId,
        "cmux.vm.edge_rules": tlsRules?.length ?? 0,
        "cmux.timeout_ms": CREATE_TIMEOUT_MS,
      },
      async (span) => {
        try {
          const fs = this.deps.client(CREATE_TIMEOUT_MS);
          const networkId = options?.network?.id;
          const { vm, vmId, data } = await fs.vms.create({
            snapshotId,
            displayName: "cmux Cloud VM",
            automaticRestart: true,
            idleTimeoutSeconds: FREESTYLE_PERSISTENT_IDLE_TIMEOUT_SECONDS,
            metadata: { cmux: "cloud" },
            ...freestyleCustomer(options?.customerId),
            firewall: { rules: freestyleFirewallRules({ publicDaemonIngress: !networkId, memberIngressNetworkId: options?.network?.memberIngress ? networkId : undefined, networkRules: options?.networkRules }) },
            ...(networkId ? { vpcs: [{ vpcId: networkId, ipv4: true, ipv6: true }] } : {}),
            ...(tlsRules ? { tls: { rules: tlsRules } } : {}),
          });
          setSpanAttributes(span, {
            "cmux.vm.id": vmId,
            "cmux.vm.network.private": !!networkId,
          });
          // The snapshot carries the daemon, guest integration, reporter, and
          // prompt sync contract. Restore has the same no-guest-bootstrap
          // invariant as fresh create.
          try {
            if (networkId) await this.announcePrivateAddresses(vm, data, { validateOnly: true });
          } catch (err) {
            await vm.delete().catch((cleanupErr) => {
              console.error(`[freestyle] restore rollback failed; VM ${vmId} may be orphaned`, cleanupErr);
            });
            throw err;
          }
          return {
            provider: "freestyle" as const,
            providerVmId: vmId,
            status: "running" as const,
            image: snapshotId,
            createdAt: Date.now(),
            providerMetadata: {
              ...(options?.providerMetadata ?? {}),
              cmuxTuiContract: "snapshot-v2",
              cmuxRemoteAuth: cloudRemoteAuthMode(options?.providerMetadata),
              ...(networkId ? { networkId, ...freestyleNetworkAddressMetadata(data) } : {}),
            },
          };
        } catch (err) {
          if (err instanceof ProviderError) throw err;
          throw freestyleOperationError(`restore(${snapshotId})`, err);
        }
      },
    );
  }

  async openCmuxRemote(vmId: string, options?: CmuxRemoteAttachOptions): Promise<CmuxRemoteEndpoint> {
    return withVmSpan(
      "cmux.vm.provider.open_cmux_remote",
      "tunnel",
      spanAttributes(vmId, "open_cmux_remote"),
      async (span) => {
        try {
          // The row supplies addresses and immutable auth mode without a
          // provider read. Only a first enrollment may execute the bounded
          // invitation command; known fingerprints remain exec-free. A row
          // without the contract or addresses is refused; older running
          // machines get the contract through the upgrade/backfill runbook.
          const routeAddresses = freestyleRouteAddressesFromMetadata(options?.providerMetadata);
          if (options?.providerMetadata?.cmuxTuiContract !== "snapshot-v2" || !routeAddresses) {
            throw new ProviderMachineRecreateRequiredError(
              "freestyle",
              `VM ${vmId} predates the snapshot-v2 machine contract (no recorded contract or private address); recreate the machine`,
            );
          }
          span.setAttribute("cmux.vm.cmux_tui_contract", "snapshot-v2");
          const route = freestyleCmuxRemoteRoute(routeAddresses, vmId);
          const auth = freestyleRemoteAuthPlan(
            options?.providerMetadata,
            options?.deviceFingerprint,
          );
          const invitation = await freestyleInvitationForAuth(auth, async () => {
            const vm = this.deps.client(EXEC_DEFAULT_TIMEOUT_MS + EXEC_OVERHEAD_TIMEOUT_MS).vms.ref(vmId);
            return await mintCmuxTuiInvitation(this.cmuxTuiInvoke(vm), "freestyle", vmId);
          }, vmId);
          const token = `cmux-freestyle-route-${randomBytes(32).toString("hex")}`;
          const expiresAtUnix = Math.floor(Date.now() / 1000) + ROUTE_TOKEN_TTL_SECONDS;
          const addresses = freestyleNetworkAddressMetadata(routeAddresses);
          span.setAttribute("cmux.vm.network.private", (routeAddresses.vpcs ?? routeAddresses.networks ?? []).length > 0);
          span.setAttribute("cmux.vm.cmux_remote.healed", false);
          span.setAttribute("cmux.vm.cmux_remote.invited", invitation !== undefined);
          const networkAddresses = {
            ...(addresses.networkIpv4 ? { ipv4: addresses.networkIpv4 } : {}),
            ...(addresses.networkIpv6 ? { ipv6: addresses.networkIpv6 } : {}),
          };
          return {
            transport: "cmux-remote" as const,
            route,
            token,
            expiresAtUnix,
            session: CMUX_TUI_SESSION,
            // A released client ignores `invitation` and uses this compatibility
            // bit. A new client that names an enrolled fingerprint uses enrolled
            // auth even on a compatibility image.
            trustedCarrier: auth.trustedCarrier,
            ...(invitation ? { invitation } : {}),
            ...(Object.keys(networkAddresses).length ? { networkAddresses } : {}),
          };
        } catch (err) {
          throw err instanceof ProviderError
            ? err
            : new ProviderError("freestyle", `openCmuxRemote(${vmId}) failed`, err);
        }
      },
    );
  }

  private async announcePrivateAddresses(
    vm: Vm,
    data: FreestyleRouteAddresses,
    options: { readonly validateOnly?: boolean } = {},
  ): Promise<void> {
    const addresses = (data.vpcs ?? data.networks ?? [])
      .flatMap((network) => [network.ipv4, network.ipv6])
      .filter((address): address is string => typeof address === "string" && address.trim() !== "")
      .map((address) => address.trim());
    await Effect.runPromise(announceFreestyleNetwork(vm, addresses, options));
  }


  async approveCmuxRemoteEnrollment(
    vmId: string,
    invitationId: string,
    options?: CmuxRemoteApprovalOptions,
  ): Promise<CmuxRemoteApprovalResult> {
    void options;
    return withVmSpan(
      "cmux.vm.provider.approve_cmux_remote_enrollment",
      "provider",
      spanAttributes(vmId, "approve_cmux_remote_enrollment"),
      async () => {
        try {
          const vm = this.deps.client(40_000 + EXEC_OVERHEAD_TIMEOUT_MS).vms.ref(vmId);
          return await approveCmuxTuiEnrollment(
            this.cmuxTuiCommandRunner(vm),
            "freestyle",
            vmId,
            invitationId,
          );
        } catch (err) {
          throw err instanceof ProviderError
            ? err
            : new ProviderError("freestyle", `approveCmuxRemoteEnrollment(${vmId}) failed`, err);
        }
      },
    );
  }

  /**
   * A machine's HTTP port as a URL the owner's Mac can open: the private VPC
   * address over the WireGuard tunnel, the same path the daemon route takes
   * (see the header). Nothing is minted at the platform and nothing public is
   * opened. The desktop port additionally proves the desktop is up, healing
   * the cmux-desktop unit first when it is not, so the Displays row opens a
   * live screen rather than a connection error. The token exists only for the
   * lease ledger, as with the cmux-remote route.
   */
  async openPort(vmId: string, port: number): Promise<{ url: string; token: string; openUrl: string; expiresAtMs?: number }> {
    return withVmSpan(
      "cmux.vm.provider.open_port",
      "provider",
      spanAttributes(vmId, "open_port", { "cmux.vm.port": port }),
      async (span) => {
        if (!Number.isInteger(port) || port < 1 || port > 65535 || port === CMUX_TUI_PORT) {
          throw new ProviderError("freestyle", `openPort(${vmId}) requires a valid port other than the daemon's ${CMUX_TUI_PORT}`);
        }
        try {
          const fs = this.deps.client();
          const vm = fs.vms.ref(vmId);
          const data = await vm.data();
          const urls = freestylePortUrls(data, vmId, port, this.desktopTransport);
          const desktop = port === desktopListenPort(this.desktopTransport);
          span.setAttribute("cmux.vm.port.desktop", desktop);
          if (desktop) {
            const healed = await this.execResult(vm, freestyleDesktopHealCommand(this.desktopTransport), DESKTOP_HEAL_TIMEOUT_MS);
            if (healed?.exitCode === 3) {
              throw new ProviderError("freestyle", `VM ${vmId} has no desktop: its image carries no desktop layer (a base machine)`);
            }
            if (healed?.exitCode !== 0) {
              throw new ProviderError(
                "freestyle",
                `VM ${vmId}: the desktop did not come up on port ${port} (exit ${healed?.exitCode ?? "n/a"}): ${(healed?.stderr ?? healed?.stdout ?? "").trim().slice(0, 300)}`,
              );
            }
          }
          return {
            ...urls,
            token: `cmux-freestyle-port-${randomBytes(32).toString("hex")}`,
            expiresAtMs: Date.now() + PORT_OPEN_LEASE_TTL_SECONDS * 1000,
          };
        } catch (err) {
          throw err instanceof ProviderError ? err : new ProviderError("freestyle", `openPort(${vmId}, ${port}) failed`, err);
        }
      },
    );
  }

  /**
   * Sign-out cleanup for legacy driver-minted preview leases. Publication
   * rules are owned by the VM-publications workflow and are not touched here.
   */
  async revokeEndpointLeases(vmId: string): Promise<void> {
    return withVmSpan(
      "cmux.vm.provider.revoke_endpoint_leases",
      "provider",
      spanAttributes(vmId, "revoke_endpoint_leases"),
      async () => {
        const fs = this.deps.client();
        const existing = await fs.tls.rules.list({ vmId });
        for (const rule of existing.rules) {
          if (rule.managed || !FREESTYLE_PORT_RULE_DOMAIN_RE.test(rule.domain)) continue;
          await fs.tls.rules.delete(rule.id).catch((err: unknown) => {
            console.error(`[freestyle] revoking legacy port rule ${rule.id} for ${vmId} failed`, err);
          });
        }
      },
    );
  }

  /**
   * A fork or restore resumes a live guest's memory image. Its boot
   * supervisor rebinds the daemon to this machine but leaves the copied
   * session stranded (remoteState.ts), so the daemon never listens. A user
   * snapshot can also carry a stopped supervisor, which nothing restarts in a
   * resumed memory image. Start a stopped supervisor, wait for the rebind,
   * repair that one state, and wait for this machine's listener so the
   * machine is never reported ready while attach would be refused.
   */
  private async awaitForkDaemon(vm: Vm): Promise<void> {
    const ready = await this.execResult(
      vm,
      devboxForkDaemonReadyCommand(FORK_DAEMON_LISTEN_TIMEOUT_SECONDS),
      (FORK_DAEMON_LISTEN_TIMEOUT_SECONDS * 1000) + EXEC_OVERHEAD_TIMEOUT_MS,
    );
    if (!ready || ready.exitCode !== 0) {
      // Only the classified stage is logged and stored: the guest's own
      // output is user-controlled text and never leaves this function.
      const stage = ready ? devboxForkReadinessStage(ready.stderr) : "stage=exec-unavailable";
      console.error("[freestyle] fork daemon readiness failed", stage);
      throw new ProviderError("freestyle", `forked machine daemon did not become ready (${stage})`);
    }
  }

  private async execResult(vm: Vm, command: string, timeoutMs = EXEC_DEFAULT_TIMEOUT_MS): Promise<ExecResult | null> {
    try {
      const r = await vm.exec({ command, timeoutMs, linuxUser: GUEST_LINUX_USER });
      return { exitCode: r.statusCode ?? 124, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
    } catch {
      return null;
    }
  }

  private cmuxTuiInvoke(vm: Vm): CmuxTuiInvoke {
    return async (args, timeoutMs) =>
      await this.execResult(vm, cmuxTuiRunCommand(args), timeoutMs ?? EXEC_DEFAULT_TIMEOUT_MS) ?? {
        exitCode: 124,
        stdout: "",
        stderr: "exec failed",
      };
  }

  private cmuxTuiCommandRunner(vm: Vm): CmuxTuiCommandRunner {
    return {
      runCommand: async (command, timeoutMs) =>
        await this.execResult(vm, command, timeoutMs ?? EXEC_DEFAULT_TIMEOUT_MS) ?? {
          exitCode: 124,
          stdout: "",
          stderr: "exec failed",
        },
    };
  }

}
