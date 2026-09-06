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
  type ProviderTunnelCreateResult,
  type RestoreOptions,
  type SSHEndpoint,
  type SnapshotRef,
  type VmEdgeRule,
  type VMHandle,
  type VMPrivateNetworking,
  type VMProvider,
  type VMResizeOptions,
  type VMStatus,
} from "./types";
import {
  PLAN_MACHINE_MEMORY_MB,
  VM_DISK_MB_DEFAULT,
  vcpusForMemoryMb,
  vmDiskMb,
} from "../machineSpec";
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
  CMUX_TUI_TRUSTED_CARRIER_ENV,
  CMUX_TUI_ATTACH_BUNDLE_NOT_READY_EXIT,
  cmuxTuiAttachBundleCommand,
  cmuxTuiDaemonBuild,
  cmuxTuiDaemonCommand,
  cmuxTuiInstallCommand,
  cmuxTuiPinCheckCommand,
  parseCmuxTuiAttachBundle,
  resolveCmuxTuiSource,
  type CmuxTuiSource,
  waitForCmuxTuiReady,
  type CmuxTuiInvoke,
} from "./cmuxTuiDaemon";

// The Freestyle driver, on the public platform (api.freestyle.sh /v5, SDK
// freestyle@0.2.x). This is the only Freestyle arm. The platform also exposes
// a scoped SSH proxy (`beta-ssh.freestyle.sh`), but SSH is an unmanaged provider
// session and cannot carry cmux's workspace graph or revision protocol. Every
// cmux Cloud session therefore uses the cmux-tui daemon below.
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
// tunnel up simply cannot reach it. A machine with no private-network address
// fails closed. It never receives a public daemon rule and the client never
// receives a public route.
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
// instance id. Create is therefore `vms.create` and the grow-only resize; the
// image-bake step owns the static model-plane file. Attach heals a daemon that
// is not yet, or no longer, listening.
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
/** Cloud machines are durable boxes; only an explicit pause/stop should put one to sleep. */
export const FREESTYLE_PERSISTENT_IDLE_TIMEOUT_SECONDS = -1;
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

