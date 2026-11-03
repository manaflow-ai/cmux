// The Cloud page's state owner on the page side. The machine list is a mirror written only by the
// owner (`cmux.cloud.machine.list` pages once, then `cmux.cloud.machine.watch` events; no polling,
// no timers) plus one ordered log of pending intents (OWNERSHIP-PRINCIPLES "Clients are
// projections"). Money, destructive and view-changing ops go to the host as native actions (ops.ts
// NATIVE_ACTIONS). React reads it through `useSyncExternalStore`; tests drive it directly.
import { isPageError, type PageClient } from "../shared/pageClient";
import { AccountReader } from "./account";
import { connectionFailure } from "./connectionFailure";
import { DetailReader, type MachineDetail } from "./detail";
import { FilesReader } from "./files";
import { TransferWatch, type FileTransfer } from "./transfers";
import {
  applyEvent,
  defaultMemory,
  memoryChoices,
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
  AccountOps,
  CloudErrors,
  CloudOps,
  isGone,
  isUnsupported,
  planRefusal,
  type ActionRunResult,
  type AccountEvent,
  type AuthStatus,
  type CloudMachine,
  type CloudPlan,
  type CloudSnapshot,
  type CloudTeam,
  type CreateMachineArgs,
  type MachineEvent,
  type MachineListResult,
  type MachineResult,
  type MigrationStatus,
  type PlanRefusal,
  type SnapshotListResult,
} from "./ops";

export type Connection = "connecting" | "connected" | "disconnected" | "failed";

/** The first and the longest wait before the store reads auth again after the link refused it. */
export const CLOUD_RESTART_MIN_MS = 1_000;
export const CLOUD_RESTART_MAX_MS = 10_000;

export interface CreateDraft {
  /** One key per sheet: a retry after a failure sends the same key, so the owner creates once. */
  key: string;
  name: string;
  /** One of the plan's allowed `memory_options_mb`; the create sends it as `size.memory_mb`. */
  memoryMb?: number;
  /** Create from this snapshot (`from_snapshot`) instead of the base image. */
  from_snapshot?: string;
  /** The team's snapshots (`cloud.snapshot.list {}`). */
  snapshots?: CloudSnapshot[];
  /**
   * The snapshot list failed: the sheet says so beside Source and offers Retry, which reads it again
   * on the same draft (name, size, source and key kept). Base image stays choosable meanwhile.
   */
  snapshotsFailed?: boolean;
  submitting: boolean;
  error?: string;
  /** The server code of `error`, when it had one: the page shows its own sentence for known codes. */
  errorCode?: string;
  /** The backend refused the create for the plan (contract 1.5): a sentence and "See plans". */
  refusal?: PlanRefusal;
  /** The backend cannot create machines yet (no machine image configured): its own sentence. */
  blocked?: "no_snapshot_configured";
  /** Opened from a storefront tier: the new machine opens in a workspace once it runs. */
  openWhenRunning?: boolean;
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
  /** The last plan read failed (not "not served"): the storefront says so and offers Retry. */
  planFailed?: boolean;
  /** `cloud.migration.status` (contract 4). */
  migration?: MigrationStatus;
  /** "Later" hid the classic migration banner for this page session. */
  migrationDismissed: boolean;
  /** A plan refusal of a change outside the create sheet (start, resize, snapshot). */
  refusal?: PlanRefusal;
  /** A restore the backend cannot serve yet (no machine image configured): its own sentence. */
  blocked?: "no_snapshot_configured";
  selection?: string;
  detail?: MachineDetail;
  /** The storefront (`#/get`): what a cloud machine gives, the plan's sizes and Get. */
  view: CloudView;
  /** A machine created from the storefront: the page connects it once the mirror shows it running. */
  openWhenRunning?: string;
  create?: CreateDraft;
  error?: string;
  /** The server code of `error`, when it had one: the page shows its own sentence for known codes. */
  errorCode?: string;
  layout: MachineLayout;
  /** Ops (and native actions) the owner answered as not served yet: the page shows "Not available yet". */
  unavailable: string[];
  /** This session's file transfers, running and ended (`cloud.file.transfer.changed`). */
  transfers: FileTransfer[];
}

