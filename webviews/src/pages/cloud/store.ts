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
  normalizeMachine,
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
  /**
   * Bumped by stop, sign-out, team switch and retry. Every async load captures it and drops its
   * result (and closes its watch) when it changed, so an old account or team never writes state.
   */
  private session = 0;
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
    const session = ++this.session;
    let auth: AuthStatus;
    try {
      auth = await this.client.call<AuthStatus>(CloudOps.authStatus, {});
    } catch (error) {
      if (session !== this.session) return;
      this.started = false;
      this.set({ loading: false, ...failure(error) });
      return;
    }
    if (session !== this.session) return;
    this.set({ auth, connection: "connected" });
    if (auth.signed_in) await this.loadSignedIn(session);
    else this.set({ loading: false });
  }

  stop(): void {
    this.started = false;
    this.endSession();
  }

  get canRetry(): boolean {
    return this.client !== null;
  }

  /** After a disconnect: drops the old session and starts again (the localized Retry button). */
  async retry(): Promise<void> {
    this.stop();
    this.set({ connection: this.client ? "connecting" : "disconnected", loading: true, error: undefined });
    await this.start();
  }

  /** Sign-in is a native browser flow the host runs as origin user (cloud-app.md section 2). */
  async signIn(): Promise<void> {
    if (!this.client || this.state.connection === "disconnected") return;
    const session = this.session;
    try {
      const result = await this.client.call<ActionRunResult | null>(ACTION_RUN, {
        action: CloudOps.authSignIn,
        args: {},
      });
      if (result?.confirmed === false || session !== this.session) return;
      const auth = await this.client.call<AuthStatus>(CloudOps.authStatus, {});
      if (session !== this.session) return;
      this.set({ auth, error: undefined });
      if (auth.signed_in) {
        const next = this.restartSession();
        await this.loadSignedIn(next);
      }
    } catch (error) {
      this.set(failure(error));
    }
  }

  async signOut(): Promise<void> {
    if (!this.canChange()) return;
    try {
      const result = await this.client!.call<ActionRunResult | null>(ACTION_RUN, {
        action: CloudOps.authSignOut,
        args: {},
      });
      if (result?.confirmed === false) return;
    } catch (error) {
      this.set(failure(error));
      return;
    }
    this.restartSession();
    void this.detail.load(undefined);
    this.set({ ...signedOutState(), auth: { signed_in: false } });
  }

  async selectTeam(team: string): Promise<void> {
    if (!this.canChange() || team === this.state.auth?.team) return;
    const session = this.restartSession();
    void this.detail.load(undefined);
    this.set({ ...signedOutState(), loading: true });
    try {
      await this.client!.call(CloudOps.teamSelect, { team, idempotency_key: this.key() });
      const auth = await this.client!.call<AuthStatus>(CloudOps.authStatus, {});
      if (session !== this.session) return;
      this.set({ auth });
      if (auth.signed_in) await this.loadSignedIn(session);
      else this.set({ loading: false });
    } catch (error) {
      if (session === this.session) this.set({ loading: false, ...failure(error) });
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
    if (!draft || draft.submitting || !this.canChange()) return;
    if (atMachineLimit(this.state.plan, this.state.machines)) return;
    this.set({ create: { ...draft, submitting: true, error: undefined } });
    const name = draft.name.trim();
    this.pushIntent({ key: draft.key, kind: "create", name });
    // No size (the plan did not load): the owner picks its default size.
    const params: CreateMachineParams = { name, idempotency_key: draft.key };
    if (draft.size) params.size = draft.size;
    if (draft.snapshot_id) params.snapshot_id = draft.snapshot_id;
    const session = this.session;
    try {
      const machine = await this.client!.call<CloudMachine>(CloudOps.machineCreate, params);
      if (session !== this.session) return;
      this.updateIntent(draft.key, { result_id: machine.id, replied: true });
      this.set({ create: undefined });
    } catch (error) {
      if (session !== this.session) return;
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
      else this.replied(key, result);
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

  private endSession(): void {
    this.session += 1;
    this.unwatch?.();
    this.unwatch = undefined;
  }

  private restartSession(): number {
    this.endSession();
    return this.session;
  }

  /** Watches, then lists once; events that arrive during the list are merged by revision. */
  private async loadSignedIn(session: number): Promise<void> {
    const client = this.client!;
    let buffer: MachineEvent[] | null = [];
    try {
      const unwatch = await client.subscribe<MachineEvent>(CloudOps.machineWatch, (event) => {
        if (session !== this.session) return;
        if (buffer) buffer.push(event);
        else this.onEvent(event);
      });
      if (session !== this.session) {
        unwatch();
        return;
      }
      this.unwatch?.();
      this.unwatch = unwatch;
      const result = await client.call<MachineListResult>(CloudOps.machineList, {});
      if (session !== this.session) return;
      let machines = result.machines.map(normalizeMachine);
      let revision = result.revision;
      for (const event of buffer) {
        if (event.revision <= revision) continue;
        machines = applyEvent(machines, event);
        revision = event.revision;
      }
      buffer = null;
      this.setMirror(machines, revision, { loading: false, connection: "connected", error: undefined });
    } catch (error) {
      buffer = null;
      if (session === this.session) this.set({ loading: false, ...failure(error) });
      return;
    }
    const [teams, plan, usage] = await Promise.allSettled([
      client.call<CloudTeam[]>(CloudOps.teamList, {}),
      client.call<CloudPlan>(CloudOps.planGet, {}),
      client.call<CloudUsage>(CloudOps.usageGet, {}),
    ]);
    if (session !== this.session) return;
    this.set({
      teams: teams.status === "fulfilled" ? teams.value : [],
      plan: plan.status === "fulfilled" ? plan.value : undefined,
      usage: usage.status === "fulfilled" ? usage.value : undefined,
    });
  }

  private onEvent(event: MachineEvent): void {
    // An event proves the owner is reachable again.
    const patch: Partial<CloudState> = this.state.connection === "disconnected" ? { connection: "connected" } : {};
    if (event.revision <= this.state.revision) {
      if (patch.connection) this.set(patch);
      return;
    }
    const target = event.type === "removed" ? event.id : event.machine.id;
    // The echo of an answered intent: the owner's next event for that machine settles it,
    // whatever value the owner chose (normalized name, failed status, other size name).
    const pending = this.state.pending.filter((intent) => !(intent.replied && intent.machine === target));
    if (pending.length !== this.state.pending.length) this.state = { ...this.state, pending };
    this.setMirror(applyEvent(this.state.machines, event), event.revision, patch);
  }

  /** The owner answered an intent. A result revision already in the mirror settles it now. */
  private replied(key: string, result: unknown): void {
    const revision = (result as { revision?: unknown } | null)?.revision;
    if (typeof revision === "number" && revision <= this.state.revision) this.dropIntent(key);
    else this.updateIntent(key, { replied: true });
  }

  private setMirror(machines: CloudMachine[], revision: number, patch: Partial<CloudState> = {}): void {
    const pending = this.state.pending.filter((intent) => !settled(intent, machines));
    const gone = this.state.selection && !machines.some((machine) => machine.id === this.state.selection);
    if (gone) void this.detail.load(undefined);
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
      this.replied(key, await this.client!.call(op, { machine, ...params, idempotency_key: key }));
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
