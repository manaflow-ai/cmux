// Wire names and types of the `cmux.cloud` namespace as the Cloud app server `cmux-cloud` answers
// them in the `cmux.wire/1` era (plans/cmux-next/cloud-client-contract.md 1.2 and 1.3; server:
// first-party-apps/cloud/server/src/ops/*.rs and src/api/models.rs). Records are the backend's
// snake_case. The op list is the server's (`ops/mod.rs` OPS) minus what the page does not call;
// the client-only ops (files, ports, browser) keep the catalog fragment's camelCase fields.
// Mutations carry `idempotency_key` in their params (the page envelope rule, react-pages.md); the
// host moves it to the op request's key.

export const CloudOps = {
  authStatus: "cmux.cloud.auth.status",
  machineList: "cmux.cloud.machine.list",
  machineWatch: "cmux.cloud.machine.watch",
  machineCreate: "cmux.cloud.machine.create",
  machineRename: "cmux.cloud.machine.rename",
  machineStart: "cmux.cloud.machine.start",
  machinePause: "cmux.cloud.machine.pause",
  machineResize: "cmux.cloud.machine.resize",
  machineDelete: "cmux.cloud.machine.delete",
  machineIdlePolicySet: "cmux.cloud.machine.idle_policy.set",
  machineUpgrade: "cmux.cloud.machine.upgrade",
  machineConnect: "cmux.cloud.machine.connect",
  snapshotList: "cmux.cloud.snapshot.list",
  snapshotCreate: "cmux.cloud.snapshot.create",
  snapshotRestore: "cmux.cloud.snapshot.restore",
  snapshotDelete: "cmux.cloud.snapshot.delete",
  planGet: "cmux.cloud.plan.get",
  billingCheckout: "cmux.cloud.billing.checkout",
  migrationStatus: "cmux.cloud.migration.status",
  migrationStart: "cmux.cloud.migration.start",
  fsList: "cmux.cloud.fs.list",
  fsStat: "cmux.cloud.fs.stat",
  fsRead: "cmux.cloud.fs.read",
  fsWrite: "cmux.cloud.fs.write",
  fsMkdir: "cmux.cloud.fs.mkdir",
  fsRemove: "cmux.cloud.fs.remove",
  filePush: "cmux.cloud.file.push",
  filePull: "cmux.cloud.file.pull",
  /** Event stream: one file transfer ended (`done`, `failed` or `cancelled`). */
  fileTransferChanged: "cmux.cloud.file.transfer.changed",
  portList: "cmux.cloud.port.list",
  portForward: "cmux.cloud.port.forward",
  portClose: "cmux.cloud.port.close",
  browserOpen: "cmux.cloud.browser.open",
} as const;

/**
 * Account ops no catalog declares yet (first-party-apps/cloud/README.md "Gaps": the host credential
 * owner will). No server serves them: each answers an unknown-op error, and the page shows "Not
 * available yet" for it.
 */
