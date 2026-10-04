// Wire names and types of the `cmux.cloud` namespace (plans/cmux-next/cloud-app.md section 2). The
// catalog fragment `first-party-apps/cloud/catalog/cloud-catalog.json` is the source of truth; this
// one file mirrors it by hand until the generated client exists, so the lead can swap it for the
// generated module without touching the page. Fields are camelCase like the catalog and the Cloud
// API (`web/app/api/vm/**`). Mutations carry `idempotency_key` in their params (the page envelope
// rule, react-pages.md); the host moves it to the op request's key.
//
// The app server does not implement every op the page lists yet (team, sign-in and sign-out,
// billing, idle policy). It answers those with
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
  tunnelAttach: "cmux.cloud.tunnel.attach",
  tunnelRotateKey: "cmux.cloud.tunnel.rotate_key",
  firewallList: "cmux.cloud.firewall.list",
  firewallGet: "cmux.cloud.firewall.get",
  firewallCreate: "cmux.cloud.firewall.create",
  firewallDelete: "cmux.cloud.firewall.delete",
  planGet: "cmux.cloud.plan.get",
  usageGet: "cmux.cloud.usage.get",
  billingOpen: "cmux.cloud.billing.open",
  fsList: "cmux.cloud.fs.list",
  fsStat: "cmux.cloud.fs.stat",
  fsRead: "cmux.cloud.fs.read",
  fsWrite: "cmux.cloud.fs.write",
  fsMkdir: "cmux.cloud.fs.mkdir",
  fsRemove: "cmux.cloud.fs.remove",
  filePush: "cmux.cloud.file.push",
  filePull: "cmux.cloud.file.pull",
  /** Event stream: one file transfer ended (`done` with `bytes`, or `failed` with a typed error). */
  fileTransferChanged: "cmux.cloud.file.transfer.changed",
  portList: "cmux.cloud.port.list",
  portForward: "cmux.cloud.port.forward",
  portClose: "cmux.cloud.port.close",
  browserOpen: "cmux.cloud.browser.open",
} as const;

/**
 * Host actions that are not Cloud ops. `cloud.browser.open` answers a proxy route and opens no tab;
 * the browser host (owned by the browser lead) opens it: `browser.tab.open {url, machineStore,
 * engine: "cef"}`, where `machineStore` (the tab configuration's BrowserMachineStore) carries the
 * proxy. Only CEF honors a machine store; WebKit refuses a proxied configuration with a typed error.
 * README "Host gaps": the host does not serve this action yet.
 */
