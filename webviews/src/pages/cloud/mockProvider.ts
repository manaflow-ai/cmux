// An in-memory `cmux.cloud` provider for the browser dev loop (`/cloud/?mock`) and tests. It is not
// the backend: the Cloud app server (first-party-apps/cloud/server) owns machines, idempotency and
// the native confirmations. The mock answers like the server does today (`cmux.wire/1` records, the
// same fields and error codes, the origin, key and argument guards of `ops/mod.rs`) and creates no
// real resource.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { SAMPLE_FS_MACHINES, sampleAccount, sampleMachines, sampleSnapshots } from "./mockData";
import { joinPath } from "./files";
import { MockEdge, MockFiles, notFound, only } from "./mockEdge";
import {
  ACTION_RUN,
  AccountOps,
  CloudErrors,
  CloudOps,
  HostActions,
  NATIVE_ACTIONS,
  type CloudMachine,
  type CloudPlan,
  type CloudSnapshot,
  type MachineEvent,
  type MachineResult,
  type TransferChanged,
} from "./ops";

export { sampleMachines } from "./mockData";

/**
 * Ops the Cloud app server does not serve (first-party-apps/cloud/README.md "Gaps": no catalog
 * declares them yet), and host actions the host does not serve yet. The mock answers them like the
 * server: an unknown-op error. Pass `unsupported: []` to drive the page's full design.
 */
export const SERVER_GAPS: readonly string[] = [
  AccountOps.signIn,
  AccountOps.signOut,
  AccountOps.teamList,
  AccountOps.teamSelect,
  // A host action, not a Cloud op: the browser host cannot open a tab through a proxy yet.
  HostActions.browserTabOpen,
];

/** Server reads (`Kind::Read`): an idempotency key is refused. */
const READS = new Set<string>([
  CloudOps.authStatus,
  AccountOps.teamList,
  CloudOps.machineList,
  CloudOps.machineWatch,
  CloudOps.snapshotList,
  CloudOps.planGet,
  CloudOps.migrationStatus,
  CloudOps.fsList,
  CloudOps.fsStat,
  CloudOps.fsRead,
  CloudOps.portList,
]);

/** Server ops for origin `user` only (`Kind::UserOnly`): the page must send them as native actions. */
const USER_ONLY = new Set<string>([
  CloudOps.machineCreate,
  CloudOps.machineResize,
  CloudOps.machineDelete,
  CloudOps.machineUpgrade,
  CloudOps.snapshotCreate,
  CloudOps.snapshotRestore,
  CloudOps.snapshotDelete,
  CloudOps.billingCheckout,
  CloudOps.migrationStart,
  CloudOps.fsRemove,
  CloudOps.filePush,
  CloudOps.filePull,
]);

/** Live ops the server never replays from its ledger (forwards and routes are live state). */
const RERUN = new Set<string>([CloudOps.portForward, CloudOps.browserOpen]);

/** Statuses that count against `max_active`. */
const ACTIVE = new Set<string>(["provisioning", "starting", "running"]);

export interface MockCall {
  op: string;
  params: unknown;
}

export interface MockOptions {
  signedIn?: boolean;
  /** Hold watch events until `releaseEvents()` (to see pending intents). */
  holdEvents?: boolean;
  /** The user's answer to every native confirmation sheet. */
  confirm?: boolean;
  /** Ops answered as not served (default `SERVER_GAPS`). */
  unsupported?: readonly string[];
  /** Keep file transfers running until `finishTransfers()` (else each ends right after it starts). */
  holdTransfers?: boolean;
  /** Machines per `cloud.machine.list` page (the server's limit is 1 to 100). */
  pageSize?: number;
}

type Params = Record<string, unknown>;

