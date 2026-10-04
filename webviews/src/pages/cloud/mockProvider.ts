// An in-memory `cmux.cloud` provider for the browser dev loop (`/cloud/?mock`) and tests. It is not
// the backend: the Cloud app server (first-party-apps/cloud/server) owns machines, idempotency and
// the native confirmations. The mock keeps only enough of them to drive the page, and creates no
// real resource.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { sampleAccount, sampleMachines, sampleSnapshots, sampleStats } from "./mockData";
import {
  ACTION_RUN,
  CloudOps,
  NATIVE_ACTIONS,
  type CloudMachine,
  type CloudPublication,
  type CloudSnapshot,
  type MachineEvent,
  type MachineMutationResult,
} from "./ops";

export { sampleMachines } from "./mockData";

/**
 * Ops the Cloud app server does not serve yet (first-party-apps/cloud/README.md "Gaps"). The mock
 * answers them like the server: `cmux.cloud.unsupported` for the idle policy, an unknown-op error
 * for the rest. Pass `unsupported: []` to drive the page's full design.
 */
export const SERVER_GAPS: readonly string[] = [
  CloudOps.machineIdlePolicySet,
  CloudOps.authSignIn,
  CloudOps.authSignOut,
  CloudOps.teamList,
  CloudOps.teamSelect,
  CloudOps.domainList,
  CloudOps.domainVerify,
  CloudOps.publicationList,
  CloudOps.publicationCreate,
  CloudOps.publicationUpdate,
  CloudOps.publicationDelete,
  CloudOps.publicationVerify,
  CloudOps.networkList,
  CloudOps.firewallList,
  CloudOps.firewallGet,
  CloudOps.firewallCreate,
  CloudOps.firewallDelete,
  CloudOps.billingOpen,
];

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
}

type Params = Record<string, unknown>;

export class MockCloudProvider implements PageClient {
  readonly calls: MockCall[] = [];
  machines: CloudMachine[] = sampleMachines();
  snapshots: Array<CloudSnapshot & { machine: string }> = sampleSnapshots();
  account = sampleAccount();
  signedIn: boolean;
  confirm: boolean;
  unsupported: Set<string>;
  /** Set to make every call reject as if the host went away. */
  offline = false;
  /** The next call of this op fails with a retryable owner error. */
  failNext?: string;
  /** Runs after the list result is taken and before it is answered (an event during the list). */
  onList?: () => void;
  /** The next delete finds the machine already gone: it is removed and answered `not_found`. */
  notFoundOnDelete = false;
  /** The owner's normalization of a new name (the echo then differs from the intent). */
  renameTransform?: (name: string) => string;
  /** The projection revision: one step per change, shared by the events of that change. */
  revision = 10;
  private nextId = 1;
  private readonly memory = new Map<string, number>();
  /** Idempotency ledger: key -> op, args and recorded result (a replay answers it and emits nothing). */
  private readonly ledger = new Map<string, { op: string; args: string; result: unknown }>();
  private readonly subs = new Map<number, { listener: (data: unknown, seq: number) => void; seq: number }>();
  private nextSub = 1;
  private readonly handlers = new Map<string, PageHandler>();
  private held: MachineEvent[] | null;

  constructor(options: MockOptions = {}) {
    this.signedIn = options.signedIn ?? true;
    this.confirm = options.confirm ?? true;
    this.unsupported = new Set(options.unsupported ?? SERVER_GAPS);
    this.held = options.holdEvents ? [] : null;
  }

  async call<R>(op: string, params: unknown): Promise<R> {
    this.calls.push({ op, params });
    if (this.offline) throw pageError("cmux.protocol.transport", "disconnected", true);
    if (this.failNext === op) {
      this.failNext = undefined;
      throw pageError("cmux.cloud.upstream", "The Cloud service did not answer.", true);
    }
    const p = (params ?? {}) as Params;
    if (op === CloudOps.authStatus) return this.authStatus() as R;
    if (op === ACTION_RUN && p.action === CloudOps.authSignIn) return this.runAction(p) as R;
    if (!this.signedIn) throw pageError("cmux.cloud.auth_required", "Sign in to cmux Cloud.");
    if (op === ACTION_RUN) return this.runAction(p) as R;
    return this.keyed(op, p) as R;
  }

  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    if (this.offline) throw pageError("cmux.protocol.transport", "disconnected", true);
    if (stream !== CloudOps.machineWatch) throw pageError("cmux.protocol.unknown_op", stream);
    const sub = this.nextSub++;
    this.subs.set(sub, { listener: onEvent as (data: unknown, seq: number) => void, seq: 0 });
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