export const HostActions = {
  browserTabOpen: "browser.tab.open",
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
 * not here: it makes a new machine and changes nothing that exists. Tunnel attach and key rotation
 * give a device a path into a private network; file push and pull reach any file of this Mac (the
 * host's native file panel picks the local path); file remove deletes data. All of them are origin
 * user only at the server.
 */
export const NATIVE_ACTIONS = new Set<string>([
  CloudOps.authSignIn,
  CloudOps.authSignOut,
  CloudOps.machineDelete,
  CloudOps.publicationCreate,
  CloudOps.publicationUpdate,
  CloudOps.snapshotDelete,
  CloudOps.publicationDelete,
  CloudOps.firewallCreate,
  CloudOps.firewallDelete,
  CloudOps.billingOpen,
  CloudOps.machineConnect,
  CloudOps.tunnelAttach,
  CloudOps.tunnelRotateKey,
  CloudOps.fsRemove,
  CloudOps.filePush,
  CloudOps.filePull,
]);

/** Error codes that mean "the owner does not serve this op yet" (not a failure of the request). */
const UNSUPPORTED_CODES = new Set([
  "cmux.cloud.unsupported",
  "cmux.cloud.unknown_op",
  "cmux.protocol.unknown_op",
  "cmux.app.unknown_action",
  "operation.unsupported",
]);

/**
 * The Cloud API's not-found code of each kind of resource (the `error` field or `x-cmux-vm-error` of
 * its 404; first-party-apps/cloud/server/src/ops/delete_retry.rs `gone_code`). A 404 with this code
 * means the route is there and the resource is not. Keyed by the op's kind (`cmux.cloud.<kind>.`).
 */
export const NOT_FOUND_CODES: Readonly<Record<string, string>> = {
  machine: "vm_not_found",
  snapshot: "vm_snapshot_not_found",
  firewall: "vm_firewall_rule_not_found",
  fs: "vm_file_not_found",
  file: "vm_file_not_found",
  publication: "vm_publication_not_found",
};

/** The own not-found code of `op`'s kind, if the kind has one. */
export function notFoundCode(op: string): string | undefined {
  const kind = op.startsWith("cmux.cloud.") ? op.slice("cmux.cloud.".length).split(".")[0] : "";
  return Object.hasOwn(NOT_FOUND_CODES, kind) ? NOT_FOUND_CODES[kind] : undefined;
}

export function isUnsupported(error: unknown): boolean {
  const code = (error as { code?: unknown } | null)?.code;
  return typeof code === "string" && UNSUPPORTED_CODES.has(code);
}

/** The host's answer to a confirmation action. A declined sheet answers `confirmed: false`. */
export interface ActionRunResult {
  confirmed?: boolean;
}

/** `cloud.file.push` and `cloud.file.pull` answer at once: the copy runs on after the answer. */
export interface TransferStarted {
  transfer: string;
  state: "running";
  machine: string;
  path: string;
  localPath?: string;
}

/** The host's answer to a push or pull action: the op's answer, or a declined sheet. */
export type TransferActionResult = ActionRunResult & Partial<TransferStarted>;

/** One event of `cmux.cloud.file.transfer.changed`: the end of one transfer. */
export interface TransferChanged {
  transfer: string;
  machine: string;
  direction: "push" | "pull";
  path: string;
  localPath?: string;
  state: "done" | "failed";
  bytes?: number;
  error?: { code: string; message?: string; retryable?: boolean };
}

/** More than 4 transfers at once: nothing ran, the same action may run again later. */
export const TRANSFER_BUSY = "cmux.cloud.transfer_busy";

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

/** One DNS record to add for a custom domain. */
export interface DnsInstruction {
  purpose?: string;
  recordTypes?: string[];
  name?: string;
  value?: string;
}

/** `cloud.domain.list` items (`CustomDomainDto`). States are open strings from the Cloud API. */
export interface CloudDomain {
  id: string;
  hostname: string;
  /** `not_required`, `pending`, `verified` or `failed`. */
  verificationState: string;
  /** `missing`, `pending`, `active` or `failed`. */
  certificateState?: string | null;
  createdAt?: string | null;
  dnsInstructions?: DnsInstruction[] | null;
  publications: Array<{ id: string; hostname: string; state: string }>;
}

export interface DomainListResult {
  domains: CloudDomain[];
}

export type AccessMode = "personal" | "team" | "public";

/** `cloud.publication.list` items (`PublicationDto`). */
export interface CloudPublication {
  id: string;
  hostname: string;
  url?: string | null;
  domainKind?: string | null;
  vmId: string;
  port: number;
  accessMode: AccessMode;
  teamId?: string | null;
  state: string;
  routingRevision?: number | null;
  verification?: Record<string, unknown> | null;
}

export interface PublicationListResult {
  publications: CloudPublication[];
}

export interface CloudNetwork {
  id: string;
  cidr?: string | null;
  cidrV6?: string | null;
  scope: "user" | "team";
}

export interface NetworkListResult {
  networks: CloudNetwork[];
}

/** One side of a firewall rule: one identity (vmId, vpcId, tunnelId, cidr or public), port needs protocol. */
export interface FirewallEndpoint {
  vmId?: string;
  vpcId?: string;
  tunnelId?: string;
  cidr?: string;
  public?: true;
  port?: number;
  protocol?: "tcp" | "udp" | "icmp";
}

export interface FirewallRule {
  id: string;
  action: "allow";
  source: FirewallEndpoint;
  destination: FirewallEndpoint;
  description?: string;
  createdAt?: string;
  updatedAt?: string;
}

export interface FirewallListResult {
  rules: FirewallRule[];
}

/** `cloud.firewall.create` input (without the idempotency key). */
export interface NewFirewallRule {
  source: FirewallEndpoint;
  destination: FirewallEndpoint;
  description?: string;
}

/** `cloud.fs.list` entries and the `cloud.fs.stat` answer. */
export interface FsEntry {
  name?: string;
  path?: string;
  kind: "file" | "directory" | "symlink";
  size?: number | null;
  mode?: number | null;
  /** Epoch milliseconds. */
  modifiedAt?: number | null;
}

export interface FsListResult {
  path: string;
  entries: FsEntry[];
}

export interface FsReadResult {
  path: string;
  dataBase64: string;
  size: number;
}

/** A port forward on this Mac (`cloud.port.list` items, the `cloud.port.forward` answer). */
export interface PortForward {
  machine: string;
  port: number;
  host: "127.0.0.1";
  /** Connect here, on 127.0.0.1 only. */
  localPort: number;
  generation: number;
  state: "up" | "down";
  reason?: string | null;
}

export interface PortListResult {
  forwards: PortForward[];
}

/** The args of `HostActions.browserTabOpen`. The host derives the store key from `machine`. */
export interface BrowserTabOpenArgs {
  url: string;
  machineStore: { machine: string; machineName: string; proxy: BrowserRoute["proxy"] };
  engine: "cef";
}

/** `cloud.browser.open`: a proxy route to the machine's localhost and the URL to load through it. */
export interface BrowserRoute {
  machine: string;
  proxy: { kind: "http" | "socks5"; host: "127.0.0.1"; port: number };
  url: string;
  generation: number;
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