export class MockCloudProvider implements PageClient {
  readonly calls: MockCall[] = [];
  machines: CloudMachine[] = sampleMachines();
  snapshots: CloudSnapshot[] = sampleSnapshots();
  account = sampleAccount();
  /** Machines whose daemon reports `fs-v1`; file ops on the others answer `unsupported`. */
  readonly fsMachines = new Set<string>(SAMPLE_FS_MACHINES);
  signedIn: boolean;
  confirm: boolean;
  unsupported: Set<string>;
  /** Set to make every call reject as if the host went away. */
  offline = false;
  /** The next call of this op fails with a retryable owner error. */
  failNext?: string;
  /** Runs after the list result is taken and before it is answered (an event during the list). */
  onList?: () => void;
  /** The host's typed refusal of a proxied tab (CEF unavailable, or WebKit refused the proxy). */
  tabError?: string;
  /** The next delete finds the machine already gone: it is removed and answered `not_found`. */
  notFoundOnDelete = false;
  /** The next call of this op (or native action) runs, then answers `not_found` (already gone). */
  goneNext?: string;
  /** The account has no paid plan: create and restore answer `plan_required`. */
  planRequired = false;
  holdTransfers: boolean;
  pageSize: number;
  /** The owner's normalization of a new name (the echo then differs from the intent). */
  renameTransform?: (name: string) => string;
  /** Files of each machine and this Mac's port forwards and browser routes. */
  readonly fs = new MockFiles();
  readonly edge = new MockEdge();
  /** The projection revision: one step per change, shared by the events of that change. */
  revision = 10;
  private nextId = 1;
  /** Idempotency ledger: key -> op, args and recorded result (a replay answers it and emits nothing). */
  private readonly ledger = new Map<string, { op: string; args: string; result: unknown }>();
  private readonly subs = new Map<
    number,
    { stream: string; listener: (data: unknown, seq: number) => void; seq: number }
  >();
  private nextSub = 1;
  private readonly handlers = new Map<string, PageHandler>();
  private held: MachineEvent[] | null;

  constructor(options: MockOptions = {}) {
    this.signedIn = options.signedIn ?? true;
    this.confirm = options.confirm ?? true;
    this.unsupported = new Set(options.unsupported ?? SERVER_GAPS);
    this.held = options.holdEvents ? [] : null;
    this.holdTransfers = options.holdTransfers ?? false;
    this.pageSize = options.pageSize ?? 100;
  }

