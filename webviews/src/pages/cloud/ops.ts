// Wire names and types of the `cmux.cloud` namespace (plans/cmux-next/cloud-app.md section 2). The
// catalog fragment `first-party-apps/cloud/catalog/cloud-catalog.json` is the source of truth; this
// one file mirrors it by hand until the generated client exists, so the lead can swap it for the
// generated module without touching the page. Fields are serde snake_case like the other pages.
// Machine fields follow `CmuxNextCloud/API/CloudMachine.swift` and `CloudResponses.swift`.

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
 * (app-platform.md 15 "Confirmation"). Page JavaScript cannot prove a gesture.
 */
export const NATIVE_ACTIONS = new Set<string>([
  CloudOps.machineDelete,
  CloudOps.snapshotDelete,
  CloudOps.publicationDelete,
  CloudOps.firewallCreate,
  CloudOps.firewallDelete,
  CloudOps.billingOpen,
  CloudOps.machineConnect,
]);

/** The host's answer to a confirmation action. A declined sheet answers `confirmed: false`. */
export interface ActionRunResult {
  confirmed?: boolean;
}

export type MachineStatus = "provisioning" | "running" | "failed" | "paused" | "destroyed" | "unknown";

export interface MachineSize {
  name?: string;
  cpu?: number;
  memory_mb?: number;
  storage_mb?: number;
}

export interface CloudMachine {
  id: string;
  provider: string;
  status: MachineStatus;
  display_name?: string;
  slug?: string;
  kind?: string;
  image?: string;
  image_version?: string;
  created_at_ms?: number;
  address?: { ipv4?: string; ipv6?: string };
  size?: MachineSize;
  /** Seconds of inactivity before the owner pauses the machine; absent = never. */
  idle_timeout_seconds?: number;
}

export interface MachineListResult {
  machines: CloudMachine[];
  /** The owner's revision of the list; watch events at or below it are already in the list. */
  revision: number;
}

/** One event of `cmux.cloud.machine.watch`. */
export type MachineEvent =
  | { type: "upsert"; revision: number; machine: CloudMachine }
  | { type: "removed"; revision: number; id: string };

export interface MachineStats {
  state: string;
  cpus?: number;
  cpu_percent?: number;
  memory_total_mb?: number;
  memory_used_mb?: number;
  disk_total_mb?: number;
  disk_used_mb?: number;
}

export interface CloudSnapshot {
  id: string;
  name?: string;
  machine?: string;
  created_at_ms?: number;
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
  cidr_v6?: string;
  scope: string;
}

export interface FirewallEndpoint {
  vm_id?: string;
  vpc_id?: string;
  tunnel_id?: string;
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

export interface AuthStatus {
  signed_in: boolean;
  email?: string;
  team?: string;
}

export interface PlanSize {
  name: string;
  cpu: number;
  memory_mb: number;
  storage_mb: number;
  /** False when the plan does not include this size. */
  allowed: boolean;
}

export interface CloudPlan {
  name: string;
  machine_limit: number;
  sizes: PlanSize[];
  /** True when the plan can be upgraded through checkout. */
  upgradable: boolean;
}

export interface CloudUsage {
  period_start_ms: number;
  period_end_ms: number;
  compute_hours: number;
  compute_hours_limit?: number;
  storage_gb: number;
  storage_gb_limit?: number;
}

export interface CreateMachineParams {
  name: string;
  size: string;
  snapshot_id?: string;
  idempotency_key: string;
}
