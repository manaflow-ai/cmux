// The Cloud page's state owner on the page side. The machine list is a mirror written only by the
// owner (`cmux.cloud.machine.list` pages once, then `cmux.cloud.machine.watch` events; no polling,
// no timers) plus one ordered log of pending intents (OWNERSHIP-PRINCIPLES "Clients are
// projections"). Money, destructive and view-changing ops go to the host as native actions (ops.ts
// NATIVE_ACTIONS). React reads it through `useSyncExternalStore`; tests drive it directly.
import { isPageError, type PageClient, pageError } from "../shared/pageClient";
import { userMessage } from "../shared/userMessage";
import { AccountReader } from "./account";
import { connectionFailure } from "./connectionFailure";
import { clearCachedMachines, readCachedMachines, writeCachedMachines, type CacheStorage } from "./machineCache";
import { DetailReader, type MachineDetail } from "./detail";
import { FilesReader } from "./files";
import { TransferWatch, type FileTransfer } from "./transfers";
import { archives, capOffer, noticeKey, readDismissed, writeDismissed, type CapOffer } from "./retention";
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
  type RetentionOverrides,
  type SnapshotListResult,
  type CloudSurge,
  type CloudUsage,
} from "./ops";

export type Connection = "connecting" | "connected" | "disconnected" | "failed";

/** The first and the longest wait before the store reads the page again after a failed read. */
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
   * The snapshot list failed: the sheet reads it again on its own (CreateSheet.tsx, useAutoRetry) on
   * the same draft (name, size, source and key kept), and says so beside Source only once that lasts.
   * Base image stays choosable meanwhile. Stays set until a read answers, across the re-reads.
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
  /**
   * The create was refused at a machines cap: the machine the sheet offers to free first ("Delete
   * NAME and create", or "Archive and delete NAME, then create"), or at the running-machines limit
   * with none of the person's machines idle ("Pause NAME and create").
   */
  offer?: CapOffer;
  /** The offered machine is being archived: the create runs once the mirror shows it gone. */
  waitingFor?: string;
}

/** Cloud settings' cleanup row: a save in flight, or why the last one was refused. */
export interface RetentionEdit {
  saving: boolean;
  /** The team's numbers are a team admin's (`auth.forbidden`). */
  forbidden?: boolean;
  error?: string;
}

export interface CloudState {
  connection: Connection;
  /**
   * The page lost its link or its first read failed, and the store reads it again on its own
   * (`readAgainLater`); set from that failure until a read succeeds, so the page keeps one quiet
   * stretch across the attempts instead of flashing between them.
   */
  recovering?: true;
  auth?: AuthStatus;
  loading: boolean;
  machines: CloudMachine[];
  revision: number;
  pending: PendingIntent[];
  rows: MachineRow[];
  teams: CloudTeam[];
  plan?: CloudPlan;
  /**
   * The last plan read failed (not "not served"): the storefront reads it again on its own and,
   * once that lasts, says it is still trying (Storefront.tsx, useAutoRetry).
   */
  planFailed?: boolean;
  /** `cloud.migration.status` (contract 4). */
  migration?: MigrationStatus;
  /** The account's latest payment failed (`cmux.cloud.billing.status`): the plan shows a notice. */
  paymentPastDue?: boolean;
  /** This month's usage and its price (`cloud.usage.current`); absent until read or when not served. */
  usage?: CloudUsage;
  /** The last usage read failed (not "not served"): the panel says so and offers Retry. */
  usageFailed?: boolean;
  /** The checkout answered that payments are not open yet (`cloud.billing.off`): no Add payment method button. */
  paymentOff?: boolean;
  /** "Later" hid the classic migration banner for this account (kept in this browser, account.ts). */
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
  /** The team's archive snapshots (`archive_of`), newest first: restorable machines the platform deleted. */
  archives: CloudSnapshot[];
  /** The latest surge as the last list read it (the surge card); absent when none. */
  surge?: CloudSurge;
  /** Retention notices dismissed in this browser (`machine:notice.at`); each shows once. */
  dismissed: ReadonlySet<string>;
  /** The cleanup settings' last save. */
  retention?: RetentionEdit;
}

/** `machines` lists the team's machines; `get` is the storefront. */
export type CloudView = "machines" | "get";