  async call<R>(op: string, params: unknown): Promise<R> {
    this.calls.push({ op, params });
    if (this.offline) throw pageError("cmux.protocol.transport", "disconnected", true);
    if (this.failNext === op) {
      this.failNext = undefined;
      throw pageError("cmux.cloud.upstream_error", "The Cloud service did not answer.", true);
    }
    const p = (params ?? {}) as Params;
    if (op === CloudOps.authStatus) return this.authStatus() as R;
    if (op === ACTION_RUN && p.action === AccountOps.signIn) return this.runAction(p) as R;
    if (!this.signedIn) throw pageError("cmux.cloud.auth_required", "Sign in to cmux Cloud.");
    if (op === ACTION_RUN) return this.runAction(p) as R;
    return this.keyed(op, p, false) as R;
  }

  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    if (this.offline) throw pageError("cmux.protocol.transport", "disconnected", true);
    if (stream !== CloudOps.machineWatch && stream !== CloudOps.fileTransferChanged)
      throw pageError("cmux.protocol.unknown_op", stream);
    this.calls.push({ op: `subscribe ${stream}`, params: undefined });
    const sub = this.nextSub++;
    this.subs.set(sub, { stream, listener: onEvent as (data: unknown, seq: number) => void, seq: 0 });
    return () => void this.subs.delete(sub);
  }

  handle(op: string, handler: PageHandler): () => void {
    this.handlers.set(op, handler);
    return () => void this.handlers.delete(op);
  }

  /** Host to page call (the dispatcher's page command in the dev loop). */
  invoke(op: string, params: unknown): unknown {
    return this.handlers.get(op)?.(params);
  }

  get forwards() {
    return this.edge.forwards;
  }

  get watchers(): number {
    return [...this.subs.values()].filter((sub) => sub.stream === CloudOps.machineWatch).length;
  }

  /** The plan as the backend reads it: fixed limits, usage from the machines and snapshots. */
  get plan(): CloudPlan {
    const p = this.account.plan;
    return {
      plan_id: p.plan_id,
      limits: {
        max_active: p.max_active,
        max_saved: p.max_saved,
        memory_options_mb: p.memory_options_mb,
        locked_memory_options_mb: p.locked_memory_options_mb,
        vm_hours_included: p.vm_hours_included,
      },
      usage: {
        active: this.machines.filter((m) => ACTIVE.has(m.status)).length,
        saved: this.snapshots.length,
        vm_hours_used: p.vm_hours_used,
        period_end: p.period_end,
      },
    };
  }

  /** The running copies end now: one `file.transfer.changed` event each (the server's worker woke). */
  finishTransfers(): TransferChanged[] {
    const ended = this.fs.finishTransfers();
    for (const event of ended) this.deliverTo(CloudOps.fileTransferChanged, event);
    return ended;
  }

  /** Another client cancelled the running copies: one `cancelled` event each. */
  cancelTransfers(): TransferChanged[] {
    const ended = this.fs.cancelTransfers();
    for (const event of ended) this.deliverTo(CloudOps.fileTransferChanged, event);
    return ended;
  }

  /** The owner changed a machine (or added one) and notifies: one change, one revision. */
  emitUpsert(machine: CloudMachine): void {
    const index = this.machines.findIndex((m) => m.id === machine.id);
    if (index >= 0 && JSON.stringify(this.machines[index]) === JSON.stringify(machine)) return;
    if (index < 0) this.machines.push(machine);
    else this.machines[index] = machine;
    this.emit({ type: "upsert", revision: ++this.revision, machine });
  }

  emitRemoved(id: string): void {
    if (!this.machines.some((machine) => machine.id === id)) return;
    this.machines = this.machines.filter((machine) => machine.id !== id);
    this.emit({ type: "removed", revision: ++this.revision, id });
  }

  /** Delivers an event as is (for stale-revision tests). */
  emitRaw(event: MachineEvent): void {
    this.deliver(event);
  }

  releaseEvents(): void {
    const held = this.held ?? [];
    this.held = null;
    for (const event of held) this.deliver(event);
  }

  private emit(event: MachineEvent): void {
    if (this.held) this.held.push(event);
    else this.deliver(event);
  }

  private deliver(event: MachineEvent): void {
    this.deliverTo(CloudOps.machineWatch, event);
  }

  private deliverTo(stream: string, event: unknown): void {
    for (const sub of this.subs.values()) if (sub.stream === stream) sub.listener(event, ++sub.seq);
  }

  private authStatus() {
    return this.signedIn ? { signedIn: true, team: this.account.team } : { signedIn: false, team: null };
  }

  private machine(params: Params): CloudMachine {
    const machine = this.machines.find((m) => m.id === params.machine);
    if (!machine) throw notFound(`no machine ${String(params.machine)}`);
    return machine;
  }

  /** Changes a machine as the owner would: a new record revision, the echo, then the answer. */
  private change(params: Params, patch: Partial<CloudMachine>): MachineResult {
    const current = this.machine(params);
    const machine = { ...current, ...patch, revision: String(Number(current.revision) + 1) };
    this.emitUpsert(machine);
    return { machine, revision: this.revision };
  }

  /** The backend's plan checks before any provider call (contract 1.5). */
  private checkPlan(memoryMb: unknown, activeDelta: number): void {
    if (this.planRequired)
      throw pageError(CloudErrors.planRequired, "Cloud machines need a paid plan", false, { plan: "pro" });
    if (typeof memoryMb === "number" && this.account.plan.locked_memory_options_mb.includes(memoryMb))
      throw pageError(CloudErrors.sizeLocked, "this size needs another plan", false, { memory_mb: memoryMb });
    const { limits, usage } = this.plan;
    if (activeDelta > 0 && usage.active + activeDelta > limits.max_active)
      throw pageError(CloudErrors.quotaExceeded, `this plan allows ${limits.max_active} active machines`, false, {
        limit: limits.max_active,
        used: usage.active,
      });
  }

  private create(name: unknown, memoryMb: unknown): MachineResult {
    const machine: CloudMachine = {
      id: `vm_new${this.nextId++}`,
      team: this.account.team,
      creator: "user_dev1",
      name: typeof name === "string" && name ? name : null,
      size: { cpu: 2, memory_mb: typeof memoryMb === "number" ? memoryMb : 4096, disk_mb: 16_384 },
      status: "provisioning",
      image: { id: "img_base1", daemon_version: "0.40.0" },
      host: null,
      classic: false,
      created_at: Date.UTC(2026, 9, 2),
      last_active_at: null,
      idle_policy: null,
      error: null,
      revision: "1",
    };
    this.emitUpsert(machine);
    return { machine, revision: this.revision };
  }

  /** The server's guards and ledger: a mutation key replays its recorded result and changes nothing. */
  private keyed(op: string, p: Params, viaHost: boolean): unknown {
    const key = typeof p.idempotency_key === "string" ? p.idempotency_key.trim() : undefined;
    if (USER_ONLY.has(op) && !viaHost)
      throw pageError("cmux.cloud.origin_refused", `${op.slice("cmux.".length)} needs a person: confirm it in cmux`);
    if (READS.has(op) && key)
      throw pageError("cmux.cloud.idempotency_key_forbidden", `${op} is a read and takes no idempotency key`);
    // Account ops are the host's (no catalog row yet): the server's key rule does not apply.
    const account = (Object.values(AccountOps) as string[]).includes(op);
    if (!READS.has(op) && !account && !key && !this.unsupported.has(op))
      throw pageError("cmux.cloud.idempotency_key_required", `${op} needs an idempotency key`);
    const args = { ...p };
    delete args.idempotency_key;
    const recorded = key ? this.ledger.get(key) : undefined;
    if (recorded) {
      if (recorded.op !== op || recorded.args !== JSON.stringify(args))
        throw pageError("cmux.cloud.idempotency_conflict", "this key was used for another request");
      return recorded.result;
    }
    const result = this.serveOp(op, args);
    if (this.goneNext === op) {
      this.goneNext = undefined;
      throw notFound("The Cloud service does not know this item.");
    }
    if (key && !RERUN.has(op)) this.ledger.set(key, { op, args: JSON.stringify(args), result });
    return result;
  }

  private serveOp(op: string, p: Params): unknown {
    if (this.unsupported.has(op)) throw pageError("cmux.cloud.unknown_op", `${op} is not a Cloud op`);
    const a = this.account;
    switch (op) {
      case AccountOps.signOut:
        this.signedIn = false;
        return { ok: true };
      case AccountOps.teamList:
        return a.teams;
      case AccountOps.teamSelect:
        a.team = String(p.team);
        return { ok: true };
      case CloudOps.machineList: {
        only(p, ["cursor", "limit"]);
        const start = typeof p.cursor === "string" ? Number(p.cursor.slice("cur_".length)) : 0;
        const size = typeof p.limit === "number" ? p.limit : this.pageSize;
        const end = start + size;
        const result = {
          machines: this.machines.slice(start, end),
          next_cursor: end < this.machines.length ? `cur_${end}` : null,
          revision: this.revision,
        };
        this.onList?.();
        return result;
      }
      case CloudOps.machineCreate: {
        only(p, ["name", "size", "image", "from_snapshot"]);
        const size = (p.size ?? undefined) as { memory_mb?: unknown } | undefined;
        if (!size || typeof size !== "object") throw pageError("cmux.cloud.invalid_args", "size is required");
        if (typeof p.from_snapshot === "string" && !this.snapshots.some((s) => s.id === p.from_snapshot))
          throw notFound(`no snapshot ${p.from_snapshot}`);
        this.checkPlan(size.memory_mb, 1);
        return this.create(p.name, size.memory_mb);
      }
      case CloudOps.machineRename:
        only(p, ["machine", "name"]);
        return this.change(p, { name: (this.renameTransform ?? String)(String(p.name).trim()) });
      case CloudOps.machineStart: {
        only(p, ["machine"]);
        if (!ACTIVE.has(this.machine(p).status)) this.checkPlan(undefined, 1);
        return this.change(p, { status: "running" });
      }
      case CloudOps.machinePause:
        only(p, ["machine"]);
        return this.change(p, { status: "paused" });
      case CloudOps.machineResize: {
        only(p, ["machine", "size"]);
        const size = (p.size ?? {}) as { memory_mb?: number };
        this.checkPlan(size.memory_mb, 0);
        return this.change(p, { size: { ...this.machine(p).size, ...size } });
      }
      case CloudOps.machineIdlePolicySet:
        only(p, ["machine", "idle_seconds"]);
        return this.change(p, { idle_policy: { idle_seconds: Number(p.idle_seconds) } });
      case CloudOps.machineUpgrade: {
        only(p, ["machine"]);
        const machine = this.machine(p);
        if (!machine.classic) throw pageError("cmux.cloud.not_classic", `${machine.id} is not a classic machine`);
        return this.change(p, {
          classic: false,
          host: `host_${machine.id}`,
          image: { id: "img_base1", daemon_version: "0.40.0" },
        });
      }
      case CloudOps.machineDelete:
        only(p, ["machine"]);
        this.machine(p);
        this.emitRemoved(String(p.machine));
        if (this.notFoundOnDelete) {
          this.notFoundOnDelete = false;
          throw notFound("The Cloud service does not know this machine.");
        }
        return { deleted: true };
      case CloudOps.snapshotList:
        only(p, ["machine"]);
        return { snapshots: this.snapshots.filter((s) => p.machine === undefined || s.machine === p.machine) };
      case CloudOps.snapshotCreate: {
        only(p, ["machine", "name"]);
        this.machine(p);
        const { limits, usage } = this.plan;
        if (usage.saved >= limits.max_saved)
          throw pageError(CloudErrors.quotaExceeded, `this plan keeps ${limits.max_saved} saved snapshots`, false, {
            limit: limits.max_saved,
            used: usage.saved,
          });
        const snapshot: CloudSnapshot = {
          id: `snap_new${this.nextId++}`,
          machine: String(p.machine),
          name: typeof p.name === "string" ? p.name : null,
          size_mb: 1024,
          status: "ready",
          created_at: Date.UTC(2026, 9, 2),
          revision: "1",
        };
        this.snapshots = [snapshot, ...this.snapshots];
        return { snapshot };
      }
      case CloudOps.snapshotRestore: {
        only(p, ["snapshot", "name"]);
        // A new machine from the snapshot; the source machine does not change.
        const snapshot = this.snapshots.find((s) => s.id === p.snapshot);
        if (!snapshot) throw notFound(`no snapshot ${String(p.snapshot)}`);
        this.checkPlan(undefined, 1);
        return this.create(typeof p.name === "string" ? p.name : (snapshot.name ?? null), undefined);
      }
      case CloudOps.snapshotDelete:
        only(p, ["snapshot"]);
        if (!this.snapshots.some((s) => s.id === p.snapshot)) throw notFound(`no snapshot ${String(p.snapshot)}`);
        this.snapshots = this.snapshots.filter((s) => s.id !== p.snapshot);
        return { deleted: true };
      case CloudOps.planGet:
        only(p, []);
        return this.plan;
      case CloudOps.billingCheckout:
        only(p, ["plan"]);
        return { url: `https://checkout.example.test/c/${String(p.plan)}` };
      case CloudOps.migrationStatus:
        only(p, []);
        return { ...a.migration };
      case CloudOps.migrationStart:
        only(p, []);
        if (a.migration.state === "none")
          throw pageError("cmux.cloud.migration_unavailable", "no classic machines to move");
        a.migration = { ...a.migration, state: "moving" };
        return { state: "moving" };
      default:
        if (MockFiles.serves(op)) return this.files(op, p);
        if (MockEdge.serves(op)) return this.edge.serve(op, p, (params) => this.machine(params).id);
        throw pageError("cmux.cloud.unknown_op", `${op} is not a Cloud op`);
    }
  }

  /** File ops: the argument checks, then the `fs-v1` gate on the machine's daemon (server link_files.rs). */
  private files(op: string, p: Params): unknown {
    this.fs.check(op, p);
    const machine = this.machine(p);
    if (!machine.host)
      throw pageError("cmux.cloud.not_bound", "the machine is still provisioning; it has no host yet", true);
    if (!this.fsMachines.has(machine.id))
      throw pageError(CloudErrors.unsupported, "The machine's cmux daemon has no file ops yet (needs fs-v1)");
    if (machine.status === "paused")
      throw pageError("cmux.cloud.machine_paused", "The machine is paused: start it to use its files");
    return this.fs.serve(op, p, machine.id);
  }

  /** The host's native confirmation: on yes it runs the op as origin user and answers its result. */
  private runAction(p: Params): unknown {
    const action = String(p.action);
    if (action === HostActions.browserTabOpen) {
      if (this.unsupported.has(action)) throw pageError("cmux.app.unknown_action", action);
      if (this.tabError) throw pageError(this.tabError, "the browser refused the proxied tab");
      return { confirmed: true };
    }
    if (!NATIVE_ACTIONS.has(action)) throw pageError("cmux.app.unknown_action", action);
    if (this.unsupported.has(action)) throw pageError("cmux.cloud.unknown_op", `${action} is not a Cloud op`);
    if (action === CloudOps.machineConnect) return { confirmed: true };
    if (!this.confirm) return { confirmed: false };
    if (action === AccountOps.signIn) return ((this.signedIn = true), { confirmed: true });
    const result = this.keyed(action, hostFields(action, (p.args ?? {}) as Params), true);
    // A transfer answers `running` at once; its end is a `file.transfer.changed` event.
    if ((action === CloudOps.filePush || action === CloudOps.filePull) && !this.holdTransfers)
      queueMicrotask(() => this.finishTransfers());
    return { confirmed: true, ...(result as object) };
  }
}

/**
 * What the host adds after its native confirmation, before it runs the op as origin user: the local
 * path the person picked in the file panel. The page never sends it.
 */
function hostFields(action: string, args: Params): Params {
  switch (action) {
    case CloudOps.filePush:
      return { ...args, localPath: "/Users/dev/upload.txt", path: joinPath(String(args.path), "upload.txt") };
    case CloudOps.filePull:
      return { ...args, localPath: "/Users/dev/Downloads/pulled" };
    default:
      return args;
  }
}
