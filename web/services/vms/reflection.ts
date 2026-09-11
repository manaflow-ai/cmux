// cmux Reflection: what a machine can learn about itself from inside.
//
// Modeled on exe.dev's reflection integration: `curl https://reflection…/` returns
// the machine's own name plus an index of paths, and `/integrations` lists what the
// machine can use, each with a one-line `help` command an agent can run as-is.
// Identity comes from the platform edge (services/vms/vmPrincipal.ts), never from
// anything the guest claims.
//
// Pure: every builder takes rows and an owner snapshot and returns JSON-ready data,
// so the route is a thin loader and the tests need no database.
import type { ProviderId } from "./drivers/types";
import { vmImageKindFor } from "./images/resolver";
import { VM_RESOURCE_RESERVATION_METADATA_KEY } from "./machineSpec";
import { VM_SELF_SCHEMA, vmSelfMachine, type VmSelfMachine } from "./selfDiscovery";
import { VM_PRINCIPAL_LIVE_STATUSES, type VmPrincipalRow } from "./vmPrincipalContract";

export type ReflectionRow = VmPrincipalRow;

export type ReflectionOwner = {
  readonly userId: string;
  readonly email: string | null;
  readonly displayName: string | null;
  readonly teamId: string;
  readonly planId: string | null;
};

export type ReflectionContext = {
  readonly self: ReflectionRow;
  readonly owner: ReflectionOwner;
  /** Every machine of the owner the loader could see; `self` may be among them. */
  readonly siblings: readonly ReflectionRow[];
  /** `https://<coderouter alias>`: the origin the guest already dials. */
  readonly aliasOrigin: string;
  /** `https://<reflection alias>`: the vanity origin (new machines only). */
  readonly reflectionOrigin: string;
  /** From the image kind; null when the image is unknown to this deployment. */
  readonly hasDesktop: boolean | null;
};

export type ReflectionPath = { readonly path: string; readonly description: string };

/** The index every machine can walk; `/` itself is the index. */
export const REFLECTION_PATHS: readonly ReflectionPath[] = [
  { path: "/owner", description: "who owns this machine (user, email, team, plan)" },
  { path: "/machine", description: "this machine: status, image, size, private network address" },
  { path: "/peers", description: "the owner's other machines reachable on the private network, with their daemon routes" },
  { path: "/integrations", description: "what this machine can use, each with a help command" },
];

/** The daemon listener every cmux Cloud machine serves on its private address. */
export const REFLECTION_PEER_DAEMON_PORT = 1337;

export type ReflectionNetwork = { readonly ipv4: string | null; readonly ipv6: string | null };
export type ReflectionSize = { readonly memory_mb: number | null; readonly cpu: number | null; readonly disk_mb: number | null };

/** The machine's address everywhere: its generated slug, else the provider id. */
export function reflectionMachineName(row: Pick<ReflectionRow, "slug" | "providerVmId" | "id">): string {
  const slug = row.slug?.trim();
  if (slug) return slug;
  const providerVmId = row.providerVmId?.trim();
  return providerVmId || row.id;
}

export function reflectionDisplayName(row: Pick<ReflectionRow, "slug" | "providerVmId" | "id" | "displayName">): string {
  const label = row.displayName?.trim();
  return label || reflectionMachineName(row);
}

