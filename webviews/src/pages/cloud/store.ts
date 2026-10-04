// The Cloud page's state owner on the page side. The machine list is a mirror written only by the
// owner (`cmux.cloud.machine.list` once, then `cmux.cloud.machine.watch` events; no polling, no
// timers) plus one ordered log of pending intents (OWNERSHIP-PRINCIPLES "Clients are projections").
// Destructive, money and view-changing ops go to the host as native actions (ops.ts NATIVE_ACTIONS).
// React reads it through `useSyncExternalStore`; tests drive it directly.
import { isPageError, type PageClient } from "../shared/pageClient";
import { DetailReader, type MachineDetail } from "./detail";
import {
  applyEvent,
  atMachineLimit,
  defaultSize,
  settled,
  visibleRows,
  type IntentKind,
  type MachineLayout,
  type MachineRow,
  type PendingIntent,
} from "./model";
import {
  ACTION_RUN,
  CloudOps,
  type ActionRunResult,
  type AuthStatus,
  type CloudMachine,
  type CloudPlan,
  type CloudSnapshot,
  type CloudTeam,
  type CloudUsage,
  type CreateMachineParams,
  type MachineEvent,
  type MachineListResult,
} from "./ops";

export type Connection = "connecting" | "connected" | "disconnected";

export interface CreateDraft {
  /** One key per sheet: a retry after a failure sends the same key, so the owner creates once. */
  key: string;
  name: string;
  size?: string;
  snapshot_id?: string;
  snapshots?: CloudSnapshot[];
  submitting: boolean;
  error?: string;
}

export interface CloudState {
  connection: Connection;
  auth?: AuthStatus;
  loading: boolean;
  machines: CloudMachine[];
  revision: number;
  pending: PendingIntent[];
  rows: MachineRow[];
  teams: CloudTeam[];
  plan?: CloudPlan;
  usage?: CloudUsage;
  selection?: string;
  detail?: MachineDetail;
  create?: CreateDraft;
  error?: string;
  layout: MachineLayout;
}

export interface CloudStoreOptions {
  newKey?: () => string;
  layout?: MachineLayout;
}

export class CloudStore {
  private state: CloudState;
  private readonly listeners = new Set<() => void>();
  private started = false;
  private unwatch?: () => void;
  /** Watch events that arrive while the first list is in flight. */
  private buffered: MachineEvent[] | null = null;
  readonly detail: DetailReader;

  constructor(
    private readonly client: PageClient | null,
    private readonly options: CloudStoreOptions = {},
  ) {
    this.state = {
      connection: client ? "connecting" : "disconnected",
      loading: client !== null,
      machines: [],
      revision: 0,
      pending: [],
      rows: [],
      teams: [],
      layout: options.layout ?? "rows",
    };
    this.detail = new DetailReader(client, {
      get: () => this.state.detail,
      set: (detail) => this.set({ detail }),
      fail: (error) => this.set(failure(error)),
      canChange: () => this.canChange(),
      key: () => this.key(),
    });
  }

