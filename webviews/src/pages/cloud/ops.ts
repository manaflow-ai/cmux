// Wire names and types of the `cmux.cloud` namespace (plans/cmux-next/cloud-app.md section 2). The
// catalog fragment `first-party-apps/cloud/catalog/cloud-catalog.json` is the source of truth; this
// one file mirrors it by hand until the generated client exists, so the lead can swap it for the
// generated module without touching the page. Fields are camelCase like the catalog and the Cloud
// API (`web/app/api/vm/**`). Mutations carry `idempotency_key` in their params (the page envelope
// rule, react-pages.md); the host moves it to the op request's key.
//
// The app server does not implement every op the page lists yet (domains, publications, network,
// firewall, team, sign-in and sign-out, billing, idle policy). It answers those with
// `cmux.cloud.unsupported` or an unknown-op error; the page then shows "Not available yet"
// (`isUnsupported`) for that op instead of an error.

export const CloudOps = {
  authStatus: "cmux.cloud.auth.status",
  authSignIn: "cmux.cloud.auth.sign_in",
  authSignOut: "cmux.cloud.auth.sign_out",
  teamList: "cmux.cloud.team.list",
  teamSelect: "cmux.cloud.team.select",
  machineList: "cmux.cloud.machine.list",
  machineGet: "cmux.cloud.machine.get",
  machineWatch: "cmux.cloud.machine.watch",
  machineCreate: "cmux.cloud.machine.create",
  machineRename: "cmux.cloud.machine.rename",
  machineStart: "cmux.cloud.machine.start",
  machinePause: "cmux.cloud.machine.pause",
  machineResize: "cmux.cloud.machine.resize",
  machineDelete: "cmux.cloud.machine.delete",
  machineStats: "cmux.cloud.machine.stats",
  machineIdlePolicySet: "cmux.cloud.machine.idle_policy.set",
  machineConnect: "cmux.cloud.machine.connect",
  snapshotList: "cmux.cloud.snapshot.list",
  snapshotCreate: "cmux.cloud.snapshot.create",
  snapshotRestore: "cmux.cloud.snapshot.restore",
  snapshotFork: "cmux.cloud.snapshot.fork",
  snapshotDelete: "cmux.cloud.snapshot.delete",
  domainList: "cmux.cloud.domain.list",
  domainVerify: "cmux.cloud.domain.verify",
  publicationList: "cmux.cloud.publication.list",
  publicationCreate: "cmux.cloud.publication.create",
  publicationUpdate: "cmux.cloud.publication.update",
  publicationDelete: "cmux.cloud.publication.delete",
  publicationVerify: "cmux.cloud.publication.verify",
  networkList: "cmux.cloud.network.list",
  firewallList: "cmux.cloud.firewall.list",
  firewallGet: "cmux.cloud.firewall.get",
  firewallCreate: "cmux.cloud.firewall.create",
  firewallDelete: "cmux.cloud.firewall.delete",
  planGet: "cmux.cloud.plan.get",
  usageGet: "cmux.cloud.usage.get",
  billingOpen: "cmux.cloud.billing.open",
} as const;

/** The native UI op that runs a registry action in the hosting app (react-pages.md 1.3). */
export const ACTION_RUN = "cmux.app.action.run";
/** App to page: the dispatcher delivered a page command (`find`, `focusSearch`). */
export const PAGE_COMMAND = "cmux.page.command";

/**
 * Ops the page never calls itself. They change money or delete data, or they change this client's
 * view, so the page asks the host to run them as a catalog action (`cmux.app.action.run {action:
 * <op>, args}`): the host shows the native confirmation sheet, which stamps origin user
 * (app-platform.md 15 "Confirmation"). Page JavaScript cannot prove a gesture. Snapshot restore is
 * not here: it makes a new machine and changes nothing that exists.
 */
export const NATIVE_ACTIONS = new Set<string>([
  CloudOps.authSignIn,
  CloudOps.authSignOut,
  CloudOps.machineDelete,
  CloudOps.publicationCreate,
  CloudOps.snapshotDelete,
  CloudOps.publicationDelete,
  CloudOps.firewallCreate,
  CloudOps.firewallDelete,
  CloudOps.billingOpen,
  CloudOps.machineConnect,
]);

/** Error codes that mean "the owner does not serve this op yet" (not a failure of the request). */
const UNSUPPORTED_CODES = new Set([
  "cmux.cloud.unsupported",
  "cmux.cloud.unknown_op",
  "cmux.protocol.unknown_op",
  "cmux.app.unknown_action",
  "operation.unsupported",
]);

export function isUnsupported(error: unknown): boolean {
  const code = (error as { code?: unknown } | null)?.code;
  return typeof code === "string" && UNSUPPORTED_CODES.has(code);
}