/** The view from the page's URL fragment: `#/get` is the storefront, anything else the list. */
export function parseView(hash: string): CloudView {
  return hash.replace(/^#\/?/, "").split("?", 1)[0] === "get" ? "get" : "machines";
}

export interface CloudStoreOptions {
  newKey?: () => string;
  /**
   * Where the last machine list is kept (machineCache.ts): the page passes its own storage, so a
   * page that opens draws that list in its first frame. Absent (tests, the gallery): nothing is kept.
   */
  cache?: CacheStorage;
  layout?: MachineLayout;
  view?: CloudView;
}

/** The host's answer to a native machine action: the op's answer fields, or a declined sheet. */
type MachineActionResult = ActionRunResult & Partial<MachineResult> & { made_room?: { machine?: CloudMachine } };

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
   * Bumped by stop, sign-out, team switch and a re-read. Every async load captures it and drops its
   * result (and closes its watch) when it changed, so an old account or team never writes state.
   */
  private session = 0;
  /** Bumped by sign-in, sign-out and team switch (not by a re-read): an answer from another account is dropped. */
  private accountEpoch = 0;
  /** The next `start` after a failed page read (`readAgainLater`); cleared by stop. */
  private restart: ReturnType<typeof setTimeout> | undefined;
  /** Failed page reads in a row: the wait before the next one doubles. */
  private restartAttempts = 0;
  /** Inside `stop`: the session it ends is not a failure to read again. */
  private halting = false;
  /**
   * The cached list's account, while the page shows that list and the owner has not answered yet:
   * the first auth read (and the account stream's first event) drop it when they name another.
   */
  private seeded?: { team: string | null; user?: string | null };
  /** The kept list's user, until the account stream's first event is checked against it. */
  private cachedUser?: string | null;
  /**
   * The user the kept list belongs to: the kept list's own, then each account event's. Unlike
   * `lastAccount` it outlives a stop (a reconnect), so a list kept after one still names its user.
   */
  private keptUser?: string | null;
  /** The machines on screen are the owner's answer, not the kept list of the first frame. */
  private ownerListed = false;
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
      archives: [],
      dismissed: readDismissed(),
    };
    // The last list this page showed, in its first frame: the owner's answer replaces it in place.
    const cached = client ? readCachedMachines(options.cache) : undefined;
    if (cached) {
      this.seeded = { team: cached.team, user: cached.user };
      this.cachedUser = cached.user;
      this.keptUser = cached.user;
      this.state = {
        ...this.state,
        auth: { signedIn: true, team: cached.team },
        machines: cached.machines,
        revision: cached.revision,
        rows: visibleRows(cached.machines, []),
      };
    }
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
      // The account could not be read at all: a kept list it never confirmed leaves the screen (a link
      // that is only down keeps it; the account is read again when the link is back).
      if (connection === "failed" && this.seeded) this.dropSeeded();
      // Read again on its own (`set` arms `readAgainLater`), whether the link refused it or the
      // owner answered with an error: auth is a read, asking again changes nothing.
      this.set({ ...failed, loading: false, connection });
      return;
    }
    if (session !== this.session) return;
    // The link answers: follow the app's account from here on (each start after a stop subscribes again).
    void this.watchAuth();
    // Back after `readAgainLater`: the failed read's error goes, and the page loads as on a first
    // start (as a first start does). The backoff resets only once the whole page
    // read (auth and, signed in, the machine list) succeeds.
    const recovered = this.restartAttempts > 0;
    // A kept list of another account or team (or a sign-out elsewhere) goes before anything shows it.
    if (this.seeded && (!auth.signedIn || (auth.team ?? null) !== this.seeded.team)) this.dropSeeded();
    this.seeded = undefined;
    this.set({
      auth,
      connection: "connected",
      ...(recovered ? { loading: true, error: undefined, errorCode: undefined } : {}),
    });
    if (auth.signedIn) await this.loadSignedIn(session);
    else this.set({ loading: false });
    if (session === this.session && this.state.connection === "connected") this.recovered();
  }

  stop(): void {
    this.halting = true;
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
    this.halting = false;
  }

  /**
   * The page lost its link or a page read failed (on a launch or a daemon restart the daemon or its
   * Cloud relay is not up yet; an owner that answered with an error for a moment): read it all again
   * on its own, 1 s and then doubling to 10 s, so the page comes up once the link and the owner do.
   * Nobody presses anything: every read here is a read, so asking again is never the person's
   * decision (Leo, 2026-11-22: "vacuous decisions like that should be just done"). The connection
   * stays "disconnected" or "failed" meanwhile and `recovering` holds the stretch, which the page
   * shows only once it lasts, as one quiet line (CloudPage.tsx). Armed by `set` on every change into
   * those states; ends with a read that succeeds, and with `stop` (the last listener leaving).
   */
  private readAgainLater(): void {
    clearTimeout(this.restart);
    const delay = Math.min(CLOUD_RESTART_MAX_MS, CLOUD_RESTART_MIN_MS * 2 ** this.restartAttempts++);
    this.restart = setTimeout(() => {
      this.restart = undefined;
      const { connection } = this.state;
      if (this.listeners.size === 0) return;
      // Back by another way meanwhile (an event proved the link, a sign-in read it all).
      if (connection !== "disconnected" && connection !== "failed") return this.recovered();
      // A fresh session, keeping what the page shows and the backoff.
      const attempts = this.restartAttempts;
      this.stop();
      this.restartAttempts = attempts;
      void this.start();
    }, delay);
  }

  /** The page read succeeded: the stretch of re-reads ends and the next failure waits 1 s again. */
  private recovered(): void {
    this.restartAttempts = 0;
    clearTimeout(this.restart);
    this.restart = undefined;
    if (this.state.recovering) this.set({ recovering: undefined });
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
    clearCachedMachines(this.options.cache);
    this.set({ ...signedOutState(), auth: { signedIn: false } });
  }

  async selectTeam(team: string): Promise<void> {
    if (!this.canChange() || team === this.state.auth?.team) return;
    const session = this.restartSession();
    void this.detail.load(undefined);
    this.set({ ...signedOutState(), loading: true });
    try {
      await this.client!.call(AccountOps.teamSelect, {
        team,
        idempotency_key: this.key(),
      });
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

  /** The page is shown again (the app became active, the tab came back): read the billing state again. */
  refreshBilling(): Promise<void> {
    return Promise.all([this.account.readBilling(this.session), this.account.readUsage(this.session)]).then(() => {});
  }

  /** Retry beside a failed usage read. */
  retryUsage(): Promise<void> {
    return this.account.readUsage(this.session);
  }

  /** "Add payment method": the host confirms, then opens the checkout in the browser. */
  addPaymentMethod(): Promise<void> {
    return this.account.checkout();
  }

  /** Manage Billing beside the payment notice. */
  manageBilling(): Promise<void> {
    return this.account.manageBilling();
  }

  /** Reads the plan again after a failed read (the storefront asks on its own, useAutoRetry). */
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
      create: {
        key,
        name: "",
        memoryMb: size,
        submitting: false,
        ...(openWhenRunning ? { openWhenRunning } : {}),
      },
    });
    this.loadSnapshots(key);
  }

  /**
   * Reads the snapshot list again after it failed (the sheet asks on its own), keeping the draft. The
   * failure stays on the draft until a read answers, so the sheet's quiet stretch spans the re-reads.
   */
  retrySnapshots(): void {
    const draft = this.state.create;
    if (!draft?.snapshotsFailed || !this.canChange()) return;
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
      this.set({
        create: {
          ...draft,
          ...patch,
          error: undefined,
          refusal: undefined,
          blocked: undefined,
          offer: undefined,
        },
      });
  }

  /**
   * `cloud.machine.create {name?, size, from_snapshot?}` as a native action (a money op, D-MONEY). The
   * size is the memory the sheet shows; without one (no plan) there is nothing to send.
   */
  async submitCreate(): Promise<void> {
    const draft = this.state.create;
    // Waiting on the make-room archive (Return in a field included): createIfRoom submits once it is gone.
    if (!draft || draft.submitting || draft.waitingFor || !draft.memoryMb || !this.canChange()) return;
    this.set({
      create: {
        ...draft,
        submitting: true,
        error: undefined,
        refusal: undefined,
        blocked: undefined,
        offer: undefined,
      },
    });
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
      // Recorded even after a session restart (stop, a re-read): the intent and the sheet must not
      // stay pending. A cleared log (sign-out, team switch) makes these no-ops.
      this.updateIntent(draft.key, {
        result_id: result?.machine?.id,
        replied: true,
        revision: revisionOf(result),
      });
      if (this.state.create?.key === draft.key) this.set({ create: undefined });
      if (session === this.session) this.madeRoom(result?.made_room?.machine);
      // Kept across a re-read while the sheet was open; dropped when the account or team changed since.
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
      const offer = capOffer(error, this.state.machines);
      const outcome = refusal
        ? { refusal }
        : blocked
          ? { blocked: "no_snapshot_configured" as const }
          : { error: message(error), errorCode: codeOf(error) };
      if (this.state.create?.key === draft.key)
        this.set({
          // A refusal is the key's answer: the server replays it for the same key, so the create
          // after making room (by the offer, or by hand on the page behind the sheet) needs a new one.
          create: {
            ...draft,
            submitting: false,
            waitingFor: undefined,
            ...outcome,
            ...(offer ? { offer } : {}),
            ...(offer || refusal ? { key: this.key() } : {}),
          },
        });
      if (session === this.session && !refusal && !blocked && !offer) this.set(failure(error, false));
    }
  }

  /**
   * The sheet's cap offer: free the offered machine, then create. A delete (a disposable or already
   * archived machine) creates as soon as the host answers it. An archive and delete keeps the
   * machine until its archive is ready, so the create waits for the machine's `removed` event on
   * the watch stream (no timer); the sheet says so meanwhile.
   */
  async makeRoom(): Promise<void> {
    const draft = this.state.create;
    const offer = draft?.offer;
    if (!draft || !offer || draft.submitting || draft.waitingFor || !this.canChange()) return;
    const action =
      offer.kind === "pause"
        ? CloudOps.machinePause
        : offer.kind === "delete"
          ? CloudOps.machineDelete
          : CloudOps.machineArchiveDelete;
    const key = this.key();
    this.pushIntent({ key, kind: offer.kind, machine: offer.machine });
    this.set({
      create: {
        ...draft,
        submitting: true,
        refusal: undefined,
        error: undefined,
        errorCode: undefined,
      },
    });
    const back = (patch: Partial<CreateDraft>) => {
      const now = this.state.create;
      if (now?.key === draft.key) this.set({ create: { ...now, submitting: false, ...patch } });
    };
    try {
      const args = { machine: offer.machine, idempotency_key: key };
      // A pause is a plain op (nothing is lost); a delete or an archive is confirmed natively. The
      // platform frees the slot when it takes the pause, so the create follows its answer.
      const result =
        offer.kind === "pause"
          ? await this.client!.call<MachineActionResult>(action, args)
          : await this.runNative(action, args);
      if (result?.confirmed === false) {
        this.dropIntent(key);
        return back({});
      }
      this.replied(key, result);
    } catch (error) {
      this.dropIntent(key);
      // A machine that is gone, or one a pause finds already stopped, holds no slot: go on to the create.
      const freed = isGone(error) || (offer.kind === "pause" && codeOf(error) === CloudErrors.notRunning);
      if (!freed && offer.kind === "pause") {
        // A pause that failed took nothing: the limit notice and the offer stay for another try, and
        // the sheet says why.
        if (connectionFailure(error) === "disconnected") this.set(failure(error));
        return back({
          refusal: draft.refusal,
          error: message(error),
          errorCode: codeOf(error),
        });
      }
      if (!freed) {
        this.fail(action, error);
        return back({ offer: undefined });
      }
    }
    if (offer.kind === "archive" && this.state.machines.some((machine) => machine.id === offer.machine)) {
      // Cancel stays open while the archive runs: closing the sheet drops the waiting create, and
      // the archive and delete goes on by itself.
      back({ offer: undefined, waitingFor: offer.machine });
      return;
    }
    back({ offer: undefined });
    await this.submitCreate();
  }

  /** The machine a waiting create freed is gone from the mirror: the create runs now. */
  private createIfRoom(): void {
    const draft = this.state.create;
    if (!draft?.waitingFor || this.state.machines.some((machine) => machine.id === draft.waitingFor)) return;
    this.set({
      create: { ...draft, waitingFor: undefined, submitting: false },
    });
    void this.submitCreate();
  }

  // Automatic cleanup (retention.ts).

  /** Keep pins a machine so nothing deletes it automatically; `false` lets its plan's cleanup apply. */
  async keep(machine: string, keep: boolean): Promise<void> {
    await this.machineIntent("keep", machine, CloudOps.machineKeep, { keep }, { keep });
  }

  /**
   * Archive and delete (a destructive native action): the platform archives the paused machine's disk
   * as a restorable snapshot, then deletes the machine. The archive list reads again once it is gone.
   */
  async archiveDelete(machine: string): Promise<void> {
    await this.machineIntent("archive", machine, CloudOps.machineArchiveDelete, {}, {}, true);
  }

  /** Hides a machine's notice for good in this browser (a new notice for it shows again). */
  dismissNotice(machine: string, at: number): void {
    const dismissed = new Set(this.state.dismissed);
    dismissed.add(noticeKey(machine, at));
    writeDismissed(dismissed);
    this.set({ dismissed });
  }

  /** Restores an archive as a new machine, named as the machine it was (a money op, native). */
  restoreArchive(snapshot: CloudSnapshot): Promise<void> {
    return this.restoreSnapshot(snapshot, snapshot.archive_of?.name ?? undefined);
  }

  /** The caller's own email heads-up before one of their machines is deleted. */
  setEmailHeadsUp(on: boolean): Promise<void> {
    return this.setRetention({ email_heads_up: on });
  }

  /** The team's cleanup numbers (a team admin); `null` goes back to the plan's. */
  setTeamRetention(settings: RetentionOverrides | null): Promise<void> {
    return this.setRetention({ settings });
  }

  private async setRetention(params: {
    email_heads_up?: boolean;
    settings?: RetentionOverrides | null;
  }): Promise<void> {
    if (!this.canChange() || this.state.retention?.saving) return;
    const session = this.session;
    this.set({ retention: { saving: true } });
    try {
      await this.client!.call(CloudOps.retentionSet, {
        ...params,
        idempotency_key: this.key(),
      });
      if (session !== this.session) return;
      this.set({ retention: undefined });
      await this.account.readPlan(session);
    } catch (error) {
      if (session !== this.session) return;
      if (isUnsupported(error)) {
        this.set({ retention: undefined });
        return this.markUnavailable(CloudOps.retentionSet);
      }
      const forbidden = isPageError(error) && error.code === "cmux.cloud.forbidden";
      this.set({
        retention: {
          saving: false,
          ...(forbidden ? { forbidden } : { error: message(error) }),
        },
      });
    }
  }

  /** `cloud.snapshot.list {}`: the team's archives. A failure or an older owner shows none. */
  private async readArchives(session: number): Promise<void> {
    if (!this.client) return;
    try {
      const { snapshots } = await this.client.call<SnapshotListResult>(CloudOps.snapshotList, {});
      if (session === this.session) this.set({ archives: archives(snapshots) });
    } catch {
      // The list shows no archives until the next read (page open, a delete).
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
  async restoreSnapshot(snapshot: CloudSnapshot, as?: string): Promise<void> {
    if (!this.canChange()) return;
    const key = this.key();
    const name = as ?? snapshot.name ?? "";
    this.pushIntent({ key, kind: "create", name });
    const session = this.session;
    try {
      const result = await this.runNative(CloudOps.snapshotRestore, {
        snapshot: snapshot.id,
        ...(as ? { name: as } : {}),
        idempotency_key: key,
      });
      if (result?.confirmed === false) return this.dropIntent(key);
      // Recorded even after a session restart, so the pending create row cannot stay.
      this.updateIntent(key, {
        result_id: result?.machine?.id,
        replied: true,
        revision: revisionOf(result),
      });
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
        // The first event is checked against the kept list's user, so another user's list never stays.
        const before =
          previous ?? (this.cachedUser !== undefined ? { signedIn: true, user: this.cachedUser } : undefined);
        this.cachedUser = undefined;
        const switched = !!before?.signedIn && !!event?.signedIn && (before.user ?? null) !== (event.user ?? null);
        const user = event?.signedIn ? (event.user ?? null) : undefined;
        if (user !== this.keptUser) {
          this.keptUser = user;
          // The owner's list kept before the stream named its user is kept again with it; a switch
          // reloads and keeps the new user's list instead.
          if (!switched && this.ownerListed) this.keepList();
        }
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
   * failed first read does (back on its own once the link is, `readAgainLater`), so the event is never lost.
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
      // `set` arms `readAgainLater`: the page reads auth again on its own.
      this.set({
        ...signedOutState(),
        auth: undefined,
        ...failure(error),
        connection: connectionFailure(error),
      });
      return;
    }
    const shown = this.state.auth;
    if (session !== this.session || !shown) return;
    if (!switched && shown.signedIn === auth.signedIn && (shown.team ?? null) === (auth.team ?? null)) return;
    const next = this.restartSession();
    void this.detail.load(undefined);
    if (!auth.signedIn) {
      clearCachedMachines(this.options.cache);
      return this.set({ ...signedOutState(), auth });
    }
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
        page = await client.call<MachineListResult>(CloudOps.machineList, {
          cursor: page.next_cursor,
        });
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
      this.setMirror(machines, revision, {
        loading: false,
        connection: "connected",
        error: undefined,
        surge: page.surge ?? undefined,
      });
      void this.readArchives(session);
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
    if (patch.connection) {
      if (this.started) this.restartAttempts = 0;
      // The drop's own words go with it: a link that is back never leaves "not connected" on screen.
      const code = this.state.errorCode;
      if (code && connectionFailure(pageError(code, "")) === "disconnected")
        Object.assign(patch, { error: undefined, errorCode: undefined });
    }
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
    // A machine that went with an archive (automatic cleanup, or archive and delete): its archive lists now.
    const archived =
      event.type === "removed" &&
      this.state.machines.some((machine) => machine.id === event.id && !!machine.delete_reason);
    // The team's spending cap marks its machines (a pending pause, a pause) through these events alone
    // (cmux-platform SpendCap.ts): a mark that changed reads the plan again, so the team's banner follows.
    const capChanged = event.type === "upsert" && capMarksChanged(this.state.machines, event.machine);
    this.setMirror(applyEvent(this.state.machines, event), event.revision, patch);
    if (archived) void this.readArchives(this.session);
    if (capChanged) void this.readPlanForCap();
  }

  /** One plan read at a time for the cap's marks: a pause marks every running machine at once (N events). */
  private capPlanRead: Promise<void> | undefined;
  private capPlanDirty = false;
  private async readPlanForCap(): Promise<void> {
    if (this.capPlanRead) {
      this.capPlanDirty = true;
      return;
    }
    do {
      this.capPlanDirty = false;
      this.capPlanRead = this.account.readPlan(this.session);
      await this.capPlanRead;
      this.capPlanRead = undefined;
    } while (this.capPlanDirty);
  }

  /**
   * The owner answered an intent. Its result revision settles it once the mirror reaches it (now,
   * when the watch event came first).
   */
  private replied(key: string, result: unknown): void {
    this.updateIntent(key, { replied: true, revision: revisionOf(result) });
  }

  /**
   * The machine the platform paused so a create fits the running-machines limit, as the create
   * answered it. Its row shows paused with the answer; the owner's event for it says the same.
   */
  private madeRoom(paused: CloudMachine | undefined): void {
    if (!paused?.id) return;
    const known = this.state.machines.find((machine) => machine.id === paused.id);
    // An event that already passed the answer wins: a newer record, or the machine's removal (a
    // machine the mirror does not hold is never added back by an answer).
    if (!known || Number(known.revision) > Number(paused.revision)) return;
    this.setMirror(
      applyEvent(this.state.machines, {
        type: "upsert",
        revision: this.state.revision,
        machine: paused,
      }),
      this.state.revision,
    );
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
    this.createIfRoom();
    this.keepList();
  }

  /** Keeps the list the owner just gave for the next open's first frame (machineCache.ts). */
  private keepList(): void {
    this.ownerListed = true;
    const { auth, connection, machines, revision } = this.state;
    if (!this.options.cache || !auth?.signedIn || connection !== "connected") return;
    writeCachedMachines(this.options.cache, {
      team: auth.team ?? null,
      user: this.keptUser,
      machines,
      revision,
    });
  }

  /** The kept list belongs to another account or team: it leaves the page and the storage. */
  private dropSeeded(): void {
    this.seeded = undefined;
    this.cachedUser = undefined;
    this.keptUser = undefined;
    clearCachedMachines(this.options.cache);
    this.set({ ...signedOutState(), auth: undefined, loading: true });
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
      const result = native ? await this.runNative(op, args) : await this.client!.call<MachineResult>(op, args);
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

  /**
   * A native machine action: the host's answer with the op's own fields at the top. A confirmed op
   * (`CONFIRMED_ACTIONS`) answers them under `value` (PageProviders `runConfirmed`).
   */
  private async runNative(action: string, args: Record<string, unknown>): Promise<MachineActionResult | null> {
    return confirmedValue(
      await this.client!.call<NativeAnswer | null>(ACTION_RUN, {
        action,
        args,
      }),
    );
  }

  private async native(action: string, args: Record<string, unknown>): Promise<void> {
    if (!this.canChange()) return;
    try {
      await this.client!.call<ActionRunResult | null>(ACTION_RUN, {
        action,
        args,
      });
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
    if (noImage(error))
      this.set({
        blocked: "no_snapshot_configured",
        refusal: undefined,
        error: undefined,
      });
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
    const wasDown = this.state.connection === "disconnected";
    this.state = { ...this.state, ...patch };
    // Any change into a lost link or a failed page read, from whichever read saw it, is read again
    // on its own (`readAgainLater`); one timer at a time, and none while `stop` ends the session.
    const { connection } = this.state;
    if (
      (connection === "disconnected" || connection === "failed") &&
      this.client &&
      !this.halting &&
      this.restart === undefined &&
      this.listeners.size > 0
    ) {
      if (!this.state.recovering) this.state = { ...this.state, recovering: true };
      this.readAgainLater();
    }
    // A live page whose link dropped under a read or an action reads everything again on its own,
    // keeping what it shows (a first read that failed has its own `startLater`).
    if (!wasDown && this.state.connection === "disconnected" && this.started) this.reconnectLater();
    for (const listener of this.listeners) listener();
  }

  /**
   * The link dropped while the page was live: after the same backoff as `startLater` (1 s doubling to
   * 10 s), the page starts again as Retry does, with no Retry and nothing cleared from the screen. Any
   * machine event meanwhile proves the link is back and ends the wait (`onEvent`).
   */
  private reconnectLater(): void {
    if (this.restart) return;
    const delay = Math.min(CLOUD_RESTART_MAX_MS, CLOUD_RESTART_MIN_MS * 2 ** this.restartAttempts++);
    this.restart = setTimeout(() => {
      this.restart = undefined;
      if (this.listeners.size === 0 || this.state.connection !== "disconnected") return;
      const attempts = this.restartAttempts;
      this.stop();
      this.restartAttempts = attempts;
      void this.start();
    }, delay);
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
    paymentPastDue: undefined,
    usage: undefined,
    usageFailed: undefined,
    paymentOff: undefined,
    refusal: undefined,
    blocked: undefined,
    selection: undefined,
    detail: undefined,
    create: undefined,
    openWhenRunning: undefined,
    planFailed: undefined,
    error: undefined,
    loading: false,
    archives: [],
    retention: undefined,
  };
}

/** The host's answer to a native action: a confirmed op's own answer sits under `value`. */
type NativeAnswer = MachineActionResult & { value?: unknown };

/** `{confirmed: true, value}` as the op's own fields beside `confirmed`; any other answer as it is. */
export function confirmedValue(answer: NativeAnswer | null): MachineActionResult | null {
  if (!answer || answer.confirmed !== true || answer.value === null || typeof answer.value !== "object") return answer;
  const { value, ...rest } = answer;
  return { ...rest, ...(value as Partial<MachineResult>) };
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

/** The plain sentence of a failure; the backend's own text stays in the error (`errorText` puts a
 * known code's page sentence first). */
const message = (error: unknown): string => userMessage(error);

function codeOf(error: unknown): string | undefined {
  return isPageError(error) ? error.code : undefined;
}

/**
 * A transport failure means the owner is unreachable: the page shows disconnected. The page shows one
 * alert at a time, so an error banner replaces the no-image banner.
 */
export function failure(error: unknown, withMessage = true): Partial<CloudState> {
  if (connectionFailure(error) === "disconnected") {
    return {
      connection: "disconnected",
      error: message(error),
      errorCode: codeOf(error),
      blocked: undefined,
    };
  }
  return withMessage ? { error: message(error), errorCode: codeOf(error), blocked: undefined } : {};
}

/** Whether `next` carries other spending cap marks (`spend_cap_pause_at`, `paused_by`) than the mirror's copy. */
function capMarksChanged(machines: readonly CloudMachine[], next: CloudMachine): boolean {
  const before = machines.find((machine) => machine.id === next.id);
  return (
    (before?.spend_cap_pause_at ?? null) !== (next.spend_cap_pause_at ?? null) ||
    (before?.paused_by ?? null) !== (next.paused_by ?? null)
  );
}
