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
import { inlineEgressFirewallRules, inlineEgressTlsRules, reconcileFreestyleEgress } from "./freestyleNetworkPolicy";
import { isIP } from "node:net";
import { Effect } from "effect";
import { FreestyleResourceStatsReader } from "./freestyleResourceStatsReader";
import { announceFreestyleNetwork } from "./freestyleNetworkAnnouncement";
import { freestyleRequestFetch } from "./freestyleRequestTiming";
import { currentVmRequestContext } from "../requestContext";
import {
  ProviderError,
  type AttachTransport,
  type CmuxRemoteApprovalResult,
  type CmuxRemoteApprovalOptions,
  type CmuxRemoteAttachOptions,
  type CmuxRemoteEndpoint,
  type CreateOptions,
  type CreateProviderTunnelOptions,
  type ExecOptions,
  type ExecResult,
  type ProviderNetwork,
  type ProviderTunnel,
  type ProviderTunnelCreateResult,
  type RestoreOptions,
  type SnapshotRef,
  type VmEdgeRule,
  type VMHandle,
  type VMPrivateNetworking,
  type VMProvider,
  type VMResizeOptions,
  type VMStats,
  type VMResourceStatsResult,
  type VMStatus,
} from "./types";
import {
  DEVBOX_DESKTOP_NOVNC_PORT,
  DEVBOX_DESKTOP_START_SCRIPT,
  DEVBOX_DESKTOP_UNIT,
  devboxDesktopOpenUrl,
} from "../images/desktop";
import { recordSpanError, setSpanAttributes, withVmSpan } from "../telemetry";
import { parseSshPublicKey, scpPrepareCommand, SCP_KEY_TTL_SECONDS } from "./scp";
import {
  CMUX_TUI_PORT,
  CMUX_TUI_SESSION,
} from "./cmuxTuiDaemon";

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
// Create and trusted-carrier attach therefore use provider metadata and the
// immutable image contract, with no guest exec or filesystem upload.
//
// NO-WORK INVARIANT (read before adding a provider call to create, restore,
// resume, or openCmuxRemote). These paths are on the user's New Machine
// critical path, and every provider round trip here is paid on every create:
//   - create: one `vms.create` with VPC and TLS rules inline. No resize (each
//     size has its own snapshot), no `vm.exec`, no `vm.fs` write, no
//     readiness poll, no second provider read.
//   - restore/resume: no guest exec; the baked supervisor owns the daemon.
//   - openCmuxRemote: built from the row's providerMetadata alone. No guest
//     exec, no install, no "heal", no enrollment round trip.
// If the guest needs a new binary, file, hook, package, or setting, bake it
// into the devbox snapshot (web/scripts/build-devbox-freestyle.ts, the boot
// supervisor in services/vms/images/devbox/cmux-devbox-boot) and bump
// images/manifest.json. If it needs per-machine identity, derive it in the
// guest at boot from the platform instance id, or fetch it asynchronously
// from the guest (cmux-prompt-sync) without gating terminal access. Old
// images without `cmuxTuiContract: "snapshot-v2"` are refused on purpose;
// do not reintroduce create- or attach-time healing to support them.
// Explicit user operations (`exec`, `resize`, file push/pull) are separate
// and stay. The one sanctioned guest exec around create is the prompt-name
// push in workflows.ts (schedulePromptIdentityPush): display-only, run after
// the response, never awaited by create. Do not add anything else to it.
//
// The coderouter model plane is edge-injected: the create carries an inline
// `tls` rule for the coderouter host whose transform overwrites `x-cmux-authorization` to every request the
// guest makes there. The platform steers the host to its edge (/etc/hosts) and
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
const CREATE_TIMEOUT_MS = 15 * 60 * 1000;
const SNAPSHOT_TIMEOUT_MS = 15 * 60 * 1000;
/** Page size and ceiling for `listSnapshots`; a machine rarely has more than a handful. */
const SNAPSHOT_LIST_PAGE = 100;
const SNAPSHOT_LIST_MAX = 1_000;
const EXEC_DEFAULT_TIMEOUT_MS = 30_000;
/** Cloud machines are durable boxes; only an explicit pause/stop should put one to sleep. */
export const FREESTYLE_PERSISTENT_IDLE_TIMEOUT_SECONDS = -1;
/** The exec API rejects timeoutMs above 300000 (5 minutes per exec). */
const MAX_EXEC_TIMEOUT_MS = 300_000;
const EXEC_OVERHEAD_TIMEOUT_MS = 15_000;
const ROUTE_TOKEN_TTL_SECONDS = 12 * 60 * 60;
const EDGE_DOMAIN = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/i;