  getSnapshot = (): CloudState => this.state;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    if (this.listeners.size === 1) void this.start();
    return () => {
      this.listeners.delete(listener);
      if (this.listeners.size === 0) this.stop();
    };
  };

  /** Reads auth; when signed in, watches and lists machines. Idempotent. */
  async start(): Promise<void> {
    if (!this.client || this.started) return;
    this.started = true;
    let auth: AuthStatus;
    try {
      auth = await this.client.call<AuthStatus>(CloudOps.authStatus, {});
    } catch (error) {
      this.started = false;
      this.set({ loading: false, ...failure(error) });
      return;
    }
    this.set({ auth, connection: "connected" });
    if (auth.signed_in) await this.loadSignedIn();
    else this.set({ loading: false });
  }

  stop(): void {
    this.started = false;
    this.unwatch?.();
    this.unwatch = undefined;
    this.buffered = null;
  }

  async signIn(): Promise<void> {
    if (!this.client || this.state.connection === "disconnected") return;
    try {
      await this.client.call(CloudOps.authSignIn, {});
      const auth = await this.client.call<AuthStatus>(CloudOps.authStatus, {});
      this.set({ auth, error: undefined });
      if (auth.signed_in) await this.loadSignedIn();
    } catch (error) {
      this.set(failure(error));
    }
  }

  async signOut(): Promise<void> {
    if (!this.canChange()) return;
    try {
      await this.client!.call(CloudOps.authSignOut, {});
    } catch (error) {
      this.set(failure(error));
      return;
    }
    this.unwatch?.();
    this.unwatch = undefined;
    this.set({ ...signedOutState(), auth: { signed_in: false } });
  }

  async selectTeam(team: string): Promise<void> {
    if (!this.canChange() || team === this.state.auth?.team) return;
    try {
      await this.client!.call(CloudOps.teamSelect, { team });
      const auth = await this.client!.call<AuthStatus>(CloudOps.authStatus, {});
      this.unwatch?.();
      this.unwatch = undefined;
      this.set({ ...signedOutState(), auth, loading: true });
      if (auth.signed_in) await this.loadSignedIn();
    } catch (error) {
      this.set(failure(error));
    }
  }

  async select(machine: string | undefined): Promise<void> {
    if (machine === this.state.selection && this.state.detail?.machine === machine) return;
    this.set({ selection: machine });
    await this.detail.load(machine);
  }

  dismissError(): void {
    if (this.state.error) this.set({ error: undefined });
  }

  // Create sheet.

  openCreate(): void {
    if (!this.canChange() || this.state.create) return;
    this.set({ create: { key: this.key(), name: "", size: defaultSize(this.state.plan), submitting: false } });
    void this.client!.call<CloudSnapshot[]>(CloudOps.snapshotList, {}).then(
      (snapshots) => this.state.create && this.set({ create: { ...this.state.create, snapshots } }),
      () => undefined,
    );
  }

  closeCreate(): void {
    if (this.state.create && !this.state.create.submitting) this.set({ create: undefined });
  }

  updateDraft(patch: Partial<Pick<CreateDraft, "name" | "size" | "snapshot_id">>): void {
    const draft = this.state.create;
    if (draft && !draft.submitting) this.set({ create: { ...draft, ...patch, error: undefined } });
  }

  async submitCreate(): Promise<void> {
    const draft = this.state.create;
    if (!draft || draft.submitting || !draft.size || !this.canChange()) return;
    if (atMachineLimit(this.state.plan, this.state.machines)) return;
    this.set({ create: { ...draft, submitting: true, error: undefined } });
    const name = draft.name.trim();
    this.pushIntent({ key: draft.key, kind: "create", name });
    const params: CreateMachineParams = { name, size: draft.size, idempotency_key: draft.key };
    if (draft.snapshot_id) params.snapshot_id = draft.snapshot_id;
    try {
      const machine = await this.client!.call<CloudMachine>(CloudOps.machineCreate, params);
      this.updateIntent(draft.key, { result_id: machine.id });
      this.set({ create: undefined });
    } catch (error) {
      this.dropIntent(draft.key);
      this.set({ create: { ...draft, submitting: false, error: message(error) }, ...failure(error, false) });
    }
  }

  // Machine intents.

  pause(machine: string): Promise<void> {
    return this.machineIntent("pause", machine, CloudOps.machinePause, {});
  }

  resume(machine: string): Promise<void> {
    return this.machineIntent("start", machine, CloudOps.machineStart, {});
  }

  rename(machine: string, name: string): Promise<void> {
    const trimmed = name.trim();
    if (!trimmed) return Promise.resolve();
    return this.machineIntent("rename", machine, CloudOps.machineRename, { name: trimmed }, { name: trimmed });
  }

  resize(machine: string, size: string): Promise<void> {
    return this.machineIntent("resize", machine, CloudOps.machineResize, { size }, { size });
  }

  setIdlePolicy(machine: string, seconds: number | null): Promise<void> {
    return this.machineIntent(
      "idle",
      machine,
      CloudOps.machineIdlePolicySet,
      { idle_timeout_seconds: seconds },
      { idle: seconds },
    );
  }

  /** Asks the host for the native delete confirmation; the host runs the delete as origin user. */
  async requestDelete(machine: string): Promise<void> {
    if (!this.canChange()) return;
    const key = this.key();
    this.pushIntent({ key, kind: "delete", machine });
    try {
      const result = await this.client!.call<ActionRunResult | null>(ACTION_RUN, {
        action: CloudOps.machineDelete,
        args: { machine, idempotency_key: key },
      });
      if (result?.confirmed === false) this.dropIntent(key);
    } catch (error) {
      this.dropIntent(key);
      this.set(failure(error));
    }
  }

  /** Opens the machine in the sidebar and a terminal through the host's connect action. */
  async connect(machine: string): Promise<void> {
    await this.native(CloudOps.machineConnect, { machine });
  }

  /** Opens checkout or the billing portal in the browser through the host (money action). */
  async openBilling(): Promise<void> {
    await this.native(CloudOps.billingOpen, {});
  }

  deleteSnapshot(machine: string, snapshot: string): Promise<void> {
    return this.detail.native(CloudOps.snapshotDelete, { machine, snapshot }, "snapshots");
  }

  deleteFirewallRule(machine: string, rule: string): Promise<void> {
    return this.detail.native(CloudOps.firewallDelete, { machine, rule }, "firewall");
  }

  // Internals.

  private async loadSignedIn(): Promise<void> {
    const client = this.client!;
    this.buffered = [];
    try {
      this.unwatch?.();
      this.unwatch = await client.subscribe<MachineEvent>(CloudOps.machineWatch, (event) => this.onEvent(event));
      const result = await client.call<MachineListResult>(CloudOps.machineList, {});
      let { machines, revision } = result;
      for (const event of this.buffered ?? []) {
        if (event.revision <= revision) continue;
        machines = applyEvent(machines, event);
        revision = event.revision;
      }
      this.buffered = null;
      this.setMirror(machines, revision, { loading: false, connection: "connected", error: undefined });
    } catch (error) {
      this.buffered = null;
      this.set({ loading: false, ...failure(error) });
      return;
    }
    const [teams, plan, usage] = await Promise.allSettled([
      client.call<CloudTeam[]>(CloudOps.teamList, {}),
      client.call<CloudPlan>(CloudOps.planGet, {}),
      client.call<CloudUsage>(CloudOps.usageGet, {}),
    ]);
    this.set({
      teams: teams.status === "fulfilled" ? teams.value : [],
      plan: plan.status === "fulfilled" ? plan.value : undefined,
      usage: usage.status === "fulfilled" ? usage.value : undefined,
    });
  }

  private onEvent(event: MachineEvent): void {
    if (this.buffered) {
      this.buffered.push(event);
      return;
    }
    if (event.revision <= this.state.revision) return;
    this.setMirror(applyEvent(this.state.machines, event), event.revision);
  }

  private setMirror(machines: CloudMachine[], revision: number, patch: Partial<CloudState> = {}): void {
    const pending = this.state.pending.filter((intent) => !settled(intent, machines));
    const gone = this.state.selection && !machines.some((machine) => machine.id === this.state.selection);
    this.set({
      machines,
      revision,
      pending,
      rows: visibleRows(machines, pending),
      ...(gone ? { selection: undefined, detail: undefined } : {}),
      ...patch,
    });
  }

  private async machineIntent(
    kind: IntentKind,
    machine: string,
    op: string,
    params: Record<string, unknown>,
    fields: Partial<PendingIntent> = {},
  ): Promise<void> {
    if (!this.canChange()) return;
    const key = this.key();
    this.pushIntent({ key, kind, machine, ...fields });
    try {
      await this.client!.call(op, { machine, ...params, idempotency_key: key });
    } catch (error) {
      this.dropIntent(key);
      this.set(failure(error));
    }
  }

  private async native(action: string, args: Record<string, unknown>): Promise<void> {
    if (!this.canChange()) return;
    try {
      await this.client!.call<ActionRunResult | null>(ACTION_RUN, { action, args });
    } catch (error) {
      this.set(failure(error));
    }
  }

  private pushIntent(intent: PendingIntent): void {
    this.setPending([...this.state.pending, intent]);
  }

  private updateIntent(key: string, patch: Partial<PendingIntent>): void {
    const pending = this.state.pending.map((intent) => (intent.key === key ? { ...intent, ...patch } : intent));
    this.setPending(pending.filter((intent) => !settled(intent, this.state.machines)));
  }

  private dropIntent(key: string): void {
    this.setPending(this.state.pending.filter((intent) => intent.key !== key));
  }

  private setPending(pending: PendingIntent[]): void {
    this.set({ pending, rows: visibleRows(this.state.machines, pending) });
  }

  private canChange(): boolean {
    return !!this.client && this.state.connection !== "disconnected" && !!this.state.auth?.signed_in;
  }

  private key(): string {
    return this.options.newKey?.() ?? crypto.randomUUID();
  }

  private set(patch: Partial<CloudState>): void {
    this.state = { ...this.state, ...patch };
    for (const listener of this.listeners) listener();
  }
}

function signedOutState(): Partial<CloudState> {
  return {
    machines: [],
    revision: 0,
    pending: [],
    rows: [],
    teams: [],
    plan: undefined,
    usage: undefined,
    selection: undefined,
    detail: undefined,
    create: undefined,
    error: undefined,
    loading: false,
  };
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/** A transport failure means the owner is unreachable: the page shows disconnected. */
function failure(error: unknown, withMessage = true): Partial<CloudState> {
  if (isPageError(error) && error.code === "cmux.protocol.transport") {
    return { connection: "disconnected", error: message(error) };
  }
  return withMessage ? { error: message(error) } : {};
}