/** The host's answer to a confirmation action. A declined sheet answers `confirmed: false`. */
export interface ActionRunResult {
  confirmed?: boolean;
}

export type MachineStatus = "provisioning" | "running" | "failed" | "paused" | "destroyed" | "unknown";

/** A Cloud machine record (catalog `cloud.machine.list` items; owner: the cmux Cloud API). */
export interface CloudMachine {
  id: string;
  provider?: string;
  status: MachineStatus;
  displayName?: string | null;
  slug?: string | null;
  kind?: string | null;
  image?: string | null;
  imageVersion?: string | null;
  /** Epoch milliseconds. */
  createdAt?: number | null;
  address?: { ipv4?: string | null; ipv6?: string | null } | null;
  createdBy?: { userId: string; displayName?: string | null } | null;
  freeAccessExpiresAt?: number | null;
}

export interface MachineListResult {
  machines: CloudMachine[];
  /** The projection revision of the list; watch events at or below it are already in the list. */
  revision: number;
}

/** One event of `cmux.cloud.machine.watch`. Events of one projection change share its revision. */
export type MachineEvent =
  | { type: "upsert"; revision: number; machine: CloudMachine }
  | { type: "removed"; revision: number; id: string };

/** `cloud.machine.stats` (and the resize answer). `state` is `awake`, `asleep` or `unknown`. */
export interface MachineStats {
  state: string;
  cpus?: number | null;
  cpuPercent?: number | null;
  loadAverage1m?: number | null;
  memoryTotalMb?: number | null;
  memoryUsedMb?: number | null;
  diskTotalMb?: number | null;
  diskUsedMb?: number | null;
  maxVcpus?: number | null;
  maxMemoryMb?: number | null;
  maxDiskMb?: number | null;
}

export interface CloudSnapshot {
  id: string;
  name?: string | null;
  /** Epoch milliseconds or an ISO 8601 string (the Cloud API sends either). */
  createdAt?: number | string | null;
}

export interface SnapshotListResult {
  snapshots: CloudSnapshot[];
}

export interface CloudDomain {
  name: string;
  status: "verified" | "pending" | "failed";
}

export interface CloudPublication {
  id: string;
  machine: string;
  hostname: string;
  port: number;
  status: "active" | "pending" | "failed";
}

export interface CloudNetwork {
  id: string;
  cidr?: string;
  cidrV6?: string;
  scope: string;
}

export interface FirewallEndpoint {
  vmId?: string;
  vpcId?: string;
  tunnelId?: string;
  cidr?: string;
  public?: boolean;
  port?: number;
  protocol?: string;
}

export interface FirewallRule {
  id: string;
  action: string;
  source: FirewallEndpoint;
  destination: FirewallEndpoint;
  description?: string;
}

export interface CloudTeam {
  id: string;
  name: string;
}

/** `cloud.auth.status`: the host answers from its own sign-in. */
export interface AuthStatus {
  signedIn: boolean;
  team?: string | null;
}

/** `cloud.plan.get`: the `limits` of `GET /api/vm`. No plan logic in the page. */
export interface CloudPlan {
  planId?: string | null;
  maxActiveVms?: number | null;
  activeVmCount?: number | null;
  /** Memory sizes the plan allows for a new machine. */
  memoryOptionsMb: number[];
  /** Memory sizes shown but locked behind `memoryUpgradePlanId`. */
  lockedMemoryOptionsMb: number[];
  memoryUpgradePlanId?: string | null;
  freeAccessExpiresAt?: number | null;
  freeAccessWindowDays?: number | null;
}

/** `cloud.usage.get`. Hours are reported only for plans with an hour allowance. */
export interface CloudUsage {
  vmHoursUsed?: number | null;
  vmHoursIncluded?: number | null;
  activeVmCount?: number | null;
  savedVmLimit?: number | null;
}

/**
 * A machine mutation answers the machine record (or the stats, for a resize) with a top-level
 * `revision`: the projection revision its change reached. When the page's mirror has that revision,
 * the intent settles without a refetch.
 */
export type MachineMutationResult = CloudMachine & { revision: number };
export type ResizeResult = MachineStats & { revision: number };

export interface CreateMachineParams {
  /** 1 to 64 characters; absent = the owner names the machine. */
  displayName?: string;
  /** One of the plan's `memoryOptionsMb`; absent = the owner's default. */
  memoryMb?: number;
  kind?: string;
  idempotency_key: string;
}

export interface ResizeParams {
  machine: string;
  cpu?: number;
  memoryMb?: number;
  storageMb?: number;
  idempotency_key: string;
}