  get watchers(): number {
    return this.subs.size;
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
    for (const sub of this.subs.values()) sub.listener(event, ++sub.seq);
  }

  private authStatus() {
    return this.signedIn ? { signedIn: true, team: this.account.team } : { signedIn: false, team: null };
  }

  private machine(params: Params): CloudMachine {
    const machine = this.machines.find((m) => m.id === params.machine);
    if (!machine) throw pageError("cmux.cloud.not_found", `no machine ${String(params.machine)}`);
    return machine;
  }

  /** Changes a machine as the owner would: emits the echo, answers the record with its revision. */
  private change(params: Params, patch: Partial<CloudMachine>): MachineMutationResult {
    const machine = { ...this.machine(params), ...patch };
    this.emitUpsert(machine);
    return { ...machine, revision: this.revision };
  }

  private create(displayName: unknown, memoryMb: unknown): MachineMutationResult {
    const id = `vm-new${this.nextId++}`;
    const machine: CloudMachine = {
      id,
      provider: "freestyle",
      status: "provisioning",
      displayName: typeof displayName === "string" ? displayName : null,
      slug: null,
      kind: "terminal",
      image: "cmux-base",
      imageVersion: "20260902e",
      createdAt: Date.now(),
      address: null,
      createdBy: { userId: "user-dev-1", displayName: "Dev User" },
      freeAccessExpiresAt: null,
    };
    if (typeof memoryMb === "number") this.memory.set(id, memoryMb);
    this.emitUpsert(machine);
    return { ...machine, revision: this.revision };
  }

  /** The server's ledger: a mutation key replays its recorded result and changes nothing. */
  private keyed(op: string, p: Params): unknown {
    const key = typeof p.idempotency_key === "string" ? p.idempotency_key : undefined;
    const args = { ...p };
    delete args.idempotency_key;
    const recorded = key ? this.ledger.get(key) : undefined;
    if (recorded) {
      if (recorded.op !== op || recorded.args !== JSON.stringify(args))
        throw pageError("cmux.cloud.idempotency_conflict", "this key was used for another request");
      return recorded.result;
    }
    const result = this.serve(op, args);
    if (key) this.ledger.set(key, { op, args: JSON.stringify(args), result });
    return result;
  }