/**
 * The seam tests replace: the SDK client. There is deliberately no daemon
 * manifest resolver here; the driver never installs or repairs cmux-tui (the
 * snapshot owns it, see NO-WORK INVARIANT above).
 */
export type FreestyleProviderDependencies = {
  readonly client: (timeoutMs?: number) => Freestyle;
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
 * connection in undici's pool. Best effort, never awaited for correctness.
 */
export function preconnectFreestyle(): void {
  const baseUrl = process.env.FREESTYLE_API_URL?.trim() || "https://api.freestyle.sh";
  fetch(`${baseUrl}/`, { method: "HEAD", signal: AbortSignal.timeout(3_000) }).catch(() => undefined);
}

/** Exported for the publication provider, which shares this account-wide client. */
export function freestyleClient(timeoutMs = DEFAULT_TIMEOUT_MS): Freestyle {
  const longFetch = freestyleRequestFetch({
    timeoutMs,
    record: process.env.NODE_ENV === "development" ? (event) => {
      const traceId = currentVmRequestContext()?.traceId;
      console.info("cmux.vm.freestyle.request", JSON.stringify({
        ...event, traceId: traceId && /^[0-9a-f]{32}$/.test(traceId) ? traceId : undefined,
      }));
    } : undefined,
  });
  const baseUrl = process.env.FREESTYLE_API_URL?.trim() || undefined;
  const apiKey = process.env.FREESTYLE_API_KEY?.trim();
  if (apiKey) return new Freestyle({ apiKey, baseUrl, fetch: longFetch });
  const stackAccessToken = process.env.FREESTYLE_STACK_ACCESS_TOKEN?.trim();
  const teamId = process.env.FREESTYLE_TEAM_ID?.trim();
  if (stackAccessToken && teamId) {
    return new Freestyle({ stackAccessToken, teamId, baseUrl, fetch: longFetch });
  }
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
export function freestyleFirewallRules(options?: { publicDaemonIngress?: boolean; networkRules?: NetworkRulePlan }) {
  const rules: Array<{
    action: "allow";
    source: { public?: true };
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
 * app to append its display options to.
 */
export function freestylePortUrls(addresses: FreestyleRouteAddresses, vmId: string, port: number): { url: string; openUrl: string } {
  const address = freestylePortAddress(addresses, vmId);
  const host = address.includes(":") ? `[${address}]` : address;
  const url = `http://${host}:${port}/`;
  return { url, openUrl: port === DEVBOX_DESKTOP_NOVNC_PORT ? devboxDesktopOpenUrl(address) : url };
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
export function freestyleDesktopHealCommand(): string {
  return (
    `[ -x ${DEVBOX_DESKTOP_START_SCRIPT} ] || exit 3; ` +
    `if [ -d /run/systemd/system ]; then systemctl start ${DEVBOX_DESKTOP_UNIT} || exit 1; fi; ` +
    `ss -tln 2>/dev/null | grep -q ':${DEVBOX_DESKTOP_NOVNC_PORT} '`
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
  if (err instanceof FreestyleApiError) {
    return (err.status === 409 && err.code === "CONFLICT") || err.status >= 500;
  }
  return true;
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
  async ensureNetwork(options: { slug: string; displayName?: string; heal?: boolean }): Promise<ProviderNetwork> {
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
          await this.ensureMembersRule(fs, existing.id);
          setSpanAttributes(span, { "cmux.vm.network.id": existing.id, "cmux.vm.network.created": false });
          return existing;
        }
        try {
          // The CIDRs are deliberately left to the platform: a derived /24 out
          // of 10.0.0.0/8 and a unique-local /64 both sit inside a tunnel's
          // default routes, so no cmux code has to allocate address space.
          const { data } = await fs.vpc.create({
            slug,
            displayName: options.displayName,
            firewall: { rules: FREESTYLE_NETWORK_FIREWALL_RULES },
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
            await this.ensureMembersRule(fs, existing.id);
            setSpanAttributes(span, { "cmux.vm.network.id": existing.id, "cmux.vm.network.created": false });
            return existing;
          }
          throw new ProviderError("freestyle", `ensureNetwork(${slug})`, err);
        }
      },
    );
  }

  async getNetwork(networkId: string): Promise<ProviderNetwork | null> {
    try {
      return mapFreestyleNetwork(await this.client().vpc.get(networkId));
    } catch (err) {
      if (isNotFound(err)) return null;
      throw new ProviderError("freestyle", `getNetwork(${networkId})`, err);
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
            throw new ProviderError("freestyle", `createTunnel(${options.slug})`, err);
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
      throw new ProviderError("freestyle", `getTunnel(${tunnelId})`, err);
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

export class FreestyleProvider implements VMProvider {
  readonly id = "freestyle" as const;

  /** The normal terminal transport. SSH is an explicit legacy attach verb, not the default. */
  readonly attachTransports: readonly AttachTransport[] = ["cmux-remote"];

  /** ``create`` honors requested memory through the grow-only size ladder. */
  /// Freestyle exposes live resource statistics and grow-only resizing.
  readonly capabilities = { stats: true, sizing: true, desktop: true } as const;

  readonly privateNetworking: VMPrivateNetworking;
  private readonly resourceStats: FreestyleResourceStatsReader;

  constructor(
    private readonly deps: FreestyleProviderDependencies = {
      client: freestyleClient,
    },
  ) {
    this.privateNetworking = new FreestylePrivateNetworking(this.deps.client);
    this.resourceStats = new FreestyleResourceStatsReader(this.deps.client);
  }

  async prepareSCP(vmId: string, publicKey: string): Promise<import("./types").SCPEndpoint> {
    return withVmSpan("cmux.vm.provider.prepare_scp", "provider", spanAttributes(vmId, "prepare_scp"), async () => {
      const key = parseSshPublicKey(publicKey);
      const vm = this.deps.client().vms.ref(vmId);
      const data = await vm.data();
      const host = freestylePortAddress(data, vmId);
      const expires = new Date(Date.now() + SCP_KEY_TTL_SECONDS * 1000);
      const result = await this.execResult(vm, scpPrepareCommand(key, expires));
      if (!result || result.exitCode !== 0) {
        throw new ProviderError("freestyle", `SCP preparation failed in ${vmId}: ${(result?.stderr || "SSH server unavailable").slice(0, 500)}`);
      }
      let hostPublicKey: string;
      try { hostPublicKey = parseSshPublicKey(result.stdout); }
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
          const fs = this.deps.client(CREATE_TIMEOUT_MS);
          const networkId = options.network?.id;
          const { vm, vmId, data } = await fs.vms.create({
            snapshotId: image,
            displayName: "cmux Cloud VM",
            // Do not let an account/provider idle default turn a persistent
            // machine into a one-shot box. Explicit pause/stop still works.
            idleTimeoutSeconds: FREESTYLE_PERSISTENT_IDLE_TIMEOUT_SECONDS,
            ...(options.runtimeBudgetSeconds !== undefined ? {
              maxRunTotalSeconds: Math.max(0, Math.floor(options.runtimeBudgetSeconds)), automaticRestart: false,
            } : {}),
            metadata: { cmux: "cloud" },
            firewall: { rules: freestyleFirewallRules({ publicDaemonIngress: !networkId, networkRules: options.networkRules }) },
            ...(networkId ? { vpcs: [{ vpcId: networkId, ipv4: true, ipv6: true }] } : {}),
            ...(tlsRules ? { tls: { rules: tlsRules } } : {}),
          });
          setSpanAttributes(span, {
            "cmux.vm.id": vmId,
            "cmux.vm.network.private": !!networkId,
          });
          try {
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
            if (options.imageSize) {
              setSpanAttributes(span, {
                "cmux.vm.image_size": options.imageSize.name,
                "cmux.vm.resources.cpu": options.imageSize.cpu,
                "cmux.vm.resources.memory_mb": options.imageSize.memoryMb,
                "cmux.vm.resources.storage_mb": options.imageSize.storageMb,
                "cmux.vm.resize.requested": false,
              });
            } else {
              setSpanAttributes(span, {
                "cmux.vm.resources.cpu": data.resources?.cpu ?? 0,
                "cmux.vm.resources.memory_mb": data.resources?.memory ?? 0,
                "cmux.vm.resources.storage_mb": data.resources?.storage ?? 0,
                "cmux.vm.resize.requested": false,
              });
            }
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
            // machine's private IP (and an operator can trace it to its owner's
            // VPC) without a provider round trip. Attach still reads the live
            // address from vm.data(): this records where the machine was
            // placed, never where to dial it.
            providerMetadata: {
              ...(options.providerMetadata ?? {}),
              cmuxTuiContract: "snapshot-v2",
              ...(networkId ? { networkId } : {}),
              ...(freestyleNetworkAddressMetadata(data)),
            },
          };
        } catch (err) {
          throw err instanceof ProviderError ? err : new ProviderError("freestyle", `create(${image}) failed`, err);
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
          throw new ProviderError("freestyle", `applyNetworkPolicy(${vmId})`, err);
        }
      },
    );
  }

  async destroy(vmId: string): Promise<void> {
    return withVmSpan(
      "cmux.vm.provider.destroy",
      "provider",
      spanAttributes(vmId, "destroy"),
      async () => {
        try {
          await this.deps.client().vms.ref(vmId).delete();
        } catch (err) {
          if (isNotFound(err)) return; // already gone; destroy is idempotent
          throw new ProviderError("freestyle", `destroy(${vmId})`, err);
        }
      },
    );
  }

  async getStatus(vmId: string): Promise<VMStatus> {
    return withVmSpan(
      "cmux.vm.provider.get_status",
      "provider",
      spanAttributes(vmId, "get_status"),
      async (span) => {
        try {
          const data = await this.deps.client().vms.get(vmId);
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
          const fs = this.deps.client(timeoutMs + EXEC_OVERHEAD_TIMEOUT_MS);
          const vm = fs.vms.ref(vmId);
          const r = await vm.exec({ command, timeoutMs, linuxUser: GUEST_LINUX_USER });
          // statusCode is null when the guest killed the command at its timeout.
          const exitCode = r.statusCode ?? 124;
          setSpanAttributes(span, { "cmux.exec.exit_code": exitCode });
          return { exitCode, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
        } catch (err) {
          throw new ProviderError("freestyle", `exec(${vmId})`, err);
        }
      },
    );
  }

  /** Read provisioned dimensions without waking the guest or inventing usage gauges. */
  async getStats(vmId: string): Promise<VMStats> {
    return withVmSpan(
      "cmux.vm.provider.get_stats",
      "provider",
      spanAttributes(vmId, "getStats"),
      async () => {
        try {
          const data = await this.deps.client().vms.get(vmId);
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

  async listSnapshots(vmId: string): Promise<SnapshotRef[]> {
    return withVmSpan(
      "cmux.vm.provider.list_snapshots",
      "provider",
      spanAttributes(vmId, "listSnapshots"),
      async (span) => {
        try {
          const fs = this.deps.client();
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
            idleTimeoutSeconds: FREESTYLE_PERSISTENT_IDLE_TIMEOUT_SECONDS,
            metadata: { cmux: "cloud" },
            firewall: { rules: freestyleFirewallRules({ publicDaemonIngress: !networkId, networkRules: options?.networkRules }) },
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
              ...(networkId ? { networkId, ...freestyleNetworkAddressMetadata(data) } : {}),
            },
          };
        } catch (err) {
          throw err instanceof ProviderError ? err : new ProviderError("freestyle", `restore(${snapshotId})`, err);
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
          // Attach never runs guest work (NO-WORK INVARIANT at the top of this
          // file). A snapshot-v2 row carries its private addresses, so attach
          // is pure metadata. A row from before this contract was recorded
          // still gets the same answer: every image baked since 2026-09-06
          // (#12042) serves the trusted listener, and an older one fails at
          // connect instead of being healed here. Only a row that never
          // recorded its addresses pays one provider read; the workflow then
          // persists them, so it happens once per machine.
          const persisted = freestyleRouteAddressesFromMetadata(options?.providerMetadata);
          const routeAddresses = persisted ?? await this.deps.client().vms.ref(vmId).data();
          span.setAttribute("cmux.vm.cmux_tui_contract", String(options?.providerMetadata?.cmuxTuiContract ?? "none"));
          const route = freestyleCmuxRemoteRoute(routeAddresses, vmId);
          const token = `cmux-freestyle-route-${randomBytes(32).toString("hex")}`;
          const expiresAtUnix = Math.floor(Date.now() / 1000) + ROUTE_TOKEN_TTL_SECONDS;
          const addresses = freestyleNetworkAddressMetadata(routeAddresses);
          span.setAttribute("cmux.vm.network.private", (routeAddresses.vpcs ?? routeAddresses.networks ?? []).length > 0);
          span.setAttribute("cmux.vm.route.source", persisted ? "row" : "provider");
          span.setAttribute("cmux.vm.cmux_remote.healed", false);
          span.setAttribute("cmux.vm.cmux_remote.invited", false);
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
            trustedCarrier: true,
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
    void invitationId;
    throw new ProviderError("freestyle", `VM ${vmId} uses trusted-carrier attach and has no enrollment approval path`);
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
          const urls = freestylePortUrls(data, vmId, port);
          const desktop = port === DEVBOX_DESKTOP_NOVNC_PORT;
          span.setAttribute("cmux.vm.port.desktop", desktop);
          if (desktop) {
            const healed = await this.execResult(vm, freestyleDesktopHealCommand(), DESKTOP_HEAL_TIMEOUT_MS);
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

  private async execResult(vm: Vm, command: string, timeoutMs = EXEC_DEFAULT_TIMEOUT_MS): Promise<ExecResult | null> {
    try {
      const r = await vm.exec({ command, timeoutMs, linuxUser: GUEST_LINUX_USER });
      return { exitCode: r.statusCode ?? 124, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
    } catch {
      return null;
    }
  }

}