/** `machines` lists the team's machines; `get` is the storefront. */
export type CloudView = "machines" | "get";

/** The view from the page's URL fragment: `#/get` is the storefront, anything else the list. */
export function parseView(hash: string): CloudView {
  return hash.replace(/^#\/?/, "").split("?", 1)[0] === "get" ? "get" : "machines";
}

export interface CloudStoreOptions {
  newKey?: () => string;
  layout?: MachineLayout;
  view?: CloudView;
}

/** The host's answer to a native machine action: the op's answer fields, or a declined sheet. */
type MachineActionResult = ActionRunResult & Partial<MachineResult>;

export class CloudStore {
  private state: CloudState;
  private readonly listeners = new Set<() => void>();
  private started = false;
  private unwatch?: () => void;
  /** The account stream (`cmux.cloud.auth.watch`): lives from start to stop, across sessions. */
  private unwatchAuth?: () => void;
  /** Bumped by stop: an auth stream that subscribes after it is closed at once. */
  private lifetime = 0;
  /** The lifetime whose account subscribe is in flight, if any. */
  private watchingAuth?: number;
  /** The account stream's last event. */
  private lastAccount?: AccountEvent;
  /**
   * Bumped by stop, sign-out, team switch and retry. Every async load captures it and drops its
   * result (and closes its watch) when it changed, so an old account or team never writes state.
   */
  private session = 0;
  /** Bumped by sign-in, sign-out and team switch (not by Retry): an answer from another account is dropped. */
  private accountEpoch = 0;
  /** The next `start` after a first auth read the link refused (`startLater`); cleared by stop. */
  private restart: ReturnType<typeof setTimeout> | undefined;
  /** Link refusals of the first auth read in a row: the wait before the next one doubles. */
  private restartAttempts = 0;
  readonly detail: DetailReader;
  readonly files: FilesReader;
  readonly transfers: TransferWatch;
  readonly account: AccountReader;

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
      migrationDismissed: false,
      layout: options.layout ?? "rows",
      view: options.view ?? "machines",
      unavailable: [],
      transfers: [],
    };
    const host = {
      get: () => this.state.detail,
      set: (detail: MachineDetail | undefined) => this.set({ detail }),
      fail: (error: unknown) => this.set(failure(error)),
      unsupported: (op: string) => this.markUnavailable(op),
      planRefused: (error: unknown) => this.refused(error),
      usageChanged: () => void this.account.readPlan(this.session),
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
    this.account = new AccountReader(client, {
      get: () => this.state,
      set: (patch) => this.set(patch),
      session: () => this.session,
      fail: (op, error) => this.fail(op, error),
      unsupported: (op) => this.markUnavailable(op),
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
      const failed = failure(error);
      const connection = connectionFailure(error);
      this.set({ ...failed, loading: false, connection });
      if (connection === "disconnected") this.startLater();
      return;
    }
    if (session !== this.session) return;
    // The link answers: follow the app's account from here on (each start after a stop subscribes again).
    void this.watchAuth();
    // Back after `startLater`: the refused read's error goes, and the page loads as on a first
    // start (Retry does the same before it starts).
    const recovered = this.restartAttempts > 0;
    this.restartAttempts = 0;
    this.set({
      auth,
      connection: "connected",
      ...(recovered ? { loading: true, error: undefined, errorCode: undefined } : {}),
    });
    if (auth.signedIn) await this.loadSignedIn(session);
    else this.set({ loading: false });
  }

  stop(): void {
    this.started = false;
    this.lifetime += 1;
    this.unwatchAuth?.();
    this.unwatchAuth = undefined;
    this.watchingAuth = undefined;
    this.lastAccount = undefined;
    clearTimeout(this.restart);
    this.restart = undefined;
    this.restartAttempts = 0;
    this.endSession();
  }

  /**
   * The link refused the first auth read (on a launch or a daemon restart the daemon or its Cloud
   * relay is not up yet): read it again on its own, 1 s and then doubling to 10 s, so the page
   * comes up once the link does. The connection stays "disconnected" meanwhile (the page shows it
   * only once that lasts, ui/lasting.ts) and Retry still asks at once. Ends with a read that
   * succeeds or a failure that is not the link's, and with `stop` (the last listener leaving).
   */
  private startLater(): void {
    clearTimeout(this.restart);
    const delay = Math.min(CLOUD_RESTART_MAX_MS, CLOUD_RESTART_MIN_MS * 2 ** this.restartAttempts++);
    this.restart = setTimeout(() => {
      this.restart = undefined;
      if (this.listeners.size > 0) void this.start();
    }, delay);
  }

  get canRetry(): boolean {
    return this.client !== null;
  }

  /** After a disconnect: drops the old session and starts again (the localized Retry button). */
  async retry(): Promise<void> {
    this.stop();
    this.set({
      connection: this.client ? "connecting" : "disconnected",
      loading: true,
      error: undefined,
      errorCode: undefined,
    });
    await this.start();
  }

  /** Sign-in is a native browser flow the host runs as origin user (cloud-app.md section 2). */
  async signIn(): Promise<void> {
    if (!this.client || this.state.connection !== "connected") return;
    const session = this.session;
    try {
      const result = await this.client.call<ActionRunResult | null>(ACTION_RUN, {
        action: AccountOps.signIn,
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
      this.fail(AccountOps.signIn, error);
    }
  }

  async signOut(): Promise<void> {
    if (!this.canChange()) return;
    try {
      const result = await this.client!.call<ActionRunResult | null>(ACTION_RUN, {
        action: AccountOps.signOut,
        args: {},
      });
      if (result?.confirmed === false) return;
    } catch (error) {
      this.fail(AccountOps.signOut, error);
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
      await this.client!.call(AccountOps.teamSelect, { team, idempotency_key: this.key() });
    } catch (error) {
      if (session !== this.session) return;
      if (!isUnsupported(error)) return this.set({ loading: false, ...failure(error) });
      // Nothing changed at the owner: show the same team again.
      this.markUnavailable(AccountOps.teamSelect);
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
    if (this.state.error || this.state.refusal || this.state.blocked)
      this.set({ error: undefined, refusal: undefined, blocked: undefined });
  }

  /** Storefront Retry after a failed plan read. */
  retryPlan(): Promise<void> {
    return this.account.readPlan(this.session);
  }

  setView(view: CloudView): void {
    if (view !== this.state.view) this.set({ view });
  }

  // Create sheet.

  /**
   * Opens the create sheet, on `memoryMb` when the plan allows it. From a storefront tier
   * (`openWhenRunning`), the created machine opens in a workspace once it runs.
   */
  openCreate(memoryMb?: number, openWhenRunning = false): void {
    if (!this.canChange() || this.state.create) return;
    const key = this.key();
    const allowed = memoryChoices(this.state.plan).some((choice) => choice.mb === memoryMb && choice.allowed);
    const size = allowed ? memoryMb : defaultMemory(this.state.plan);
    this.set({
      create: { key, name: "", memoryMb: size, submitting: false, ...(openWhenRunning ? { openWhenRunning } : {}) },
    });
    this.loadSnapshots(key);
  }

  /** The sheet's Retry after the snapshot list failed: reads it again, keeping the draft. */
  retrySnapshots(): void {
    const draft = this.state.create;
    if (!draft?.snapshotsFailed || !this.canChange()) return;
    this.set({ create: { ...draft, snapshotsFailed: undefined } });
    this.loadSnapshots(draft.key);
  }

  /**
   * `cloud.snapshot.list {}` for the draft `key`. The answer lands only on that draft (a closed or
   * newer sheet, or another account's, drops it); a failure stays on it as `snapshotsFailed`.
   */
  private loadSnapshots(key: string): void {
    const onDraft = (patch: Partial<CreateDraft>) => {
      const draft = this.state.create;
      if (draft?.key === key) this.set({ create: { ...draft, ...patch } });
    };
    void this.client!.call<SnapshotListResult>(CloudOps.snapshotList, {}).then(
      ({ snapshots }) => onDraft({ snapshots, snapshotsFailed: undefined }),
      // An owner that serves no snapshot list has none to offer: Base image only, no failure.
      (error) => onDraft(isUnsupported(error) ? { snapshots: [] } : { snapshotsFailed: true }),
    );
  }

  closeCreate(): void {
    if (this.state.create && !this.state.create.submitting) this.set({ create: undefined });
  }

  updateDraft(patch: Partial<Pick<CreateDraft, "name" | "memoryMb" | "from_snapshot">>): void {
    const draft = this.state.create;
    if (draft && !draft.submitting)
      this.set({ create: { ...draft, ...patch, error: undefined, refusal: undefined, blocked: undefined } });
  }

  /**
   * `cloud.machine.create {name?, size, from_snapshot?}` as a native action (a money op, D-MONEY). The
   * size is the memory the sheet shows; without one (no plan) there is nothing to send.
   */
  async submitCreate(): Promise<void> {
    const draft = this.state.create;
    if (!draft || draft.submitting || !draft.memoryMb || !this.canChange()) return;
    this.set({ create: { ...draft, submitting: true, error: undefined, refusal: undefined, blocked: undefined } });
    const snapshot = draft.from_snapshot ? draft.snapshots?.find((s) => s.id === draft.from_snapshot) : undefined;
    const name = draft.name.trim() || (snapshot?.name ?? "");
    this.pushIntent({ key: draft.key, kind: "create", name });
    const args: CreateMachineArgs & { idempotency_key: string } = {
      ...(name ? { name } : {}),
      size: { memory_mb: draft.memoryMb },
      ...(draft.from_snapshot ? { from_snapshot: draft.from_snapshot } : {}),
      idempotency_key: draft.key,
    };
    const session = this.session;
    const accountEpoch = this.accountEpoch;
    try {
      const result = await this.client!.call<MachineActionResult | null>(ACTION_RUN, {
        action: CloudOps.machineCreate,
        args,
      });
      if (result?.confirmed === false) {
        this.dropIntent(draft.key);
        if (this.state.create?.key === draft.key) this.set({ create: { ...draft, submitting: false } });
        return;
      }
      // Recorded even after a session restart (stop, retry): the intent and the sheet must not
      // stay pending. A cleared log (sign-out, team switch) makes these no-ops.
      this.updateIntent(draft.key, { result_id: result?.machine?.id, replied: true, revision: revisionOf(result) });
      if (this.state.create?.key === draft.key) this.set({ create: undefined });
      // Kept across a Retry while the sheet was open; dropped when the account or team changed since.
      if (
        draft.openWhenRunning &&
        result?.machine?.id &&
        accountEpoch === this.accountEpoch &&
        this.state.auth?.signedIn
      ) {
        const id = result.machine.id;
        this.set({ openWhenRunning: id, view: "machines" });
        void this.select(id);
        this.openIfRunning();
      }
      if (session === this.session) void this.account.readPlan(session);
    } catch (error) {
      this.dropIntent(draft.key);
      const refusal = planRefusal(error, this.state.plan?.upgrade_plan);
      const blocked = noImage(error);
      const outcome = refusal
        ? { refusal }
        : blocked
          ? { blocked: "no_snapshot_configured" as const }
          : { error: message(error), errorCode: codeOf(error) };
      if (this.state.create?.key === draft.key) this.set({ create: { ...draft, submitting: false, ...outcome } });
      if (session === this.session && !refusal && !blocked) this.set(failure(error, false));
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
    await this.machineIntent("rename", machine, CloudOps.machineRename, { name: trimmed }, { name: trimmed });
  }

  /** Resizes memory to one of the plan's allowed sizes: a money op, so a native action. */
  async resize(machine: string, memoryMb: number): Promise<void> {
    await this.machineIntent(
      "resize",
      machine,
      CloudOps.machineResize,
      { size: { memory_mb: memoryMb } },
      { memoryMb },
      true,
    );
  }

  /** `null` = never pause (sent as 0 seconds). */
  async setIdlePolicy(machine: string, seconds: number | null): Promise<void> {
    await this.machineIntent(
      "idle",
      machine,
      CloudOps.machineIdlePolicySet,
      { idle_seconds: seconds ?? 0 },
      { idle: seconds },
    );
  }

  /** Installs the cmux-next daemon into a classic machine (contract 4.4), after a confirmation. */
  async upgrade(machine: string): Promise<void> {
    await this.machineIntent("upgrade", machine, CloudOps.machineUpgrade, {}, {}, true);
  }

  /** A new machine from a snapshot (`snapshot.restore`, a money op); a pending create until its echo. */
  async restoreSnapshot(snapshot: CloudSnapshot): Promise<void> {
    if (!this.canChange()) return;
    const key = this.key();
    const name = snapshot.name ?? "";
    this.pushIntent({ key, kind: "create", name });
    const session = this.session;
    try {
      const result = await this.client!.call<MachineActionResult | null>(ACTION_RUN, {
        action: CloudOps.snapshotRestore,
        args: { snapshot: snapshot.id, idempotency_key: key },
      });
      if (result?.confirmed === false) return this.dropIntent(key);
      // Recorded even after a session restart, so the pending create row cannot stay.
      this.updateIntent(key, { result_id: result?.machine?.id, replied: true, revision: revisionOf(result) });
      if (session === this.session) void this.account.readPlan(session);
    } catch (error) {
      this.dropIntent(key);
      if (session === this.session) this.fail(CloudOps.snapshotRestore, error);
    }
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
      if (result?.confirmed === false) return this.dropIntent(key);
      this.replied(key, result);
      void this.account.readPlan(this.session);
    } catch (error) {
      this.dropIntent(key);
      // `cmux.cloud.not_found`: the owner dropped it and sent `removed`. Nothing failed.
      if (!isGone(error)) this.fail(CloudOps.machineDelete, error);
    }
  }

  /** Opens the machine in the sidebar and a terminal through the host's connect action. */
  async connect(machine: string): Promise<void> {
    await this.native(CloudOps.machineConnect, { machine });
  }

  deleteSnapshot(snapshot: string): Promise<void> {
    return this.detail.deleteSnapshot(snapshot);
  }

  // Internals.

  /**
   * Follows the app's account: a page opened while signed out (or before the session was restored
   * at launch) shows the machines once the account signs in anywhere in the app, and a sign-out
   * elsewhere clears them. Each event only says "read auth again" (`accountChanged`).
   */
  private async watchAuth(): Promise<void> {
    const lifetime = this.lifetime;
    if (!this.client || this.unwatchAuth || this.watchingAuth === lifetime) return;
    // A subscribe of an earlier lifetime that is still in flight closes itself when it answers.
    this.watchingAuth = lifetime;
    try {
      const unwatch = await this.client.subscribe<AccountEvent>(CloudOps.authWatch, (event) => {
        if (lifetime !== this.lifetime) return;
        const previous = this.lastAccount;
        this.lastAccount = event;
        // Another signed-in account (a user switch): its auth status may read the same, so it reloads.
        const switched = !!previous?.signedIn && !!event?.signedIn && (previous.user ?? null) !== (event.user ?? null);
        void this.accountChanged(switched);
      });
      if (lifetime !== this.lifetime) return unwatch();
      this.unwatchAuth = unwatch;
    } catch {
      // An older host serves no account stream, or the link is down: the next start subscribes again.
    } finally {
      if (this.watchingAuth === lifetime) this.watchingAuth = undefined;
    }
  }

  /**
   * Reads auth again after an account event. Nothing changes when the page already shows that
   * account (its own Sign In, a team switch it ran, the stream's first event) unless `switched`
   * (another signed-in user); otherwise the old account's state goes and the new one loads, as
   * after the page's own sign-in or sign-out. A read that fails restarts the page the way a
   * failed first read does (back on its own once the link is, or Retry), so the event is never lost.
   */
  private async accountChanged(switched = false): Promise<void> {
    // Before the first auth read answered, that read is newer than the event.
    if (!this.client || this.state.connection !== "connected" || !this.state.auth) return;
    const session = this.session;
    let auth: AuthStatus;
    try {
      auth = await this.client.call<AuthStatus>(CloudOps.authStatus, {});
    } catch (error) {
      if (session !== this.session) return;
      // The old account's machines must not stay: drop them, and start again like a first read.
      this.restartSession();
      void this.detail.load(undefined);
      this.started = false;
      const connection = connectionFailure(error);
      this.set({ ...signedOutState(), auth: undefined, ...failure(error), connection });
      if (connection === "disconnected") this.startLater();
      return;
    }
    const shown = this.state.auth;
    if (session !== this.session || !shown) return;
    if (!switched && shown.signedIn === auth.signedIn && (shown.team ?? null) === (auth.team ?? null)) return;
    const next = this.restartSession();
    void this.detail.load(undefined);
    if (!auth.signedIn) return this.set({ ...signedOutState(), auth });
    this.set({ ...signedOutState(), auth, loading: true });
    await this.loadSignedIn(next);
  }

  private endSession(): void {
    this.session += 1;
    this.unwatch?.();
    this.unwatch = undefined;
    // Without the event stream a running row would never end: the session's transfers go with it.
    this.transfers.stop();
    if (this.state.transfers.length) this.set({ transfers: [] });
  }

  private restartSession(): number {
    this.accountEpoch += 1;
    this.endSession();
    return this.session;
  }

  /** Watches, then lists every page once; events that arrive during the list are merged by revision. */
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
      let page = await client.call<MachineListResult>(CloudOps.machineList, {});
      let machines = page.machines.map(normalizeMachine);
      // A listing from the first page to the last also lets the owner drop machines it did not see.
      while (page.next_cursor && session === this.session) {
        page = await client.call<MachineListResult>(CloudOps.machineList, { cursor: page.next_cursor });
        machines = [...machines, ...page.machines.map(normalizeMachine)];
      }
      if (session !== this.session) return;
      let revision = page.revision;
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
      if (session === this.session) this.set({ loading: false, connection: "failed", ...failure(error) });
      return;
    }
    await this.account.load(session);
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
    // An answer without a revision (a delete): the owner's next event for that machine is its echo,
    // whatever value the owner chose. Answers with a revision settle in setMirror.
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
    // The machine Get just created stays selected until its first event reaches the mirror.
    const gone =
      this.state.selection &&
      this.state.selection !== this.state.openWhenRunning &&
      !machines.some((machine) => machine.id === this.state.selection);
    if (gone) void this.detail.load(undefined);
    this.set({
      machines,
      revision,
      pending,
      rows: visibleRows(machines, pending),
      ...(gone ? { selection: undefined, detail: undefined } : {}),
      ...patch,
    });
    this.openIfRunning();
  }

  /**
   * A machine Get created opens in a workspace (the host's connect action) the first time the mirror
   * shows it running; a machine that fails or is being deleted drops the wish without connecting.
   * A machine the mirror does not show yet keeps the wish (its first event may follow the reply).
   */
  private openIfRunning(): void {
    const id = this.state.openWhenRunning;
    if (!id) return;
    const machine = this.state.machines.find((m) => m.id === id);
    if (machine?.status === "running") {
      this.set({ openWhenRunning: undefined });
      void this.connect(id);
    } else if (machine?.status === "failed" || machine?.status === "deleting") {
      this.set({ openWhenRunning: undefined });
    }
  }

  /**
   * Sends one machine intent, directly or (`native`) as a host action after its confirmation.
   * Answers the owner's result, or undefined after a reject or a declined sheet.
   */
  private async machineIntent(
    kind: IntentKind,
    machine: string,
    op: string,
    params: Record<string, unknown>,
    fields: Partial<PendingIntent> = {},
    native = false,
  ): Promise<unknown> {
    if (!this.canChange()) return undefined;
    const key = this.key();
    this.pushIntent({ key, kind, machine, ...fields });
    const session = this.session;
    const args = { machine, ...params, idempotency_key: key };
    try {
      // Recorded even after a session restart, so the intent cannot stay pending.
      const result = native
        ? await this.client!.call<MachineActionResult | null>(ACTION_RUN, { action: op, args })
        : await this.client!.call<MachineResult>(op, args);
      if (native && (result as ActionRunResult | null)?.confirmed === false) {
        this.dropIntent(key);
        return undefined;
      }
      this.replied(key, result);
      if (session === this.session && (kind === "start" || kind === "pause" || kind === "resize"))
        void this.account.readPlan(session);
      return result;
    } catch (error) {
      this.dropIntent(key);
      if (session === this.session) this.fail(op, error);
      return undefined;
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

  /**
   * A reject: a plan refusal shows its sentence and "See plans"; an op the owner does not serve yet
   * shows "Not available yet"; anything else shows the error banner.
   */
  private fail(op: string, error: unknown): void {
    if (this.refused(error)) return;
    if (noImage(error)) this.set({ blocked: "no_snapshot_configured", refusal: undefined, error: undefined });
    else if (isUnsupported(error)) this.markUnavailable(op);
    else this.set(failure(error));
  }

  /** Shows a plan refusal; false when `error` is none. */
  private refused(error: unknown): boolean {
    const refusal = planRefusal(error, this.state.plan?.upgrade_plan);
    if (refusal) this.set({ refusal, blocked: undefined });
    return !!refusal;
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
    return !!this.client && this.state.connection === "connected" && !!this.state.auth?.signedIn;
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
    migration: undefined,
    refusal: undefined,
    blocked: undefined,
    selection: undefined,
    detail: undefined,
    create: undefined,
    openWhenRunning: undefined,
    planFailed: undefined,
    error: undefined,
    loading: false,
  };
}

/** The projection `revision` of a mutation result, when the owner sent one. */
function revisionOf(result: unknown): number | undefined {
  const revision = (result as { revision?: unknown } | null)?.revision;
  return typeof revision === "number" ? revision : undefined;
}

/** The backend has no machine image yet (`cloud.no_snapshot_configured`): create and restore cannot run. */
function noImage(error: unknown): boolean {
  return isPageError(error) && error.code === CloudErrors.noSnapshotConfigured;
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function codeOf(error: unknown): string | undefined {
  return isPageError(error) ? error.code : undefined;
}

/**
 * A transport failure means the owner is unreachable: the page shows disconnected. The page shows one
 * alert at a time, so an error banner replaces the no-image banner.
 */
export function failure(error: unknown, withMessage = true): Partial<CloudState> {
  if (connectionFailure(error) === "disconnected") {
    return { connection: "disconnected", error: message(error), errorCode: codeOf(error), blocked: undefined };
  }
  return withMessage ? { error: message(error), errorCode: codeOf(error), blocked: undefined } : {};
}