export const AccountOps = {
  signIn: "cmux.cloud.auth.sign_in",
  signOut: "cmux.cloud.auth.sign_out",
  teamList: "cmux.cloud.team.list",
  teamSelect: "cmux.cloud.team.select",
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
 * Ops the page never calls itself. The server runs them only for origin `user` (`ops/mod.rs`
 * `Kind::UserOnly`: money, destructive, and the one-way migration and upgrade; decision D-MONEY),
 * or they reach files of this Mac, or they change this client's view. The page asks the host to run
 * them as a catalog action (`cmux.app.action.run {action: <op>, args}`): the host shows the native
 * confirmation sheet (or file panel), stamps origin user and runs the op. Page JavaScript cannot
 * prove a gesture. The host answers the op's result fields at the top level, or `{confirmed: false}`
 * for a declined sheet.
 */
export const NATIVE_ACTIONS = new Set<string>([
  AccountOps.signIn,
  AccountOps.signOut,
  CloudOps.machineCreate,
  CloudOps.machineResize,
  CloudOps.machineDelete,
  CloudOps.machineUpgrade,
  CloudOps.machineConnect,
  CloudOps.snapshotCreate,
  CloudOps.snapshotRestore,
  CloudOps.snapshotDelete,
  CloudOps.billingCheckout,
  CloudOps.migrationStart,
  CloudOps.fsRemove,
  CloudOps.filePush,
  CloudOps.filePull,
]);

/** Server error codes the page reads (first-party-apps/cloud/server/src/api/error.rs, fs/mod.rs). */
export const CloudErrors = {
  notFound: "cmux.cloud.not_found",
  unsupported: "cmux.cloud.unsupported",
  planRequired: "cmux.cloud.plan_required",
  quotaExceeded: "cmux.cloud.quota_exceeded",
  sizeLocked: "cmux.cloud.size_locked",
  /** No machine image is configured for this deployment yet (dev until the image lane has one). */
  noSnapshotConfigured: "cmux.cloud.no_snapshot_configured",
  fileOpsBusy: "cmux.cloud.file_ops_busy",
  fileTooLarge: "cmux.cloud.file_too_large",
  /** More than 4 transfers at once: nothing ran, the same action may run again later. */
  transferBusy: "cmux.cloud.transfer_busy",
} as const;

/** Error codes that mean "the owner does not serve this op yet" (not a failure of the request). */
const UNSUPPORTED_CODES = new Set([
  CloudErrors.unsupported,
  "cmux.cloud.unknown_op",
  "cmux.protocol.unknown_op",
  "cmux.app.unknown_action",
  "operation.unsupported",
]);

const codeOf = (error: unknown) => (error as { code?: unknown } | null)?.code;

export function isUnsupported(error: unknown): boolean {
  const code = codeOf(error);
  return typeof code === "string" && UNSUPPORTED_CODES.has(code);
}

/**
 * The item a delete or remove names is not there (`cloud.machine.not_found`,
 * `cloud.snapshot.not_found`, a daemon `fs.not_found`): the outcome the person asked for.
 */
export function isGone(error: unknown): boolean {
  return codeOf(error) === CloudErrors.notFound;
}

/** A typed plan refusal (contract 1.5). The backend reads the plan; the page never computes one. */
export interface PlanRefusal {
  kind: "plan_required" | "quota_exceeded" | "size_locked";
  limit?: number;
  used?: number;
  /**
   * The plan "See plans" checks out: the error's `details.plan`, else `CloudPlan.upgrade_plan`.
   * Absent when neither names one (null = no plan lifts the limit): the sentence shows alone.
   */
  plan?: string;
}

const PLAN_KINDS: Record<string, PlanRefusal["kind"]> = {
  [CloudErrors.planRequired]: "plan_required",
  [CloudErrors.quotaExceeded]: "quota_exceeded",
  [CloudErrors.sizeLocked]: "size_locked",
};

/**
 * The plan refusal of `error`, read from its code and `details` (`{limit, used}`, `{plan}`).
 * `upgradePlan` is `CloudPlan.upgrade_plan`: the plan to offer when the error names none.
 */
export function planRefusal(error: unknown, upgradePlan?: string | null): PlanRefusal | undefined {
  const code = codeOf(error);
  const kind = typeof code === "string" ? PLAN_KINDS[code] : undefined;
  if (!kind) return undefined;
  const details = (error as { details?: unknown }).details;
  const d = details && typeof details === "object" ? (details as Record<string, unknown>) : {};
  const plan = typeof d.plan === "string" && d.plan ? d.plan : upgradePlan || undefined;
  return {
    kind,
    ...(typeof d.limit === "number" ? { limit: d.limit } : {}),
    ...(typeof d.used === "number" ? { used: d.used } : {}),
    ...(plan ? { plan } : {}),
  };
}

/** The host's answer to a confirmation action. A declined sheet answers `confirmed: false`. */
export interface ActionRunResult {
  confirmed?: boolean;
}

/** `cloud.file.push` and `cloud.file.pull` answer at once: the copy runs on after the answer. */
export interface TransferStarted {
  ok?: true;
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
  state: "done" | "failed" | "cancelled";
  bytes?: number;
  error?: { code: string; message?: string; retryable?: boolean };
}

/** `CloudMachine.status` (contract 1.2); a status the page does not know becomes `unknown`. */
export type MachineStatus =
  | "provisioning"
  | "starting"
  | "running"
  | "pausing"
  | "paused"
  | "deleting"
  | "failed"
  | "unknown";

/** A machine size. Create and resize send at least one field; the plan decides which are allowed. */
export interface MachineSize {
  cpu?: number | null;
  memory_mb?: number | null;
  disk_mb?: number | null;
}

/** `CloudMachine` (contract 1.2; server `api/models.rs` `Machine`). Owner: the team's CloudDO. */
export interface CloudMachine {
  id: string;
  team?: string | null;
  creator?: string | null;
  name?: string | null;
  size?: MachineSize | null;
  status: MachineStatus;
  image?: { id: string; daemon_version?: string | null } | null;
  /** The overlay host id; null until the machine is bound. */
  host?: string | null;
  /** Imported from cmux Cloud classic: read-only here until upgraded (contract 4). */
  classic?: boolean;
  /** Epoch milliseconds. */
  created_at?: number | null;
  last_active_at?: number | null;
  idle_policy?: { idle_seconds?: number | null } | null;
  error?: { code: string; message?: string | null; at?: number | null } | null;
  /** The record's own revision: a decimal string that only grows. */
  revision: string;
}

export interface MachineListResult {
  machines: CloudMachine[];
  /** More machines follow: list again with this cursor. */
  next_cursor?: string | null;
  /** The projection revision; watch events at or below it are already in the page. */
  revision: number;
}

/** One event of `cmux.cloud.machine.watch`. Events of one projection change share its revision. */
export type MachineEvent =
  | { type: "upsert"; revision: number; machine: CloudMachine }
  | { type: "removed"; revision: number; id: string };

/**
 * A machine mutation's answer (create, rename, start, pause, resize, idle policy, upgrade, snapshot
 * restore): the record and the projection revision its change reached. When the page's mirror has
 * that revision, the intent settles without a refetch.
 */
export interface MachineResult {
  machine: CloudMachine;
  revision: number;
}

/** A delete's answer; a retry after the delete answers the same. */
export interface DeletedResult {
  deleted: true;
}

/** `CloudSnapshot` (contract 1.2). */
export interface CloudSnapshot {
  id: string;
  machine?: string | null;
  name?: string | null;
  size_mb?: number | null;
  status?: string | null;
  /** Epoch milliseconds. */
  created_at?: number | null;
  revision: string;
}

export interface SnapshotListResult {
  snapshots: CloudSnapshot[];
}

export interface SnapshotResult {
  snapshot: CloudSnapshot;
}

/** `CloudPlan`: limits and usage in one record (`cloud.usage.get` folded in). No plan logic here. */
export interface CloudPlan {
  plan_id: string;
  /** The plan that lifts this plan's limits ("See plans"); null when no plan does. */
  upgrade_plan?: string | null;
  limits: {
    max_active: number;
    max_saved: number;
    /** Memory sizes the plan offers, locked ones included. */
    memory_options_mb: number[];
    /** Offered sizes that need another plan: shown, not selectable. */
    locked_memory_options_mb: number[];
    vm_hours_included?: number | null;
  };
  usage: {
    active: number;
    saved: number;
    vm_hours_used?: number | null;
    /** Epoch milliseconds. */
    period_end?: number | null;
  };
}

/** `cloud.billing.checkout {plan}`: the host opens the https URL in the browser. */
export interface CheckoutResult {
  url: string;
}

export type MigrationState = "none" | "available" | "moving" | "moved";

/** `cloud.migration.status` (contract 4). */
export interface MigrationStatus {
  state: MigrationState;
  classic_count: number;
  imported: string[];
}

/** `cloud.migration.start`: one way, per user. */
export interface MigrationStarted {
  state: MigrationState;
}

/** `cloud.machine.create` params (contract 1.3), without the key. */
export interface CreateMachineArgs {
  /** 1 to 80 characters; absent = the owner names the machine. */
  name?: string;
  size: MachineSize;
  image?: string;
  from_snapshot?: string;
}

/** `cloud.fs.list` entries and the `cloud.fs.stat` answer (server `fs/files.rs` `Entry`). */
export interface FsEntry {
  /** The entry name (list) or absent (stat). */
  name?: string;
  /** The full path (stat). */
  path?: string;
  kind: "file" | "directory" | "symlink" | "other";
  size?: number | null;
  mode?: number | null;
  /** Epoch milliseconds. */
  modifiedAt?: number | null;
  /** The daemon's revision, for a `baseRevision` write (stat only). */
  revision?: string;
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

export interface FsWriteResult {
  ok: true;
  path: string;
  size: number;
  revision?: string | null;
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