/** Exported for the publication provider, which shares this account-wide client. */
export function freestyleClient(timeoutMs = DEFAULT_TIMEOUT_MS): Freestyle {
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
 */
export function freestyleFirewallRules() {
  const rules: Array<{
    action: "allow";
    source: { public?: true };
    destination: { public?: true; port?: number; protocol?: "tcp" };
  }> = [{ action: "allow", source: {}, destination: { public: true } }];
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
 * Where to dial the machine's daemon: its private VPC address.
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
 * the daemon is dialed on.
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
  throw new ProviderError(
    "freestyle",
    `VM ${vmId} is not attached to a private network, so its cmux-tui daemon is unreachable`,
  );
}

/**
 * The address a machine's HTTP ports are opened at: its private VPC address,
 * v4 first for the same tunnel-routing reason the daemon route prefers it.
 * There is no public fallback. A machine without a private network has no port
 * to open.
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
 * response without any contributes nothing and cannot be used for a route.
 */
/**
 * The persisted network addresses (see {@link freestyleNetworkAddressMetadata})
 * re-shaped for {@link freestyleCmuxRemoteRoute}, so attach on a private
 * machine needs no provider read. Null when the row carries none.
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

type FreestyleTunnelOperations = {
  readonly create: (options: {
    readonly slug?: string;
    readonly displayName?: string;
    readonly clientPublicKey?: string;
    readonly routes?: string[];
    readonly vpcs?: { readonly vpcId?: string; readonly vpc?: string }[];
  }) => Promise<TunnelData>;
  readonly get: (tunnelIdOrSlug: string) => Promise<TunnelData>;
  readonly attachVpc: (tunnelIdOrSlug: string, vpcIdOrSlug: string) => Promise<TunnelData>;
  readonly rotateKey: (
    tunnelIdOrSlug: string,
    options: { readonly clientPublicKey?: string },
  ) => Promise<TunnelData>;
};

function isTunnelSlugConflict(error: unknown): boolean {
  return error instanceof FreestyleApiError && error.status === 409 && error.code === "CONFLICT";
}

function hasVPCAttachment(data: TunnelData, networkId: string): boolean {
  return data.attachments.some((attachment) => attachment.vpcId === networkId);
}

/**
 * A process-local queue for one provider slug. The durable database lease is
 * the cross-instance fence; this queue closes the smaller window between two
 * requests in one warm server process and makes the helper linearizable in
 * unit tests and local development. The queue promise never rejects, so one
 * failed provider call cannot strand later work behind it.
 */
const freestyleTunnelMutationTails = new Map<string, Promise<void>>();

async function withFreestyleTunnelMutation<T>(slug: string, operation: () => Promise<T>): Promise<T> {
  const previous = freestyleTunnelMutationTails.get(slug) ?? Promise.resolve();
  let release!: () => void;
  const current = new Promise<void>((resolve) => {
    release = resolve;
  });
  const tail = previous.catch(() => undefined).then(() => current);
  freestyleTunnelMutationTails.set(slug, tail);
  try {
    await previous.catch(() => undefined);
    return await operation();
  } finally {
    release();
    if (freestyleTunnelMutationTails.get(slug) === tail) {
      freestyleTunnelMutationTails.delete(slug);
    }
  }
}

/**
 * Create one device tunnel, or recover the provider resource when a previous
 * request committed it before the control-plane row did. Freestyle addresses
 * tunnels by slug, so a conflict is a durable idempotency signal, not a reason
 * to return a retryable 502 or create a second device identity.
 */
export async function createOrReuseFreestyleTunnel(
  tunnels: FreestyleTunnelOperations,
  options: CreateProviderTunnelOptions,
): Promise<ProviderTunnelCreateResult> {
  const slug = options.slug.trim();
  const clientPublicKey = options.clientPublicKey.trim();
  if (!slug) throw new Error("createOrReuseFreestyleTunnel requires a slug");
  if (!clientPublicKey) throw new Error("createOrReuseFreestyleTunnel requires a client public key");

  return withFreestyleTunnelMutation(slug, async () => {
    try {
      const data = await tunnels.create({
        slug,
        displayName: options.displayName,
        clientPublicKey,
        vpcs: [{ vpcId: options.networkId }],
      });
      return {
        tunnel: mapFreestyleTunnel(data, options.networkId),
        created: true,
        rotated: false,
      };
    } catch (error) {
      if (!isTunnelSlugConflict(error)) throw error;

      // The create may have succeeded in an earlier request whose DB write was
      // interrupted. Read by the deterministic slug, repair the requested
      // attachment, then rotate only when this installation's key changed.
      let data = await tunnels.get(slug);
      if (!hasVPCAttachment(data, options.networkId)) {
        data = await tunnels.attachVpc(slug, options.networkId);
      }
      let rotated = false;
      if (data.clientPublicKey.trim() !== clientPublicKey) {
        data = await tunnels.rotateKey(slug, { clientPublicKey });
        rotated = true;
        // Freestyle preserves attachments during rotation. Keep the invariant
        // explicit in case an older API response omits one from the result.
        if (!hasVPCAttachment(data, options.networkId)) {
          data = await tunnels.attachVpc(slug, options.networkId);
        }
      }

      // A mutation response is not the provider's concurrency fence. Read the
      // slug once more before returning so a stale or partial response cannot
      // be persisted as the device's current key or network attachment. If a
      // different process changed the key after our durable lease expired,
      // fail closed and let the caller retry instead of writing a false row.
      const verified = await tunnels.get(slug);
      if (!hasVPCAttachment(verified, options.networkId)) {
        throw new Error(`Freestyle tunnel ${slug} could not attach VPC ${options.networkId}`);
      }
      if (verified.clientPublicKey.trim() !== clientPublicKey) {
        throw new Error(`Freestyle tunnel ${slug} changed concurrently; retry enrollment`);
      }
      return {
        tunnel: mapFreestyleTunnel(verified, options.networkId),
        created: false,
        rotated,
      };
    }
  });
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
export function renderFreestyleModelPlaneEnvFile(envs: Readonly<Record<string, string>>): string | null {
  const baseUrl = envs.OPENAI_BASE_URL?.trim();
  if (!baseUrl) return null;
  const quote = (value: string) => `'${value.replace(/'/g, `'\\''`)}'`;
  const lines = [
    "# generated by cmux from machine boot env; managed, do not edit",
    `export OPENAI_BASE_URL=${quote(baseUrl)}`,
  ];
  if (envs.OPENAI_API_KEY) lines.push(`export OPENAI_API_KEY=${quote(envs.OPENAI_API_KEY)}`);
  const coderouterURL = envs.CMUX_CODEROUTER_URL?.trim();
  if (coderouterURL) {
    lines.push(`export CMUX_CODEROUTER_URL=${quote(coderouterURL)}`);
    // Keep Claude usable when a VM was created from an older devbox snapshot
    // whose agent-config.sh predates the derived Anthropic stanza. The route
    // token is already present in OPENAI_API_KEY for this legacy model-plane
    // contract; exposing the same value under Claude's standard names makes
    // the persisted file self-sufficient across resurrection and image drift.
    lines.push(`export ANTHROPIC_BASE_URL=${quote(coderouterURL)}`);
    if (envs.OPENAI_API_KEY) {
      lines.push(`export ANTHROPIC_AUTH_TOKEN=${quote(envs.OPENAI_API_KEY)}`);
      lines.push(`export ANTHROPIC_API_KEY=${quote(envs.OPENAI_API_KEY)}`);
    }
  }
  return `${lines.join("\n")}\n`;
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
 * Healthy = the daemon process is up AND something listens on 1337 in the v6
 * table (a dual-stack `[::]` bind; 0x0539 = 1337). A daemon bound 0.0.0.0 only
 * appears in /proc/net/tcp and cannot accept a private IPv6 connection.
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
 * (Re)start the daemon listening dual-stack with the trusted-carrier listener.
 * Under systemd (the baked cmux-tui-daemon unit), install a drop-in setting
 * CMUX_TUI_REMOTE_WS_BIND=[::]:1337 — the env cmux-devbox-boot reads — and
 * CMUX_TUI_REMOTE_WS_TRUSTED_CARRIER=1 — which the daemon itself reads, so a
 * baked launch line that predates the flag still serves the trusted listener —
 * then restart the unit. Without systemd (or the unit), fall back to a direct
 * daemon launch carrying both.
 */
/**
 * `replaceExisting` is the trusted-listener heal: a daemon that already runs
 * without the trusted env must go, or installing the pinned binary changes
 * nothing for the live process. systemd restarts unconditionally; the
 * fallback launcher otherwise keeps a running daemon.
 */
export function freestyleStartDaemonCommand(options?: { replaceExisting?: boolean }): string {
  const replace = options?.replaceExisting === true;
  const fallbackLaunch = `(setsid nohup sh -c '${cmuxTuiDaemonCommand(FREESTYLE_REMOTE_WS_BIND)}' >>/tmp/cmux-tui-daemon.log 2>&1 &)`;
  return [
    "if [ -d /run/systemd/system ] && [ -f /etc/systemd/system/cmux-tui-daemon.service ]; then",
    `mkdir -p ${REMOTE_WS_BIND_OVERRIDE.replace(/\/[^/]+$/, "")};`,
    `printf '[Service]\\nEnvironment=CMUX_TUI_REMOTE_WS_BIND=${FREESTYLE_REMOTE_WS_BIND}\\nEnvironment=${CMUX_TUI_TRUSTED_CARRIER_ENV}=1\\n' > ${REMOTE_WS_BIND_OVERRIDE};`,
    "systemctl daemon-reload;",
    "systemctl restart cmux-tui-daemon;",
    "else",
    replace
      ? `pkill -f 'cmux-tui server [s]tart' >/dev/null 2>&1; sleep 1; ${fallbackLaunch};`
      : `pgrep -f 'cmux-tui server [s]tart' >/dev/null 2>&1 || ${fallbackLaunch};`,
    "fi",
  ].join(" ");
}

function isNotFound(err: unknown): boolean {
  return err instanceof FreestyleApiError && (err.status === 404 || err.code === "NOT_FOUND");
}

function isConflict(err: unknown): boolean {
  return err instanceof FreestyleApiError && (err.status === 409 || err.code === "CONFLICT");
}

/**
 * Recover a provider tunnel whose create response was lost after the provider
 * committed it. This is intentionally a small seam: the workflow can repair a
 * missing local row without rotating a key that another running app may still
 * be using.
 */
export async function recoverFreestyleTunnelAfterConflict(
  tunnels: Pick<Freestyle["tunnels"], "get" | "attachVpc">,
  options: CreateProviderTunnelOptions,
  clientPublicKey: string,
): Promise<ProviderTunnel> {
  let existing = await tunnels.get(options.slug);
  if (existing.clientPublicKey.trim() !== clientPublicKey) {
    throw new ProviderError(
      "freestyle",
      `tunnel ${options.slug} already exists with a different client key; use the original installation or revoke it before re-enrolling`,
    );
  }
  if (!existing.attachments.some((entry) => entry.vpcId === options.networkId)) {
    existing = await tunnels.attachVpc(existing.tunnelId ?? existing.id, options.networkId);
  }
  return mapFreestyleTunnel(existing, options.networkId);
}

/**
 * A VPC slug conflict is the only provider failure that means another request
 * won the create race. Status and code are both checked because a 409 also
 * represents unrelated provider conflicts, which must remain visible.
 */
function isVpcSlugConflict(err: unknown): boolean {
  return err instanceof FreestyleApiError && err.status === 409 && err.code === "CONFLICT";
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
          // Two machines created at once both miss the read and both create.
          // Reconcile only the documented slug conflict. A 401, 403, 429, or
          // 5xx must not be hidden by a coincidental stale network lookup.
          if (!isVpcSlugConflict(err)) {
            throw new ProviderError("freestyle", `ensureNetwork(${slug})`, err);
          }
          const raced = await this.readNetworkBySlug(fs, slug);
          if (!raced) {
            throw new ProviderError("freestyle", `ensureNetwork(${slug})`, err);
          }
          // The winner may have created the VPC without its rule, or an
          // operator may have removed it between create and this read. Heal the
          // winner before returning it, otherwise the next VM is unreachable.
          await this.ensureMembersRule(fs, raced.id);
          setSpanAttributes(span, { "cmux.vm.network.id": raced.id, "cmux.vm.network.created": false });
          return raced;
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

  async createTunnel(options: CreateProviderTunnelOptions): Promise<ProviderTunnelCreateResult> {
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
          // for the Mac to fill in from its own Keychain. A slug conflict is
          // reconciled by the helper, which also preserves the operation
          // outcome for the control-plane response.
          const result = await createOrReuseFreestyleTunnel(freestyleClient().tunnels, options);
          setSpanAttributes(span, { "cmux.vm.tunnel.id": result.tunnel.id });
          setSpanAttributes(span, {
            "cmux.vm.tunnel.created": result.created,
            "cmux.vm.tunnel.rotated": result.rotated,
          });
          return result;
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
   * protocols, the rule created with the network). Missing means someone removed
   * it, so re-create it. A provider error is fatal: continuing would create a
   * machine that the owner's tunnel cannot reach.
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
      throw new ProviderError("freestyle", `ensureMembersRule(${networkId})`, err);
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
    const networkId = options.network?.id;
    if (!networkId) {
      throw new ProviderError("freestyle", "create requires a private network");
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
          const { vm, vmId, data } = await fs.vms.create({
            snapshotId: image,
            displayName: options.displayName ?? "cmux Cloud VM",
            // Do not let an account/provider idle default turn a persistent
            // machine into a one-shot box. Explicit pause/stop still works.
            idleTimeoutSeconds: FREESTYLE_PERSISTENT_IDLE_TIMEOUT_SECONDS,
            metadata: { cmux: "cloud" },
            firewall: { rules: freestyleFirewallRules() },
            vpcs: [{ vpcId: networkId, ipv4: true, ipv6: true }],
            ...(tlsRules ? { tls: { rules: tlsRules } } : {}),
          });
          setSpanAttributes(span, {
            "cmux.vm.id": vmId,
            "cmux.vm.network.private": !!networkId,
          });
          try {
            if (options.imageSize) {
              // One snapshot per CPU/memory size: preserve that baked shape,
              // then grow only storage when the image is below the documented
              // 32 GB starting disk.
              setSpanAttributes(span, {
                "cmux.vm.image_size": options.imageSize.name,
                "cmux.vm.resources.cpu": options.imageSize.cpu,
                "cmux.vm.resources.memory_mb": options.imageSize.memoryMb,
              });
              await this.growToRequestedSize(
                fs,
                vm,
                vmId,
                undefined,
                span,
                {
                  cpu: options.imageSize.cpu,
                  memory: options.imageSize.memoryMb,
                  storage: Math.max(VM_DISK_MB_DEFAULT, options.imageSize.storageMb, vmDiskMb()),
                },
              );
            } else {
              // A size-less image boots at its snapshot's resources and only a
              // grow-only resize raises them. Size first so the daemon comes
              // up on the provider profile requested by the server.
              await this.growToRequestedSize(fs, vm, vmId, options.memoryMb, span);
            }
            // The baked supervisor is already bringing the daemon up; the only
            // per-machine input it needs is the model-plane env file.
          } catch (err) {
            // A VM that failed to size or configure must not survive as an
            // orphan, and an undersized machine must not ship as if it were
            // the provider sizing profile.
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
              networkId,
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
   * Grow the VM to the requested memory (the provider profile when the caller
   * sent none), the vCPUs that memory implies, and the starting disk. Freestyle
   * resize is grow-only, so only larger dimensions are sent; a snapshot that
   * already carries the size is a no-op.
   */
  private async growToRequestedSize(
    fs: Freestyle,
    vm: Vm,
    vmId: string,
    memoryMb: number | undefined,
    span: Parameters<typeof setSpanAttributes>[0],
    targetResources?: VmResources,
  ): Promise<void> {
    const current = (await fs.vms.get(vmId)).resources;
    const target = targetResources ?? freestyleTargetResources(memoryMb ?? PLAN_MACHINE_MEMORY_MB);
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

  async resize(vmId: string, options: VMResizeOptions): Promise<void> {
    return withVmSpan(
      "cmux.vm.provider.resize",
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
    const networkId = options?.network?.id;
    if (!networkId) {
      throw new ProviderError("freestyle", "restore requires a private network");
    }
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
          const { vm, vmId, data } = await fs.vms.create({
            snapshotId,
            displayName: "cmux Cloud VM",
            idleTimeoutSeconds: FREESTYLE_PERSISTENT_IDLE_TIMEOUT_SECONDS,
            metadata: { cmux: "cloud" },
            firewall: { rules: freestyleFirewallRules() },
            vpcs: [{ vpcId: networkId, ipv4: true, ipv6: true }],
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
          return {
            provider: "freestyle" as const,
            providerVmId: vmId,
            status: "running" as const,
            image: snapshotId,
            createdAt: Date.now(),
            providerMetadata: {
              ...(options?.providerMetadata ?? {}),
              networkId,
              ...freestyleNetworkAddressMetadata(data),
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
          const persisted = freestyleRouteAddressesFromMetadata(options?.providerMetadata);
          const data = persisted ?? await vm.data();
          const route = freestyleCmuxRemoteRoute(data, vmId);
          const fingerprint = options?.deviceFingerprint;
          let { bundle, healed } = await this.loadCmuxRemoteBundle(vm, vmId, fingerprint);
          // A daemon from a bake that predates the trusted listener is brought to
          // the pinned build and restarted with the drop-in — but never under a
          // device that is already enrolled there, whose sessions the restart
          // would end; that device keeps dialing with its stored key. The
          // manifest is read only here, so a manifest outage cannot reject an
          // attach that needs no heal.
          if (!bundle.trustedCarrier && !bundle.enrolled) {
            healed = true;
            const source = await this.deps.resolveDaemonSource("freestyle");
            await this.installTrustedCmuxTui(vm, vmId, source);
            const retried = await this.loadCmuxRemoteBundle(vm, vmId, fingerprint);
            bundle = retried.bundle;
            if (!bundle.trustedCarrier) {
              throw new ProviderError(
                "freestyle",
                `cmux-tui daemon in ${vmId} still refuses the trusted listener after the pinned build was installed and restarted`,
              );
            }
          }
          span.setAttribute("cmux.vm.cmux_remote.healed", healed);
          span.setAttribute("cmux.vm.cmux_remote.trusted", bundle.trustedCarrier);
          span.setAttribute("cmux.vm.cmux_remote.enrolled", bundle.enrolled);
          span.setAttribute("cmux.vm.network.private", (data.vpcs ?? data.networks ?? []).length > 0);
          span.setAttribute("cmux.vm.route.source", persisted ? "row" : "provider");
          return {
            transport: "cmux-remote" as const,
            route,
            token: `cmux-freestyle-route-${randomBytes(32).toString("hex")}`,
            expiresAtUnix: Math.floor(Date.now() / 1000) + ROUTE_TOKEN_TTL_SECONDS,
            session: CMUX_TUI_SESSION,
            trustedCarrier: bundle.trustedCarrier,
            ...(bundle.daemonBuild ? { daemonBuild: bundle.daemonBuild } : {}),
            ...this.networkAddresses(data),
          };
        } catch (err) {
          throw err instanceof ProviderError
            ? err
            : new ProviderError("freestyle", `openCmuxRemote(${vmId}) failed`, err);
        }
      },
    );
  }

  private async loadCmuxRemoteBundle(
    vm: Vm,
    vmId: string,
    fingerprint: string | undefined,
  ) {
    const bundleOptions = { deviceFingerprint: fingerprint };
    let result = await this.execResult(
      vm,
      cmuxTuiAttachBundleCommand({ readyGate: freestyleDaemonSettledCommand(), ...bundleOptions }),
      DAEMON_SETTLE_TIMEOUT_MS + EXEC_OVERHEAD_TIMEOUT_MS + EXEC_DEFAULT_TIMEOUT_MS,
    );
    let healed = false;
    if (!result || result.exitCode === CMUX_TUI_ATTACH_BUNDLE_NOT_READY_EXIT) {
      healed = true;
      await this.ensureCmuxTuiRunning(vm, vmId);
      result = await this.execResult(vm, cmuxTuiAttachBundleCommand(bundleOptions));
    }
    if (!result || result.exitCode !== 0) {
      throw new ProviderError(
        "freestyle",
        `cmux-tui attach bundle in ${vmId} failed (exit ${result?.exitCode ?? "n/a"}): ${(result?.stderr || result?.stdout || "").slice(0, 500)}`,
      );
    }
    return { bundle: parseCmuxTuiAttachBundle(result.stdout, "freestyle", vmId, fingerprint), healed };
  }

  /**
   * Bring a machine's daemon to the pinned build and restart it with the
   * trusted-carrier drop-in. The manifest sha decides the install, not the
   * bake-time pin file: a bake that predates the trusted listener records a
   * binary that ignores the env, and only a build that honors it counts.
   */
  private async installTrustedCmuxTui(vm: Vm, vmId: string, source: CmuxTuiSource): Promise<void> {
    const pinned = await this.execResult(vm, cmuxTuiPinCheckCommand(source));
    if (pinned?.exitCode !== 0) {
      await this.execOrThrow(vm, vmId, cmuxTuiInstallCommand(source), CMUX_TUI_INSTALL_TIMEOUT_MS)
        .catch((err: unknown) => {
          throw new ProviderError("freestyle", `cmux-tui install in ${vmId} failed: ${errorMessage(err)}`);
        });
    }
    await this.execOrThrow(vm, vmId, freestyleStartDaemonCommand({ replaceExisting: true }), 60_000);
    await waitForCmuxTuiReady(this.cmuxTuiInvoke(vm), "freestyle", vmId);
  }

  private networkAddresses(data: FreestyleRouteAddresses): Pick<CmuxRemoteEndpoint, "networkAddresses"> {
    const addresses = freestyleNetworkAddressMetadata(data);
    const networkAddresses = {
      ...(addresses.networkIpv4 ? { ipv4: addresses.networkIpv4 } : {}),
      ...(addresses.networkIpv6 ? { ipv6: addresses.networkIpv6 } : {}),
    };
    return Object.keys(networkAddresses).length ? { networkAddresses } : {};
  }

  async approveCmuxRemoteEnrollment(
    vmId: string,
    invitationId: string,
    options?: CmuxRemoteApprovalOptions,
  ): Promise<CmuxRemoteApprovalResult> {
    void options;
    void invitationId;
    // Compatibility: the trusted listener enrolls nobody, so there is nothing
    // to approve and nothing to exec. Older Mac builds call this once after
    // their first connect and only need `approved` back.
    return withVmSpan(
      "cmux.vm.provider.approve_cmux_remote_enrollment",
      spanAttributes(vmId, "approve_cmux_remote_enrollment", { "cmux.vm.cmux_remote.approve_noop": true }),
      async () => ({ approved: true, state: "approved" as const }),
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
          "Freestyle provides scoped SSH for unmanaged access, but managed Cloud VM sessions " +
            "use the cmux-tui remote daemon (transport cmux-remote).",
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
   * cannot accept a private IPv6 connection.
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

/** The provider resources each machine receives for `memoryMb` (see entitlements.ts). */
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