function metadataString(metadata: Readonly<Record<string, unknown>>, key: string): string | null {
  const value = metadata[key];
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

/** The private-network address recorded at create or learned on first attach. */
export function reflectionNetwork(metadata: Readonly<Record<string, unknown>>): ReflectionNetwork {
  return {
    ipv4: metadataString(metadata, "networkIpv4"),
    ipv6: metadataString(metadata, "networkIpv6"),
  };
}

/** The reserved shape (`cmuxResourceReservation`), when the row carries one. */
export function reflectionSize(metadata: Readonly<Record<string, unknown>>): ReflectionSize {
  const raw = metadata[VM_RESOURCE_RESERVATION_METADATA_KEY];
  const reservation = raw && typeof raw === "object" ? (raw as Record<string, unknown>) : {};
  const number = (key: string): number | null => {
    const value = reservation[key];
    return typeof value === "number" && Number.isFinite(value) && value > 0 ? value : null;
  };
  return { memory_mb: number("memoryMb"), cpu: number("vcpus"), disk_mb: number("diskMb") };
}

/**
 * How a peer dials this machine's session daemon on the private network. IPv6 is
 * the address every private Freestyle network assigns; IPv4 is the fallback.
 */
export function reflectionPeerRoute(network: ReflectionNetwork): string | null {
  if (network.ipv6) return `ws://[${network.ipv6}]:${REFLECTION_PEER_DAEMON_PORT}/v1/link`;
  if (network.ipv4) return `ws://${network.ipv4}:${REFLECTION_PEER_DAEMON_PORT}/v1/link`;
  return null;
}

/**
 * Whether the machine has a screen: the image kind decides. An image or
 * provider unknown to this deployment means "cannot say", not "no".
 */
export function reflectionHasDesktop(row: Pick<ReflectionRow, "provider" | "imageId">): boolean | null {
  try {
    return vmImageKindFor(row.provider as ProviderId, row.imageId) === "desktop";
  } catch {
    return null;
  }
}

export function reflectionIsLive(row: Pick<ReflectionRow, "status">): boolean {
  return (VM_PRINCIPAL_LIVE_STATUSES as readonly string[]).includes(row.status);
}

/** Same owner as `self`: the billing team when there is one, else the creating user. */
export function reflectionSharesOwner(self: ReflectionRow, other: ReflectionRow): boolean {
  if (self.billingTeamId) return other.billingTeamId === self.billingTeamId;
  return other.billingTeamId === null && other.userId === self.userId;
}

export function reflectionUrls(context: Pick<ReflectionContext, "aliasOrigin" | "reflectionOrigin">): string[] {
  // No trailing slash on the path form: Next redirects `/x/` to `/x`, and a
  // redirect is one thing a `curl -s` inside a machine will not follow.
  return [`${context.aliasOrigin}/api/vm/reflection`, `${context.reflectionOrigin}/`];
}

/**
 * One owner machine in the `cmux self` / `cmux vm ls` shape (`VmSelfMachine`),
 * plus how a peer would reach it. The caller's own entry carries no route: a
 * machine does not link to itself.
 */
export type ReflectionMachineEntry = VmSelfMachine & {
  readonly network: ReflectionNetwork;
  readonly route: string | null;
  readonly reachable: boolean;
};

function reflectionMachineEntry(row: ReflectionRow, self: ReflectionRow): ReflectionMachineEntry | null {
  const base = vmSelfMachine(
    {
      vmId: row.id,
      providerVmId: row.providerVmId,
      displayName: row.displayName,
      slug: row.slug,
      status: row.status,
      createdAt: row.createdAt.toISOString(),
    },
    self.id,
  );
  if (!base) return null;
  const network = reflectionNetwork(row.providerMetadata);
  const route = row.id === self.id ? null : reflectionPeerRoute(network);
  return { ...base, network, route, reachable: route !== null };
}

/**
 * Every live machine of the owner, the caller included and marked `self`,
 * newest first — the list `GET /api/vm/self` has always served, so the guest's
 * `cmux self` and `cmux vm ls` read one shape whichever endpoint answers, now
 * with each machine's private route beside it.
 */
export function reflectionMachines(context: ReflectionContext): ReflectionMachineEntry[] {
  const { self } = context;
  const seen = new Set<string>();
  const rows = [self, ...context.siblings].filter((row) => {
    if (seen.has(row.id)) return false;
    seen.add(row.id);
    return row.id === self.id || (reflectionIsLive(row) && reflectionSharesOwner(self, row));
  });
  return rows
    .map((row) => reflectionMachineEntry(row, self))
    .filter((entry): entry is ReflectionMachineEntry => entry !== null)
    .sort((a, b) => (a.createdAt < b.createdAt ? 1 : a.createdAt > b.createdAt ? -1 : 0));
}

/** The caller as a `VmSelfMachine`; a still-provisioning machine falls back to its row id as the address. */
export function reflectionSelfMachine(context: ReflectionContext): ReflectionMachineEntry {
  const { self } = context;
  return reflectionMachineEntry(self, self) ?? {
    id: self.id,
    vmId: self.id,
    name: reflectionDisplayName(self),
    displayName: self.displayName,
    slug: self.slug,
    status: self.status,
    createdAt: self.createdAt.toISOString(),
    self: true,
    network: reflectionNetwork(self.providerMetadata),
    route: null,
    reachable: false,
  };
}

/**
 * The index: the machine's own name at the top level (exe.dev parity), the
 * owner, and the paths — plus the `GET /api/vm/self` fields (`schema`, `machine`,
 * `team`, `machines`) so this one answer serves `cmux self` and `cmux vm ls`.
 */
export function reflectionIndex(context: ReflectionContext): Record<string, unknown> {
  const { self, owner } = context;
  return {
    name: reflectionMachineName(self),
    display_name: reflectionDisplayName(self),
    emoji: null,
    vm_id: self.id,
    provider_vm_id: self.providerVmId,
    status: self.status,
    created_at: self.createdAt.toISOString(),
    owner: { user_id: owner.userId, email: owner.email, display_name: owner.displayName },
    team_id: owner.teamId,
    plan_id: owner.planId,
    urls: { reflection: reflectionUrls(context) },
    paths: REFLECTION_PATHS,
    schema: VM_SELF_SCHEMA,
    machine: reflectionSelfMachine(context),
    team: { id: owner.teamId },
    machines: reflectionMachines(context),
  };
}

export function reflectionOwner(context: ReflectionContext): Record<string, unknown> {
  const { owner } = context;
  return {
    user_id: owner.userId,
    email: owner.email,
    display_name: owner.displayName,
    team_id: owner.teamId,
    plan_id: owner.planId,
  };
}

export function reflectionMachine(context: ReflectionContext): Record<string, unknown> {
  const { self } = context;
  return {
    vm_id: self.id,
    provider_vm_id: self.providerVmId,
    name: reflectionMachineName(self),
    display_name: reflectionDisplayName(self),
    status: self.status,
    provider: self.provider,
    image_id: self.imageId,
    image_version: self.imageVersion,
    created_at: self.createdAt.toISOString(),
    size: reflectionSize(self.providerMetadata),
    network: reflectionNetwork(self.providerMetadata),
    has_desktop: context.hasDesktop,
  };
}

export type ReflectionPeer = {
  readonly name: string;
  readonly display_name: string;
  readonly vm_id: string;
  readonly provider_vm_id: string | null;
  readonly status: string;
  readonly network: ReflectionNetwork;
  readonly route: string | null;
  readonly reachable: boolean;
  readonly help: string;
};

/**
 * The owner's OTHER live machines. Discovery, not authorization: the daemon's
 * private-network listener is a trusted carrier (every member is the owner's
 * Mac or another of the owner's machines), so a route is all a peer link needs.
 */
export function reflectionPeers(context: ReflectionContext): { peers: ReflectionPeer[] } {
  const { self } = context;
  const peers = context.siblings
    .filter((row) => row.id !== self.id && reflectionIsLive(row) && reflectionSharesOwner(self, row))
    .map((row): ReflectionPeer => {
      const name = reflectionMachineName(row);
      const network = reflectionNetwork(row.providerMetadata);
      const route = reflectionPeerRoute(network);
      return {
        name,
        display_name: reflectionDisplayName(row),
        vm_id: row.id,
        provider_vm_id: row.providerVmId,
        status: row.status,
        network,
        route,
        reachable: route !== null,
        help: `cmux vm exec ${name} -- <command>`,
      };
    })
    .sort((a, b) => a.name.localeCompare(b.name));
  return { peers };
}

export type ReflectionIntegration = {
  readonly type: string;
  readonly name: string;
  readonly help: string;
  readonly comment?: string;
};

export const REFLECTION_AGENTS = ["claude", "codex", "opencode", "pi"] as const;

export function reflectionIntegrations(context: ReflectionContext): { integrations: ReflectionIntegration[] } {
  const integrations: ReflectionIntegration[] = [
    { type: "reflection", name: "reflection", help: "cmux whoami" },
    {
      type: "llm",
      name: "coderouter",
      help: "cmux coderouter models",
      comment: "Model credentials are injected by the platform edge; agents authenticate with the placeholder key already in the environment.",
    },
    ...REFLECTION_AGENTS.map((agent): ReflectionIntegration => ({
      type: "agent",
      name: agent,
      help: `cmux agent ${agent} "<prompt>"`,
    })),
    { type: "notify", name: "notify", help: "cmux notify --title <text> --body <text>" },
    { type: "peers", name: "machines", help: "cmux vm ls" },
    { type: "env", name: "env", help: "cmux env ls" },
    { type: "layout", name: "layout", help: "cmux layout export" },
  ];
  if (context.hasDesktop === true) {
    integrations.push({ type: "desktop", name: "display:1", help: "DISPLAY=:1 xdotool key ctrl+l" });
  }
  return { integrations };
}

export function reflectionNotFound(path: string): Record<string, unknown> {
  return { error: "not_found", path, paths: REFLECTION_PATHS };
}

/** `""`, `"/"`, `"peers"`, `"/peers/"` → `"/"` or `"/peers"`. */
export function normalizeReflectionPath(raw: string): string {
  const trimmed = raw.trim().replace(/^\/+|\/+$/g, "").toLowerCase();
  return trimmed ? `/${trimmed}` : "/";
}

export type ReflectionAnswer = { readonly status: number; readonly body: Record<string, unknown> };

/** The whole read surface behind one dispatcher, so the route stays a loader. */
export function reflectionPayload(rawPath: string, context: ReflectionContext): ReflectionAnswer {
  const path = normalizeReflectionPath(rawPath);
  switch (path) {
    case "/":
      return { status: 200, body: reflectionIndex(context) };
    case "/owner":
      return { status: 200, body: reflectionOwner(context) };
    case "/machine":
      return { status: 200, body: reflectionMachine(context) };
    case "/peers":
      return { status: 200, body: reflectionPeers(context) };
    case "/integrations":
      return { status: 200, body: reflectionIntegrations(context) };
    default:
      return { status: 404, body: reflectionNotFound(path) };
  }
}
