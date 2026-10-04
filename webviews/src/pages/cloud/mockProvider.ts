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
  type MutationResult,
} from "./ops";

export { sampleMachines } from "./mockData";

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
}

type Params = Record<string, unknown>;

export class MockCloudProvider implements PageClient {
  readonly calls: MockCall[] = [];
  machines: CloudMachine[] = sampleMachines();
  snapshots: CloudSnapshot[] = sampleSnapshots();
  account = sampleAccount();
  signedIn: boolean;
  confirm: boolean;
  /** Set to make every call reject as if the host went away. */
  offline = false;
  /** The next call of this op fails with a retryable owner error. */
  failNext?: string;
  /** Runs after the list result is taken and before it is answered (an event during the list). */
  onList?: () => void;
  /** The owner's normalization of a new name (the echo then differs from the intent). */
  renameTransform?: (name: string) => string;
  private revision = 10;
  private nextId = 1;
  private readonly created = new Map<string, string>();
  private readonly subs = new Map<number, { listener: (data: unknown, seq: number) => void; seq: number }>();
  private nextSub = 1;
  private readonly handlers = new Map<string, PageHandler>();
  private held: MachineEvent[] | null;

  constructor(options: MockOptions = {}) {
    this.signedIn = options.signedIn ?? true;
    this.confirm = options.confirm ?? true;
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
    return this.serve(op, p) as R;
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

  /** The owner changed a machine (or added one) and notifies. */
  emitUpsert(machine: CloudMachine): void {
    const index = this.machines.findIndex((m) => m.id === machine.id);
    if (index < 0) this.machines.push(machine);
    else this.machines[index] = machine;
    this.emit({ type: "upsert", revision: ++this.revision, machine });
  }

  emitRemoved(id: string): void {
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
    return this.signedIn
      ? { signed_in: true, email: "dev@example.com", team: this.account.team }
      : { signed_in: false };
  }

  private machine(params: Params): CloudMachine {
    const machine = this.machines.find((m) => m.id === params.machine);
    if (!machine) throw pageError("cmux.cloud.not_found", `no machine ${String(params.machine)}`);
    return machine;
  }

  /** Changes a machine as the owner would: emits the echo, answers with the revision. */
  private change(params: Params, patch: Partial<CloudMachine>): MutationResult {
    const machine = { ...this.machine(params), ...patch };
    this.emitUpsert(machine);
    return { machine, revision: this.revision };
  }

  private create(params: Params, snapshot?: string): CloudMachine {
    const key = String(params.idempotency_key ?? "");
    const existing = key ? this.created.get(key) : undefined;
    if (existing) return this.machines.find((m) => m.id === existing) ?? this.machine({ machine: existing });
    const plan = this.account.plan.sizes.find((size) => size.name === (params.size ?? "small-1"));
    const id = `vm-new${this.nextId++}`;
    const machine: CloudMachine = {
      id,
      provider: "freestyle",
      status: "provisioning",
      display_name: (params.name as string) || undefined,
      created_at_ms: Date.now(),
      size: plan && { name: plan.name, cpu: plan.cpu, memory_mb: plan.memory_mb, storage_mb: plan.storage_mb },
      image: snapshot ? `snapshot ${snapshot}` : "cmux-base",
    };
    if (key) this.created.set(key, id);
    this.emitUpsert(machine);
    return machine;
  }

  private serve(op: string, p: Params): unknown {
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
        return this.create(p, p.snapshot_id as string | undefined);
      case CloudOps.machineRename:
        return this.change(p, { display_name: (this.renameTransform ?? String)(String(p.name)) });
      case CloudOps.machineStart:
        return this.change(p, { status: "running" });
      case CloudOps.machinePause:
        return this.change(p, { status: "paused" });
      case CloudOps.machineResize: {
        const size = a.plan.sizes.find((s) => s.name === p.size);
        return this.change(p, { size: size && { ...size } });
      }
      case CloudOps.machineIdlePolicySet:
        return this.change(p, { idle_timeout_seconds: (p.idle_timeout_seconds as number | null) ?? undefined });
      case CloudOps.machineDelete:
        this.machine(p);
        this.emitRemoved(String(p.machine));
        return { ok: true };
      case CloudOps.machineStats:
        return sampleStats(this.machine(p));
      case CloudOps.snapshotList:
        return this.snapshots.filter((s) => !p.machine || s.machine === p.machine);
      case CloudOps.snapshotCreate: {
        const snapshot = {
          id: `snap-new${this.nextId++}`,
          name: p.name as string | undefined,
          machine: String(p.machine),
          created_at_ms: Date.now(),
        };
        this.snapshots = [snapshot, ...this.snapshots];
        return snapshot;
      }
      case CloudOps.snapshotRestore:
        return this.change(p, { status: "provisioning" });
      case CloudOps.snapshotFork:
        return this.create({ ...p, name: `${this.machine(p).display_name ?? "machine"}-fork` }, String(p.snapshot));
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
        return a.firewall.filter((rule) => rule.destination.vm_id === p.machine || rule.source.vm_id === p.machine);
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
            destination: { vm_id: String(p.machine), port: rule.port, protocol: rule.protocol },
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
    if (action === CloudOps.machineConnect || action === CloudOps.billingOpen) return { confirmed: true };
    if (!this.confirm) return { confirmed: false };
    if (action === CloudOps.authSignIn) return ((this.signedIn = true), { confirmed: true });
    this.serve(action, (p.args ?? {}) as Params);
    return { confirmed: true };
  }
}
