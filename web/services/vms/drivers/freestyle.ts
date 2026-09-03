import {
  Freestyle,
  FreestyleApiError,
  type ResizeVmOptions,
  type TunnelData,
  type VmData,
  type VmResources,
  type Vm,
  type VpcData,
} from "freestyle";
import { randomBytes } from "node:crypto";
import {
  ProviderError,
  type AttachEndpoint,
  type AttachOptions,
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
  type RestoreOptions,
  type SSHEndpoint,
  type SnapshotRef,
  type VmEdgeRule,
  type VMHandle,
  type VMPrivateNetworking,
  type VMProvider,
  type VMStatus,
} from "./types";
import { PLAN_MACHINE_MEMORY_MB, vcpusForMemoryMb, vmDiskMb } from "../machineSpec";
import {
  DEVBOX_DESKTOP_NOVNC_PORT,
  DEVBOX_DESKTOP_START_SCRIPT,
  DEVBOX_DESKTOP_UNIT,
  devboxDesktopOpenUrl,
} from "../images/desktop";
import { recordSpanError, setSpanAttributes, withVmSpan } from "../telemetry";
import {
  CMUX_TUI_BINARY_PATH,
  CMUX_TUI_INSTALL_TIMEOUT_MS,
  CMUX_TUI_PORT,
  CMUX_TUI_SESSION,
  approveCmuxTuiEnrollment,
  CMUX_TUI_ATTACH_BUNDLE_NOT_READY_EXIT,
  cmuxTuiAttachBundleCommand,
  cmuxTuiDaemonBuild,
  cmuxTuiDaemonCommand,
  cmuxTuiInstallCommand,
  cmuxTuiPinCheckCommand,
  mintCmuxTuiInvitation,
  parseCmuxTuiAttachBundle,
  resolveCmuxTuiSource,
  type CmuxTuiSource,
  waitForCmuxTuiReady,
  type CmuxTuiInvoke,
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
// sets CMUX_TUI_REMOTE_WS_BIND=[::]:1337 and the driver re-asserts it on heal —
// which is also what makes a VPC address reachable, since it is neither
// loopback nor the public NIC.
//
// Creates take NO ports field, NO create-time env, and NO systemd injection;
// `firewall` is mandatory. Model-plane env is delivered by writing the
// persisted /root/.config/cmux/model-plane.env file (0600) that
// /etc/cmux/agent-config.sh already sources when the boot env is absent.
//
// Create runs no guest bootstrap. The devbox snapshot carries the pinned
// cmux-tui build and the cmux-tui-daemon systemd unit, and its supervisor
// (services/vms/images/devbox/cmux-devbox-boot) starts the daemon with a
// fresh identity as soon as the machine resumes, keyed on the platform
// instance id. Create is therefore `vms.create`, the grow-only resize, and one
// file write; attach heals a daemon that is not yet, or no longer, listening.
//
// The coderouter model plane is edge-injected: the create carries an inline
// `tls` rule for the coderouter host whose transform adds
// `x-coderouter-route-token` and `x-cmux-vm-id` to every request the guest
// makes there. The platform steers the host to its edge (/etc/hosts) and
// installs its CA at boot; rules added after boot never reach a running
// guest, so the rule must be inline. The env file holds only base URLs and
// placeholder keys: no token is ever written into the guest. Injection
// becomes active 20-30 s after boot, so create ends with a guest-side probe
// of https://<host>/api/coderouter/vm-usage/self (a 200 proves the injected
// token is bound to this machine) and rolls the machine back if it never
// succeeds.
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
 * Every guest command runs as root. The 0.2 API's `linuxUser` default is not
 * root but "the account holding uid 1000, or root in an image with no such
 * account", and the cmux devbox image ships a uid-1000 user — so leaving this
 * off would silently move the daemon, its install, and the model-plane write
 * off the root layout they are baked around.
 */
const GUEST_LINUX_USER = "root";

const DEFAULT_TIMEOUT_MS = 60_000;
const CREATE_TIMEOUT_MS = 15 * 60 * 1000;
const SNAPSHOT_TIMEOUT_MS = 15 * 60 * 1000;
const EXEC_DEFAULT_TIMEOUT_MS = 30_000;
/** The exec API rejects timeoutMs above 300000 (5 minutes per exec). */
const MAX_EXEC_TIMEOUT_MS = 300_000;
const EXEC_OVERHEAD_TIMEOUT_MS = 15_000;
const ROUTE_TOKEN_TTL_SECONDS = 12 * 60 * 60;
/** Guest-side edge probe: 30 attempts x (5 s curl + 2 s sleep) worst case, under the 300 s exec cap. */
const EDGE_DOMAIN = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/i;
const ROUTE_TOKEN_GRAMMAR = /\bcrt_[A-Za-z0-9._-]+/;

/**
 * The seams tests replace: the SDK client and the cmux-tui manifest read.
 * Production uses the env-configured client and the live manifest.
 */
export type FreestyleProviderDependencies = {
  readonly client: (timeoutMs?: number) => Freestyle;
  readonly resolveDaemonSource: typeof resolveCmuxTuiSource;
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

function freestyleClient(timeoutMs = DEFAULT_TIMEOUT_MS): Freestyle {
  const longFetch: typeof fetch = (input, init) =>
    fetch(input as Request, { ...(init ?? {}), signal: AbortSignal.timeout(timeoutMs) });
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
 * Outbound is always open (package installs, files.cmux.com, agents). Inbound
 * is the interesting half:
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
export function freestyleFirewallRules(options?: { publicDaemonIngress?: boolean }) {
  const rules: Array<{
    action: "allow";
    source: { public?: true };
    destination: { public?: true; port?: number; protocol?: "tcp" };
  }> = [{ action: "allow", source: {}, destination: { public: true } }];
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
    ...(ipv4 ? { networkIpv4: ipv4 } : {}),
    ...(ipv6 ? { networkIpv6: ipv6 } : {}),
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

/**
 * Nothing that reaches the guest (env file, exec command) may carry a route
 * token: the token lives only in the edge rule. Throws on the `crt_` grammar.
 */
export function assertNoRouteTokenInGuestPayload(values: Iterable<string>, what: string): void {
  for (const value of values) {
    if (ROUTE_TOKEN_GRAMMAR.test(value)) {
      throw new ProviderError("freestyle", `refusing to write a coderouter route token into the guest (${what})`);
    }
  }
}

/**
 * The persisted model-plane env file, byte-compatible with what
 * /etc/cmux/agent-config.sh itself writes from a boot env: shells that see no
 * boot env source this copy and then materialize the codex/pi/opencode
 * configs. Freestyle has no create-time env, so the driver writes the file.
 * Every key is rendered; OPENAI_BASE_URL is the anchor the generator keys on,
 * so its absence means "no model plane" and nothing is written.
 */
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
 * Healthy = the daemon process is up AND something listens on 1337 in the v6
 * table (a dual-stack `[::]` bind; 0x0539 = 1337). A daemon bound 0.0.0.0 only
 * appears in /proc/net/tcp, is unreachable at the public IPv6, and must be
 * restarted under the dual-stack override.
 */
/**
 * Is the installed binary the machine's pinned build? A baked image records
 * the pin it was built with in /etc/cmux/cmux-tui-pin (`<sha256> <commit>`),
 * and that is the version contract for every machine from that snapshot: the
 * heal reinstalls only a missing or corrupt binary, never one the live
 * files.cmux.com manifest has since moved past (a new pin ships by rebake).
 * Images without the file were installed from the live pin at create, so the
 * live pin stays their reference.
 */
export function freestylePinCheckCommand(source: CmuxTuiSource): string {
  return (
    "if [ -s /etc/cmux/cmux-tui-pin ]; then " +
    `test -x ${CMUX_TUI_BINARY_PATH} && printf '%s  %s\\n' "$(cut -d' ' -f1 /etc/cmux/cmux-tui-pin)" ${CMUX_TUI_BINARY_PATH} | sha256sum -c >/dev/null 2>&1; ` +
    `else ${cmuxTuiPinCheckCommand(source)}; fi`
  );
}

/** How long the heal lets a baked supervisor bring the daemon up before restarting it. */
const DAEMON_SETTLE_TIMEOUT_MS = 3_000;

/**
 * Healthy now, or healthy within the settle budget on an image whose
 * supervisor binds the daemon to the instance id (it ships
 * /etc/cmux/bake-instance-id) and is active. A machine attached right after
 * create is inside the sub-second window before that supervisor has started
 * the daemon; restarting the unit there costs a second and a half, waiting
 * costs a few hundred milliseconds. Older images take the immediate check.
 */
export function freestyleDaemonSettledCommand(): string {
  const healthy = freestyleDaemonHealthyCommand();
  const ticks = Math.floor(DAEMON_SETTLE_TIMEOUT_MS / 100);
  return (
    "if [ -f /etc/cmux/bake-instance-id ] && systemctl is-active cmux-tui-daemon >/dev/null 2>&1; then " +
    `for i in $(seq 1 ${ticks}); do { ${healthy}; } && exit 0; sleep 0.1; done; exit 1; ` +
    `else ${healthy}; fi`
  );
}

export function freestyleDaemonHealthyCommand(): string {
  // [s]tart: pgrep -f would otherwise match the exec shell carrying this command line.
  // On an image whose supervisor binds the daemon identity to the instance id
  // (it ships /etc/cmux/bake-instance-id), the daemon is healthy only when the
  // bound id is this machine's: a clone of a live machine briefly runs the
  // source machine's daemon until the supervisor re-keys it, and an
  // invitation minted from that daemon would name the wrong fingerprint.
  return (
    "pgrep -f 'cmux-tui server [s]tart' >/dev/null 2>&1 && grep -qi ':0539 ' /proc/net/tcp6" +
    " && { [ ! -f /etc/cmux/bake-instance-id ] || [ \"$(cat /etc/cmux/daemon-instance-id 2>/dev/null)\" = \"$(" +
    "curl -sf -m 2 -H \"X-aws-ec2-metadata-token: $(curl -sf -m 2 -X PUT http://169.254.169.254/latest/api/token -H 'X-metadata-token-ttl-seconds: 60')\" http://169.254.169.254/latest/meta-data/instance-id" +
    ")\" ]; }"
  );
}

const REMOTE_WS_BIND_OVERRIDE =
  "/etc/systemd/system/cmux-tui-daemon.service.d/10-cmux-remote-ws-bind.conf";

/**
 * (Re)start the daemon listening dual-stack. Under systemd (the baked
 * cmux-tui-daemon unit), install a drop-in setting
 * CMUX_TUI_REMOTE_WS_BIND=[::]:1337 — the env cmux-devbox-boot reads — then
 * restart the unit, healing machines from bakes that predate the env default.
 * Without systemd (or the unit), fall back to a direct daemon launch with the
 * dual-stack bind.
 */
export function freestyleStartDaemonCommand(): string {
  return [
    "if [ -d /run/systemd/system ] && [ -f /etc/systemd/system/cmux-tui-daemon.service ]; then",
    `mkdir -p ${REMOTE_WS_BIND_OVERRIDE.replace(/\/[^/]+$/, "")};`,
    `printf '[Service]\\nEnvironment=CMUX_TUI_REMOTE_WS_BIND=${FREESTYLE_REMOTE_WS_BIND}\\n' > ${REMOTE_WS_BIND_OVERRIDE};`,
    "systemctl daemon-reload;",
    "systemctl restart cmux-tui-daemon;",
    "else",
    `pgrep -f 'cmux-tui server [s]tart' >/dev/null 2>&1 || (setsid nohup sh -c '${cmuxTuiDaemonCommand(FREESTYLE_REMOTE_WS_BIND)}' >>/tmp/cmux-tui-daemon.log 2>&1 &);`,
    "fi",
  ].join(" ");
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
      { "cmux.vm.provider": "freestyle", "cmux.vm.operation": "ensure_network", "cmux.vm.network.slug": slug, "cmux.vm.network.heal": options.heal === true },
      async (span) => {
        const fs = freestyleClient();
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
          // The slug is unique per account: the loser of a race, or a create
          // for a user whose row was lost, is told the name is taken, and the
          // existing network is the right answer.
          const existing = await this.readNetworkBySlug(fs, slug);
          if (existing) {
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
      return mapFreestyleNetwork(await freestyleClient().vpc.get(networkId));
    } catch (err) {
      if (isNotFound(err)) return null;
      throw new ProviderError("freestyle", `getNetwork(${networkId})`, err);
    }
  }

  async deleteNetwork(networkId: string): Promise<void> {
    try {
      await freestyleClient().vpc.delete(networkId);
    } catch (err) {
      if (isNotFound(err)) return; // already gone; delete is idempotent
      throw new ProviderError("freestyle", `deleteNetwork(${networkId})`, err);
    }
  }

  async createTunnel(options: CreateProviderTunnelOptions): Promise<ProviderTunnel> {
    const clientPublicKey = options.clientPublicKey.trim();
    if (!clientPublicKey) {
      throw new ProviderError("freestyle", "createTunnel requires the client's public key");
    }
    return withVmSpan(
      "cmux.vm.provider.create_tunnel",
      {
        "cmux.vm.provider": "freestyle",
        "cmux.vm.operation": "create_tunnel",
        "cmux.vm.network.id": options.networkId,
      },
      async (span) => {
        try {
          // clientPublicKey is always supplied, so the platform never mints or
          // holds a private key: the config comes back with a blank PrivateKey
          // for the Mac to fill in from its own Keychain.
          const data = await freestyleClient().tunnels.create({
            slug: options.slug,
            displayName: options.displayName,
            clientPublicKey,
            vpcs: [{ vpcId: options.networkId }],
          });
          const tunnel = mapFreestyleTunnel(data, options.networkId);
          setSpanAttributes(span, { "cmux.vm.tunnel.id": tunnel.id });
          return tunnel;
        } catch (err) {
          throw new ProviderError("freestyle", `createTunnel(${options.slug})`, err);
        }
      },
    );
  }

  async getTunnel(tunnelId: string, networkId: string): Promise<ProviderTunnel | null> {
    try {
      const fs = freestyleClient();
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
      const data = await freestyleClient().tunnels.rotateKey(tunnelId, { clientPublicKey: key });
      return mapFreestyleTunnel(data, networkId);
    } catch (err) {
      throw new ProviderError("freestyle", `rotateTunnelKey(${tunnelId})`, err);
    }
  }

  async deleteTunnel(tunnelId: string): Promise<void> {
    try {
      await freestyleClient().tunnels.delete(tunnelId);
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
      // Heal is best-effort on the reuse path: a transient listing failure
      // must not block machine creation on a network that is almost always
      // already correct.
      console.error(`[freestyle] members-rule heal failed for ${networkId}`, err);
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

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

function spanAttributes(vmId: string, operation: string, extra: Record<string, string | number | boolean> = {}) {
  return {
    "cmux.vm.provider": "freestyle",
    "cmux.vm.operation": operation,
    "cmux.vm.id": vmId,
    ...extra,
  };
}

export class FreestyleProvider implements VMProvider {
  readonly id = "freestyle" as const;

  /** The only session transport: the cmux-tui remote daemon (`openCmuxRemote`). */
  readonly attachTransports: readonly AttachTransport[] = ["cmux-remote"];

  constructor(
    private readonly deps: FreestyleProviderDependencies = {
      client: freestyleClient,
      resolveDaemonSource: resolveCmuxTuiSource,
    },
  ) {}

  readonly privateNetworking: VMPrivateNetworking = new FreestylePrivateNetworking();

  async create(options: CreateOptions): Promise<VMHandle> {
    const image = options.image.trim();
    if (!image) {
      throw new ProviderError("freestyle", "create requires a resolved image");
    }
    const tlsRules = freestyleEdgeRules(options.edgeRules);
    return withVmSpan(
      "cmux.vm.provider.create",
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
            metadata: { cmux: "cloud" },
            firewall: { rules: freestyleFirewallRules({ publicDaemonIngress: !networkId }) },
            ...(networkId ? { vpcs: [{ vpcId: networkId, ipv4: true, ipv6: true }] } : {}),
            ...(tlsRules ? { tls: { rules: tlsRules } } : {}),
          });
          setSpanAttributes(span, {
            "cmux.vm.id": vmId,
            "cmux.vm.network.private": !!networkId,
          });
          try {
            if (options.imageSize) {
              // One snapshot per size: the machine already boots at the shape
              // that was sold, so nothing is read back and nothing is grown.
              setSpanAttributes(span, {
                "cmux.vm.image_size": options.imageSize.name,
                "cmux.vm.resources.cpu": options.imageSize.cpu,
                "cmux.vm.resources.memory_mb": options.imageSize.memoryMb,
                "cmux.vm.resources.storage_mb": options.imageSize.storageMb,
                "cmux.vm.resize.requested": false,
              });
            } else {
              // A size-less image boots at its snapshot's resources and only a
              // grow-only resize raises them. Size first so the machine the
              // daemon comes up on is the one that was sold.
              await this.growToRequestedSize(fs, vm, vmId, options.memoryMb, span);
            }
            // The baked supervisor is already bringing the daemon up; the only
            // per-machine input it needs is the model-plane env file.
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

  /**
   * Grow the VM to the requested memory (the plan machine when the caller
   * sent none), the vCPUs that memory implies, and the plan disk. Freestyle
   * resize is grow-only, so only larger dimensions are sent; a snapshot that
   * already carries the size is a no-op.
   */
  private async growToRequestedSize(
    fs: Freestyle,
    vm: Vm,
    vmId: string,
    memoryMb: number | undefined,
    span: Parameters<typeof setSpanAttributes>[0],
  ): Promise<void> {
    const current = (await fs.vms.get(vmId)).resources;
    const target = freestyleTargetResources(memoryMb ?? PLAN_MACHINE_MEMORY_MB);
    const request = freestyleResizeRequest(current, target);
    setSpanAttributes(span, {
      "cmux.vm.resources.cpu": target.cpu,
      "cmux.vm.resources.memory_mb": target.memory,
      "cmux.vm.resources.storage_mb": target.storage,
      "cmux.vm.resize.requested": request !== null,
    });
    if (!request) return;
    await vm.resize(request);
  }

  async destroy(vmId: string): Promise<void> {
    return withVmSpan(
      "cmux.vm.provider.destroy",
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

  async resume(vmId: string): Promise<VMHandle> {
    return withVmSpan(
      "cmux.vm.provider.resume",
      spanAttributes(vmId, "resume"),
      async (span) => {
        try {
          const fs = this.deps.client(CREATE_TIMEOUT_MS);
          const vm = fs.vms.ref(vmId);
          const data = await vm.start();
          const status = mapFreestyleState(data.state);
          setSpanAttributes(span, { "cmux.vm.provider_state": data.state, "cmux.vm.status": status });
          // A memory-preserving pause keeps the daemon; a cold boot (the VM had
          // stopped) relies on the baked systemd unit. Heal best-effort so the
          // first attach doesn't race the unit; attach re-verifies anyway.
          try {
            await this.ensureCmuxTuiRunning(vm, vmId);
          } catch (healErr) {
            recordSpanError(span, healErr);
          }
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
      spanAttributes(vmId, "exec", {
        "cmux.command_length": command.length,
        "cmux.timeout_ms": timeoutMs,
      }),
      async (span) => {
        try {
          const fs = this.deps.client(timeoutMs + EXEC_OVERHEAD_TIMEOUT_MS);
          const r = await fs.vms.ref(vmId).exec({ command, timeoutMs, linuxUser: GUEST_LINUX_USER });
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

  async snapshot(vmId: string, name?: string): Promise<SnapshotRef> {
    return withVmSpan(
      "cmux.vm.provider.snapshot",
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

  async restore(snapshotId: string, options?: RestoreOptions): Promise<VMHandle> {
    const tlsRules = freestyleEdgeRules(options?.edgeRules);
    return withVmSpan(
      "cmux.vm.provider.restore",
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
            metadata: { cmux: "cloud" },
            firewall: { rules: freestyleFirewallRules({ publicDaemonIngress: !networkId }) },
            ...(networkId ? { vpcs: [{ vpcId: networkId, ipv4: true, ipv6: true }] } : {}),
            ...(tlsRules ? { tls: { rules: tlsRules } } : {}),
          });
          setSpanAttributes(span, {
            "cmux.vm.id": vmId,
            "cmux.vm.network.private": !!networkId,
          });
          // The snapshot carries the installed binary and a persisted
          // model-plane file with placeholders only; heal best-effort so the
          // machine is attach-ready without failing restore on a transient
          // daemon error. The new machine's env (its own VM id) and edge rule
          // are mandatory: a snapshot never carries a token, so the restored
          // machine is unusable until its own injection is live.
          await this.ensureCmuxTuiRunning(vm, vmId).catch(() => undefined);
          try {
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
      spanAttributes(vmId, "open_cmux_remote"),
      async (span) => {
        try {
          const fs = this.deps.client(CMUX_TUI_INSTALL_TIMEOUT_MS + EXEC_OVERHEAD_TIMEOUT_MS);
          const vm = fs.vms.ref(vmId);
          // The row already holds the private addresses from create; only a
          // public-ingress machine needs the provider read for its IPv6.
          const persisted = freestyleRouteAddressesFromMetadata(options?.providerMetadata);
          const data = persisted ?? await vm.data();
          const route = freestyleCmuxRemoteRoute(data, vmId);
          span.setAttribute("cmux.vm.network.private", (data.vpcs ?? data.networks ?? []).length > 0);
          span.setAttribute("cmux.vm.route.source", persisted ? "row" : "provider");
          // Direct-IPv6 carries no URL token; this one exists only for the
          // lease ledger. The daemon's Noise enrollment is the session gate —
          // the same trust model as E2B's public proxy route.
          const token = `cmux-freestyle-route-${randomBytes(32).toString("hex")}`;
          const expiresAtUnix = Math.floor(Date.now() / 1000) + ROUTE_TOKEN_TTL_SECONDS;
          // One guest exec: readiness gate, daemon build, enrolled devices, and
          // an invitation unless the caller is enrolled. Exit 3 means the daemon
          // was not ready inside the settle budget; heal, then run it again.
          const fingerprint = options?.deviceFingerprint;
          let bundleResult = await this.execResult(
            vm,
            cmuxTuiAttachBundleCommand({ readyGate: freestyleDaemonSettledCommand(), deviceFingerprint: fingerprint }),
            DAEMON_SETTLE_TIMEOUT_MS + EXEC_OVERHEAD_TIMEOUT_MS + EXEC_DEFAULT_TIMEOUT_MS,
          );
          let healed = false;
          if (!bundleResult || bundleResult.exitCode === CMUX_TUI_ATTACH_BUNDLE_NOT_READY_EXIT) {
            healed = true;
            await this.ensureCmuxTuiRunning(vm, vmId);
            bundleResult = await this.execResult(vm, cmuxTuiAttachBundleCommand({ deviceFingerprint: fingerprint }));
          }
          if (!bundleResult || bundleResult.exitCode !== 0) {
            throw new ProviderError(
              "freestyle",
              `cmux-tui attach bundle in ${vmId} failed (exit ${bundleResult?.exitCode ?? "n/a"}): ${(bundleResult?.stderr || bundleResult?.stdout || "").slice(0, 500)}`,
            );
          }
          const bundle = parseCmuxTuiAttachBundle(bundleResult.stdout, "freestyle", vmId, fingerprint);
          span.setAttribute("cmux.vm.cmux_remote.healed", healed);
          const invoke = this.cmuxTuiInvoke(vm);
          const enrolled = bundle.enrolled;
          let invitation: CmuxRemoteEndpoint["invitation"] = bundle.invitation ?? undefined;
          if (!enrolled && !invitation) {
            // The shell's substring check and the JSON parse disagreed (a
            // revoked device with the same fingerprint): mint separately.
            invitation = await mintCmuxTuiInvitation(invoke, "freestyle", vmId);
          }
          span.setAttribute("cmux.vm.cmux_remote.invited", !enrolled);
          const daemonBuild = bundle.daemonBuild ?? await cmuxTuiDaemonBuild(invoke);
          const addresses = freestyleNetworkAddressMetadata(data);
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
            ...(daemonBuild ? { daemonBuild } : {}),
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

  async approveCmuxRemoteEnrollment(
    vmId: string,
    invitationId: string,
    options?: CmuxRemoteApprovalOptions,
  ): Promise<CmuxRemoteApprovalResult> {
    void options;
    return withVmSpan(
      "cmux.vm.provider.approve_cmux_remote_enrollment",
      spanAttributes(vmId, "approve_cmux_remote_enrollment"),
      async () => {
        try {
          const vm = this.deps.client().vms.ref(vmId);
          return await approveCmuxTuiEnrollment(this.cmuxTuiInvoke(vm), "freestyle", vmId, invitationId);
        } catch (err) {
          throw err instanceof ProviderError
            ? err
            : new ProviderError("freestyle", `approveCmuxRemoteEnrollment(${vmId}) failed`, err);
        }
      },
    );
  }

  async openAttach(vmId: string, options?: AttachOptions): Promise<AttachEndpoint> {
    void options;
    throw new ProviderError(
      "freestyle",
      `openAttach(${vmId}) is not supported: Freestyle machines attach through the cmux-tui remote daemon (transport cmux-remote).`,
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

  async openSSH(vmId: string): Promise<SSHEndpoint> {
    return withVmSpan(
      "cmux.vm.provider.open_ssh",
      spanAttributes(vmId, "open_ssh"),
      async () => {
        throw new ProviderError(
          "freestyle",
          "Freestyle machines have no SSH gateway on the public platform. " +
            "They attach through the cmux-tui remote daemon (transport cmux-remote).",
        );
      },
    );
  }

  async revokeSSHIdentity(identityHandle: string): Promise<void> {
    void identityHandle;
    // openSSH always throws, so there is never an identity to revoke.
  }

  /**
   * Edge injection activates 20-30 s after boot and a guest request made
   * before that reaches coderouter without the token. Prove each rule from
   * inside the guest before handing the machine out; an inactive rule means
   * the machine can never reach a model, so the caller rolls it back.
   */
  /**
   * Attach-time heal: a daemon that is running AND listening dual-stack is
   * left alone; anything else is repaired, reinstalling first when the binary
   * is missing (a pre-bake image) or superseded by a manifest pin change. On a
   * freshly resumed machine this also covers the sub-second window before the
   * baked supervisor has started the daemon. The dual-stack check matters
   * because a machine from an older bake boots the daemon on 0.0.0.0, which
   * the public-IPv6 route cannot reach.
   */
  private async ensureCmuxTuiRunning(vm: Vm, vmId: string): Promise<void> {
    const healthy = await this.execResult(vm, freestyleDaemonSettledCommand(), DAEMON_SETTLE_TIMEOUT_MS + EXEC_OVERHEAD_TIMEOUT_MS);
    if (healthy?.exitCode === 0) return;
    const source = await resolveCmuxTuiSource("freestyle");
    const pinned = await this.execResult(vm, freestylePinCheckCommand(source));
    if (pinned?.exitCode !== 0) {
      await this.execOrThrow(vm, vmId, cmuxTuiInstallCommand(source), CMUX_TUI_INSTALL_TIMEOUT_MS)
        .catch((err: unknown) => {
          throw new ProviderError("freestyle", `cmux-tui install in ${vmId} failed: ${errorMessage(err)}`);
        });
    }
    await this.execOrThrow(vm, vmId, freestyleStartDaemonCommand(), 60_000);
    await waitForCmuxTuiReady(this.cmuxTuiInvoke(vm), "freestyle", vmId);
  }

  private async execResult(vm: Vm, command: string, timeoutMs = EXEC_DEFAULT_TIMEOUT_MS): Promise<ExecResult | null> {
    try {
      const r = await vm.exec({ command, timeoutMs, linuxUser: GUEST_LINUX_USER });
      return { exitCode: r.statusCode ?? 124, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
    } catch {
      return null;
    }
  }

  private async execOrThrow(vm: Vm, vmId: string, command: string, timeoutMs: number): Promise<ExecResult> {
    const r = await vm.exec({ command, timeoutMs, linuxUser: GUEST_LINUX_USER });
    const exitCode = r.statusCode ?? 124;
    if (exitCode !== 0) {
      throw new Error(`exec in ${vmId} exited ${exitCode}: ${(r.stderr ?? r.stdout ?? "").trim().slice(0, 500)}`);
    }
    return { exitCode, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
  }

  private cmuxTuiInvoke(vm: Vm): CmuxTuiInvoke {
    return async (args, timeoutMs) => {
      const r = await this.execResult(vm, `env HOME=/root /root/.cmux/bin/cmux-tui ${args}`, timeoutMs ?? EXEC_DEFAULT_TIMEOUT_MS);
      return r ?? { exitCode: 124, stdout: "", stderr: "exec failed" };
    };
  }
}

/** The resources a machine of `memoryMb` is sold with (see entitlements.ts). */
export function freestyleTargetResources(
  memoryMb: number,
  env: Record<string, string | undefined> = process.env,
): VmResources {
  return {
    cpu: vcpusForMemoryMb(memoryMb),
    memory: memoryMb,
    storage: vmDiskMb(env),
  };
}

/**
 * The grow-only resize that takes `current` to `target`, or null when nothing
 * needs to grow. Shrinks are never requested: Freestyle rejects them, and a
 * snapshot restored at a larger size keeps what it had.
 */
export function freestyleResizeRequest(
  current: VmResources,
  target: VmResources,
): ResizeVmOptions | null {
  const request: ResizeVmOptions = {};
  if (target.cpu > current.cpu) request.cpu = target.cpu;
  if (target.memory > current.memory) request.memory = target.memory;
  if (target.storage > current.storage) request.storage = target.storage;
  return Object.keys(request).length > 0 ? request : null;
}