  private serve(op: string, p: Params): unknown {
    if (this.unsupported.has(op)) {
      if (op === CloudOps.machineIdlePolicySet)
        throw pageError("cmux.cloud.unsupported", "The cmux Cloud API has no idle policy route yet");
      throw pageError("cmux.cloud.unknown_op", `${op} is not a Cloud op`);
    }
    const a = this.account;
    switch (op) {
      case CloudOps.authSignOut:
        this.signedIn = false;
        return { ok: true };
      case CloudOps.teamList:
        return a.teams;
      case CloudOps.teamSelect:
        a.team = String(p.team);
        return { ok: true };
      case CloudOps.machineList: {
        const result = { machines: this.machines.slice(), revision: this.revision };
        this.onList?.();
        return result;
      }
      case CloudOps.machineGet:
        return this.machine(p);
      case CloudOps.machineCreate:
        return this.create(p.displayName, p.memoryMb);
      case CloudOps.machineRename:
        return this.change(p, { displayName: (this.renameTransform ?? String)(String(p.displayName)) });
      case CloudOps.machineStart:
        return this.change(p, { status: "running" });
      case CloudOps.machinePause:
        return this.change(p, { status: "paused" });
      case CloudOps.machineResize: {
        // The answer is the stats with the plan maximums; the record does not change.
        const machine = this.machine(p);
        if (typeof p.memoryMb === "number") this.memory.set(machine.id, p.memoryMb);
        return { ...sampleStats(machine, this.memory.get(machine.id)), revision: this.revision };
      }
      case CloudOps.machineDelete:
        this.machine(p);
        this.emitRemoved(String(p.machine));
        if (this.notFoundOnDelete) {
          this.notFoundOnDelete = false;
          throw pageError("cmux.cloud.not_found", "The Cloud API does not know this machine.");
        }
        return { ok: true };
      case CloudOps.machineStats: {
        const machine = this.machine(p);
        return sampleStats(machine, this.memory.get(machine.id));
      }
      case CloudOps.snapshotList: {
        if (typeof p.machine !== "string") throw pageError("cmux.cloud.invalid_args", "machine is required");
        const snapshots = this.snapshots
          .filter((s) => s.machine === p.machine)
          .map(({ id, name, createdAt }) => ({ id, name, createdAt }));
        return { snapshots };
      }
      case CloudOps.snapshotCreate: {
        const snapshot = {
          id: `snap-new${this.nextId++}`,
          name: typeof p.name === "string" ? p.name : null,
          machine: String(p.machine),
          createdAt: new Date().toISOString(),
        };
        this.snapshots = [snapshot, ...this.snapshots];
        return { id: snapshot.id, name: snapshot.name, createdAt: snapshot.createdAt };
      }
      case CloudOps.snapshotRestore: {
        // A new machine from the snapshot; the source machine does not change.
        const snapshot = this.snapshots.find((s) => s.id === p.snapshot);
        if (!snapshot) throw pageError("cmux.cloud.not_found", `no snapshot ${String(p.snapshot)}`);
        return this.create(snapshot.name ?? null, undefined);
      }
      case CloudOps.snapshotFork: {
        const source = this.machine(p);
        return {
          ...this.create(`${source.displayName ?? source.slug ?? "machine"}-fork`, undefined),
          snapshotId: null,
        };
      }
      case CloudOps.snapshotDelete:
        this.snapshots = this.snapshots.filter((s) => s.id !== p.snapshot);
        return { ok: true };
      case CloudOps.domainList:
        return a.domains;
      case CloudOps.domainVerify:
        a.domains = a.domains.map((d) => (d.name === p.domain ? { ...d, status: "verified" as const } : d));
        return { ok: true };
      case CloudOps.publicationList:
        return a.publications.filter((pub) => pub.machine === p.machine);
      case CloudOps.publicationCreate: {
        const port = Number(p.port);
        const publication: CloudPublication = {
          id: `pub-${this.nextId++}`,
          machine: String(p.machine),
          hostname: `${port}-${String(p.machine)}.example.dev`,
          port,
          status: "pending",
        };
        a.publications = [...a.publications, publication];
        return publication;
      }
      case CloudOps.publicationVerify:
        a.publications = a.publications.map((pub) =>
          pub.id === p.publication ? { ...pub, status: "active" as const } : pub,
        );
        return { ok: true };
      case CloudOps.publicationDelete:
        a.publications = a.publications.filter((pub) => pub.id !== p.publication);
        return { ok: true };
      case CloudOps.networkList:
        return a.networks;
      case CloudOps.firewallList:
        return a.firewall.filter((rule) => rule.destination.vmId === p.machine || rule.source.vmId === p.machine);
      case CloudOps.firewallCreate: {
        const rule = p.rule as {
          action: string;
          port?: number;
          protocol?: string;
          cidr?: string;
          description?: string;
        };
        a.firewall = [
          ...a.firewall,
          {
            id: `fw-${this.nextId++}`,
            action: rule.action,
            source: rule.cidr ? { cidr: rule.cidr } : { public: true },
            destination: { vmId: String(p.machine), port: rule.port, protocol: rule.protocol },
            description: rule.description,
          },
        ];
        return { ok: true };
      }
      case CloudOps.firewallDelete:
        a.firewall = a.firewall.filter((rule) => rule.id !== p.rule);
        return { ok: true };
      case CloudOps.planGet:
        return a.plan;
      case CloudOps.usageGet:
        return a.usage;
      default:
        throw pageError("cmux.protocol.unknown_op", op);
    }
  }

  /** The host's native confirmation: on yes it runs the op as origin user. */
  private runAction(p: Params): unknown {
    const action = String(p.action);
    if (!NATIVE_ACTIONS.has(action)) throw pageError("cmux.app.unknown_action", action);
    if (this.unsupported.has(action)) throw pageError("cmux.cloud.unknown_op", `${action} is not a Cloud op`);
    if (action === CloudOps.machineConnect || action === CloudOps.billingOpen) return { confirmed: true };
    if (!this.confirm) return { confirmed: false };
    if (action === CloudOps.authSignIn) return ((this.signedIn = true), { confirmed: true });
    this.keyed(action, (p.args ?? {}) as Params);
    return { confirmed: true };
  }
}
