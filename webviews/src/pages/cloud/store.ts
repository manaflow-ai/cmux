// The Cloud page's state owner on the page side. The machine list is a mirror written only by the
// owner (`cmux.cloud.machine.list` once, then `cmux.cloud.machine.watch` events; no polling, no
// timers) plus one ordered log of pending intents (OWNERSHIP-PRINCIPLES "Clients are projections").
// Destructive, money and view-changing ops go to the host as native actions (ops.ts NATIVE_ACTIONS).
// React reads it through `useSyncExternalStore`; tests drive it directly.
import { isPageError, type PageClient } from "../shared/pageClient";
import { DetailReader, type MachineDetail } from "./detail";
import { FilesReader } from "./files";
import { TransferWatch, type FileTransfer } from "./transfers";
import {
  applyEvent,
  atMachineLimit,
  defaultMemory,
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
  hasNoDetails,
  isGone,
  isNotServed,
  isRouteMissing,
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
  type MachineMutationResult,
  type MachineStats,
  type ResizeResult,
  type SnapshotListResult,
} from "./ops";

export type Connection = "connecting" | "connected" | "disconnected";

export interface CreateDraft {
  /** One key per sheet: a retry after a failure sends the same key, so the owner creates once. */
  key: string;
  name: string;
  memoryMb?: number;
  /** Create from this snapshot (`cmux.cloud.snapshot.restore`) instead of the base image. */
  snapshot_id?: string;
  /** The selected machine's snapshots (the Cloud API has no account-wide snapshot list). */
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
  /** Ops (and native actions) the owner answered as not served yet: the page shows "Not available yet". */
  unavailable: string[];
  /** This session's file transfers, running and ended (`cloud.file.transfer.changed`). */
  transfers: FileTransfer[];
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
  readonly files: FilesReader;
  readonly transfers: TransferWatch;

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
      unavailable: [],
      transfers: [],
    };
    const host = {
      get: () => this.state.detail,
      set: (detail: MachineDetail | undefined) => this.set({ detail }),
      fail: (error: unknown) => this.set(failure(error)),
      unsupported: (op: string) => this.markUnavailable(op),
      canChange: () => this.canChange(),
      key: () => this.key(),
      epoch: () => this.detail.epoch,
    };
    this.detail = new DetailReader(client, host);
    this.transfers = new TransferWatch(client, {
      get: () => this.state.transfers,
      set: (transfers) => this.set({ transfers }),
      ended: (event) => this.files.transferEnded(event),
      unsupported: (op) => this.markUnavailable(op),
    });
    this.files = new FilesReader(client, host, this.transfers);
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
    if (auth.signedIn) await this.loadSignedIn(session);
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
      if (auth.signedIn) {
        const next = this.restartSession();
        await this.loadSignedIn(next);
      }
    } catch (error) {
      this.fail(CloudOps.authSignIn, error);
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
      this.fail(CloudOps.authSignOut, error);
      return;
    }
    this.restartSession();
    void this.detail.load(undefined);
    this.set({ ...signedOutState(), auth: { signedIn: false } });
  }

  async selectTeam(team: string): Promise<void> {
    if (!this.canChange() || team === this.state.auth?.team) return;
    const session = this.restartSession();
    void this.detail.load(undefined);
    this.set({ ...signedOutState(), loading: true });
    try {
      await this.client!.call(CloudOps.teamSelect, { team, idempotency_key: this.key() });
    } catch (error) {
      if (session !== this.session) return;
      if (!isNotServed(CloudOps.teamSelect, error)) return this.set({ loading: false, ...failure(error) });
      // Nothing changed at the owner: show the same team again.
      this.markUnavailable(CloudOps.teamSelect);
    }
    try {
      const auth = await this.client!.call<AuthStatus>(CloudOps.authStatus, {});
      if (session !== this.session) return;
      this.set({ auth });
      if (auth.signedIn) await this.loadSignedIn(session);
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
    const key = this.key();
    this.set({ create: { key, name: "", memoryMb: defaultMemory(this.state.plan), submitting: false } });
    const machine = this.state.selection;
    if (!machine) return;
    void this.client!.call<SnapshotListResult>(CloudOps.snapshotList, { machine }).then(
      ({ snapshots }) => this.state.create?.key === key && this.set({ create: { ...this.state.create, snapshots } }),
      () => undefined,
    );
  }

  closeCreate(): void {
    if (this.state.create && !this.state.create.submitting) this.set({ create: undefined });
  }

  updateDraft(patch: Partial<Pick<CreateDraft, "name" | "memoryMb" | "snapshot_id">>): void {
    const draft = this.state.create;
    if (draft && !draft.submitting) this.set({ create: { ...draft, ...patch, error: undefined } });
  }

  async submitCreate(): Promise<void> {
    const draft = this.state.create;
    if (!draft || draft.submitting || !this.canChange()) return;
    if (atMachineLimit(this.state.plan, this.state.machines)) return;
    this.set({ create: { ...draft, submitting: true, error: undefined } });
    const snapshot = draft.snapshot_id ? draft.snapshots?.find((s) => s.id === draft.snapshot_id) : undefined;
    const name = draft.snapshot_id ? (snapshot?.name ?? "") : draft.name.trim();
    this.pushIntent({ key: draft.key, kind: "create", name });
    const session = this.session;
    try {
      let result: MachineMutationResult;
      if (draft.snapshot_id) {
        // A machine from a snapshot is a restore: the owner takes only the snapshot.
        result = await this.client!.call<MachineMutationResult>(CloudOps.snapshotRestore, {
          snapshot: draft.snapshot_id,
          idempotency_key: draft.key,
        });
      } else {
        // No memory (the plan did not load) or no name: the owner picks its default.
        const params: CreateMachineParams = { idempotency_key: draft.key };
        if (name) params.displayName = name;
        if (draft.memoryMb) params.memoryMb = draft.memoryMb;
        result = await this.client!.call<MachineMutationResult>(CloudOps.machineCreate, params);
      }
      // Recorded even after a session restart (stop, retry): the intent and the sheet must not
      // stay pending. A cleared log (sign-out, team switch) makes these no-ops.
      this.updateIntent(draft.key, { result_id: result.id, replied: true, revision: revisionOf(result) });
      if (this.state.create?.key === draft.key) this.set({ create: undefined });
    } catch (error) {
      this.dropIntent(draft.key);
      if (this.state.create?.key === draft.key)
        this.set({ create: { ...draft, submitting: false, error: message(error) } });
      if (session === this.session) this.set(failure(error, false));
    }
  }

  // Machine intents.

  async pause(machine: string): Promise<void> {
    await this.machineIntent("pause", machine, CloudOps.machinePause, {});
  }

  async resume(machine: string): Promise<void> {
    await this.machineIntent("start", machine, CloudOps.machineStart, {});
  }

  async rename(machine: string, name: string): Promise<void> {
    const trimmed = name.trim();
    if (!trimmed) return;
    await this.machineIntent("rename", machine, CloudOps.machineRename, { displayName: trimmed }, { name: trimmed });
  }

  /** Resizes memory to one of the plan's `memoryOptionsMb`. The answer is the new stats. */
  async resize(machine: string, memoryMb: number): Promise<void> {
    const stats = await this.machineIntent("resize", machine, CloudOps.machineResize, { memoryMb }, { memoryMb });
    const detail = this.state.detail;
    if (stats && detail?.machine === machine)
      this.set({ detail: { ...detail, stats: statsOf(stats as ResizeResult) } });
  }

  /** `null` = never pause (sent as 0 seconds). */
  async setIdlePolicy(machine: string, seconds: number | null): Promise<void> {
    await this.machineIntent(
      "idle",
      machine,
      CloudOps.machineIdlePolicySet,
      { idleTimeoutSeconds: seconds ?? 0 },
      { idle: seconds },
    );
  }

  /** A new machine from a snapshot (`snapshot.restore`); it shows as a pending create until its echo. */
  restoreSnapshot(snapshot: CloudSnapshot): Promise<void> {
    return this.newMachine(CloudOps.snapshotRestore, { snapshot: snapshot.id }, snapshot.name ?? "");
  }

  /** A copy of the machine (`snapshot.fork`); it shows as a pending create until its echo. */
  forkMachine(machine: string): Promise<void> {
    const source = this.state.machines.find((m) => m.id === machine);
    return this.newMachine(CloudOps.snapshotFork, { machine }, source?.displayName ?? "");
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
      // The machine's own 404 (`vm_not_found`): the owner dropped it and sent `removed`. Nothing
      // failed. A bare 404 is a missing route: "Not available yet". A `not_found` without details
      // (a host that does not forward them) keeps the old answer: gone, no error.
      if (isGone(CloudOps.machineDelete, error)) return;
      if (isPageError(error) && error.code === "cmux.cloud.not_found" && hasNoDetails(error)) return;
      if (isRouteMissing(CloudOps.machineDelete, error)) this.markUnavailable(CloudOps.machineDelete);
      else this.fail(CloudOps.machineDelete, error);
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

  /** `cloud.firewall.delete` takes the rule id only. */
  deleteFirewallRule(rule: string): Promise<void> {
    return this.detail.native(CloudOps.firewallDelete, { rule }, "firewall");
  }

  // Internals.

  private endSession(): void {
    this.session += 1;
    this.unwatch?.();
    this.unwatch = undefined;
    // Without the event stream a running row would never end: the session's transfers go with it.
    this.transfers.stop();
    if (this.state.transfers.length) this.set({ transfers: [] });
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
        // The list holds its own revision; events of that revision are re-applied (idempotent).
        if (event.revision < revision) continue;
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
    for (const [op, result] of [
      [CloudOps.teamList, teams],
      [CloudOps.planGet, plan],
      [CloudOps.usageGet, usage],
    ] as const)
      if (result.status === "rejected" && isNotServed(op, result.reason)) this.markUnavailable(op);
    this.set({
      teams: teams.status === "fulfilled" ? teams.value : [],
      plan: plan.status === "fulfilled" ? plan.value : undefined,
      usage: usage.status === "fulfilled" ? usage.value : undefined,
    });
  }

  private onEvent(event: MachineEvent): void {
    // An event proves the owner is reachable again.
    const patch: Partial<CloudState> = this.state.connection === "disconnected" ? { connection: "connected" } : {};
    // Events of one projection change share its revision, so only an older revision is stale.
    // An event of the mirror's own revision is applied again; it describes the same state.
    if (event.revision < this.state.revision) {
      if (patch.connection) this.set(patch);
      return;
    }
    const target = event.type === "removed" ? event.id : event.machine.id;
    // An answer without a revision (a native action): the owner's next event for that machine is
    // its echo, whatever value the owner chose. Answers with a revision settle in setMirror.
    const pending = this.state.pending.filter(
      (intent) => !(intent.replied && intent.revision === undefined && intent.machine === target),
    );
    if (pending.length !== this.state.pending.length) this.state = { ...this.state, pending };
    this.setMirror(applyEvent(this.state.machines, event), event.revision, patch);
  }

  /**
   * The owner answered an intent. Its result revision settles it once the mirror reaches it (now,
   * when the watch event came first).
   */
  private replied(key: string, result: unknown): void {
    this.updateIntent(key, { replied: true, revision: revisionOf(result) });
  }

  private setMirror(machines: CloudMachine[], revision: number, patch: Partial<CloudState> = {}): void {
    const pending = this.state.pending.filter((intent) => !settled(intent, machines, revision));
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

  /** Sends one machine intent; answers the owner's result, or undefined after a reject. */
  private async machineIntent(
    kind: IntentKind,
    machine: string,
    op: string,
    params: Record<string, unknown>,
    fields: Partial<PendingIntent> = {},
  ): Promise<unknown> {
    if (!this.canChange()) return undefined;
    const key = this.key();
    this.pushIntent({ key, kind, machine, ...fields });
    const session = this.session;
    try {
      // Recorded even after a session restart, so the intent cannot stay pending.
      const result = await this.client!.call(op, { machine, ...params, idempotency_key: key });
      this.replied(key, result);
      return result;
    } catch (error) {
      this.dropIntent(key);
      if (session === this.session) this.fail(op, error);
      return undefined;
    }
  }

  /** Restore and fork: a new machine, shown as a pending create row until the mirror has it. */
  private async newMachine(op: string, params: Record<string, unknown>, name: string): Promise<void> {
    if (!this.canChange()) return;
    const key = this.key();
    this.pushIntent({ key, kind: "create", name });
    const session = this.session;
    try {
      // Recorded even after a session restart, so the pending create row cannot stay.
      const result = await this.client!.call<MachineMutationResult>(op, { ...params, idempotency_key: key });
      this.updateIntent(key, { result_id: result.id, replied: true, revision: revisionOf(result) });
    } catch (error) {
      this.dropIntent(key);
      if (session === this.session) this.fail(op, error);
    }
  }

  private async native(action: string, args: Record<string, unknown>): Promise<void> {
    if (!this.canChange()) return;
    try {
      await this.client!.call<ActionRunResult | null>(ACTION_RUN, { action, args });
    } catch (error) {
      this.fail(action, error);
    }
  }

  /** A reject: "not available yet" for an op the owner does not serve, else the error banner. */
  private fail(op: string, error: unknown): void {
    if (isNotServed(op, error)) this.markUnavailable(op);
    else this.set(failure(error));
  }

  private markUnavailable(op: string): void {
    if (!this.state.unavailable.includes(op)) this.set({ unavailable: [...this.state.unavailable, op] });
  }

  private pushIntent(intent: PendingIntent): void {
    this.setPending([...this.state.pending, intent]);
  }

  private updateIntent(key: string, patch: Partial<PendingIntent>): void {
    const pending = this.state.pending.map((intent) => (intent.key === key ? { ...intent, ...patch } : intent));
    this.setPending(pending.filter((intent) => !settled(intent, this.state.machines, this.state.revision)));
  }

  private dropIntent(key: string): void {
    this.setPending(this.state.pending.filter((intent) => intent.key !== key));
  }

  private setPending(pending: PendingIntent[]): void {
    this.set({ pending, rows: visibleRows(this.state.machines, pending) });
  }

  private canChange(): boolean {
    return !!this.client && this.state.connection !== "disconnected" && !!this.state.auth?.signedIn;
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

/** The stats of a resize answer, without its `revision`. */
function statsOf(result: ResizeResult): MachineStats {
  const stats: MachineStats & { revision?: number } = { ...result };
  delete stats.revision;
  return stats;
}

/** The `revision` of a mutation result, when the owner sent one. */
function revisionOf(result: unknown): number | undefined {
  const revision = (result as { revision?: unknown } | null)?.revision;
  return typeof revision === "number" ? revision : undefined;
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
