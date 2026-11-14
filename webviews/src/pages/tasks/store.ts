// The Tasks page's state owner: the mirror of the local Tasks owner (cmux.tasks.snapshot, then each
// cmux.tasks.changed event), the pending intents, and client view state (scope, selection, the New
// Task focus request). React reads it through `useSyncExternalStore`; tests drive it directly.
//
// Nothing polls. While the owner is unreachable the page retries the snapshot on a backoff (200 ms
// doubling to 10 s) only while the document is visible; the retry stops once the owner answers, the
// page hides, or the store stops.
import { isPageError, type PageClient } from "../shared/pageClient";
import { subscribePageStreams } from "../shared/pageStreams";
import {
  EMPTY_MIRROR,
  applyEvent,
  choiceIntent,
  committedIn,
  fromSnapshot,
  intentTask,
  intentWire,
  scoped,
  visibleTasks,
  type AssigneeChoice,
  type Intent,
  type IntentKind,
  type Mirror,
} from "./model";
import { TasksOps, type MutationReply, type Scope, type Snapshot, type Task, type TasksChanged } from "./types";

/** connecting: no answer yet; connected: the mirror is live; unreachable: no owner answers. */
export type Connection = "connecting" | "connected" | "unreachable";

export interface TasksSnapshot {
  connection: Connection;
  /** True once a snapshot arrived (a later loss keeps the rows, with a banner). */
  everConnected: boolean;
  mirror: Mirror;
  pending: readonly Intent[];
  /** Live tasks with the pending intents applied, in manual order. */
  tasks: readonly Task[];
  /** `tasks` narrowed by `scope`. */
  shown: readonly Task[];
  scope: Scope;
  selection?: string;
  /** Bumped by a New Task request; the field takes focus once per value. */
  newTaskRequest: number;
  /** The last refusal or failure, cleared by the next intent. */
  reject?: string;
}

export interface TasksStoreOptions {
  newKey?: () => string;
  newId?: (prefix: "task_" | "asess_") => string;
  /** The retry delays. */
  backoff?: { initial: number; maximum: number };
  /** Runs `run` after `ms` and returns its cancel; default `setTimeout` (tests step it by hand). */
  schedule?: (run: () => void, ms: number) => () => void;
  /** Whether the page is shown (the retry runs only then); default: the document's visibility. */
  visible?: () => boolean;
}

function timeout(run: () => void, ms: number): () => void {
  const timer = setTimeout(run, ms);
  return () => clearTimeout(timer);
}

export const OWNER_UNREACHABLE = "tasks.owner_unreachable";

/** The owner code of a routed failure (`details.extra.code`), when the daemon sent one. */
export function ownerCode(error: unknown): string | undefined {
  if (!isPageError(error)) return undefined;
  const details = error.details as { extra?: { code?: unknown } } | undefined;
  const code = details?.extra?.code;
  return typeof code === "string" ? code : undefined;
}

function unreachable(error: unknown): boolean {
  if (ownerCode(error) === OWNER_UNREACHABLE) return true;
  return isPageError(error) && (error.code === "cmux.protocol.closed" || error.code === "cmux.page.closed");
}

/** No answer the owner gave: the change may or may not have applied (the link broke, the call timed
 * out on either side, or the daemon refused a call without the person's gesture). The intent stays. */
function uncertain(error: unknown): boolean {
  return transient(error) || gestureRefused(error);
}

/** The link broke or a call timed out: worth reading again on the backoff. */
function transient(error: unknown): boolean {
  if (unreachable(error)) return true;
  if (ownerCode(error) === "tasks.timeout") return true;
  return isPageError(error) && TRANSIENT_CODES.has(error.code);
}

/** The daemon refused a call that no gesture backs (the page relay prefixes `cmux.`). */
function gestureRefused(error: unknown): boolean {
  return isPageError(error) && (error.code === "cmux.origin.forbidden" || error.code === "origin.forbidden");
}

const TRANSIENT_CODES = new Set(["cmux.protocol.timeout", "cmux.protocol.unavailable", "cmux.op.cancelled"]);

/** How many echo keys (`tx`) the store remembers, to settle a change whose reply was lost. */
const ECHO_MEMORY = 256;

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export class TasksStore {
  private snapshot: TasksSnapshot;
  private readonly listeners = new Set<() => void>();
  private lifetime = 0;
  private running = false;
  private unsubscribe?: () => void;
  private unpage?: () => void;
  /** Events that arrived before the snapshot they follow. */
  private early: TaskEventLike[] | null = null;
  private reading = false;
  private retryTimer?: () => void;
  private retryDelay: number;
  private readonly onVisibility = () => {
    if (this.visible() && this.snapshot.connection === "unreachable") this.scheduleRetry(true);
  };
  /** The start in flight, so a second `start()` waits for the same one. */
  private starting?: Promise<void>;
  /** A resync came while a read was in flight: read once more after it. */
  private readAgain = false;
  /** An event subscribe is in flight. */
  private subscribing = false;
  /** The latest echo keys (`tx`) the mirror took, oldest first (at most ECHO_MEMORY). */
  private readonly echoed = new Set<string>();

  constructor(
    private readonly client: PageClient | null,
    private readonly options: TasksStoreOptions = {},
  ) {
    this.retryDelay = options.backoff?.initial ?? 200;
    this.snapshot = {
      connection: client ? "connecting" : "unreachable",
      everConnected: false,
      mirror: EMPTY_MIRROR,
      pending: [],
      tasks: [],
      shown: [],
      scope: "all",
      newTaskRequest: 0,
    };
  }

  getSnapshot = (): TasksSnapshot => this.snapshot;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    if (this.listeners.size === 1) void this.start();
    return () => {
      this.listeners.delete(listener);
      if (this.listeners.size === 0) this.stop();
    };
  };

  /** Follows the page connection, subscribes to the owner's changes, then reads the snapshot.
   * Idempotent: a second call while one runs returns the same promise. */
  start(): Promise<void> {
    if (!this.client) return Promise.resolve();
    if (this.running) return this.starting ?? Promise.resolve();
    this.running = true;
    const starting = this.begin(this.client, ++this.lifetime).finally(() => {
      if (this.starting === starting) this.starting = undefined;
    });
    this.starting = starting;
    return starting;
  }

  private async begin(client: PageClient, lifetime: number): Promise<void> {
    if (typeof document !== "undefined") document.addEventListener("visibilitychange", this.onVisibility);
    try {
      const unpage = await subscribePageStreams(client, {
        onConnection: (connected) => {
          if (lifetime !== this.lifetime) return;
          if (!connected) this.set({ connection: "unreachable" });
          else if (this.snapshot.connection === "unreachable") void this.connect();
        },
      });
      if (lifetime !== this.lifetime) return unpage();
      this.unpage = unpage;
    } catch {
      // A host without the connection stream still answers reads.
    }
    await this.connect();
  }

  /** Subscribes to the owner's changes when not yet subscribed, then reads the snapshot. A failed
   * subscribe is unreachable and retried on the same backoff as a failed read. */
  private async connect(): Promise<void> {
    const client = this.client;
    if (!client || !this.running) return;
    const lifetime = this.lifetime;
    if (!this.unsubscribe) {
      // One subscribe at a time: a connection change during one waits for it, then reads.
      if (this.subscribing) return;
      this.subscribing = true;
      try {
        const unsubscribe = await client.subscribe<TasksChanged>(TasksOps.changed, (data) => {
          if (lifetime === this.lifetime) this.onChanged(data);
        });
        if (lifetime !== this.lifetime) return unsubscribe();
        this.unsubscribe = unsubscribe;
      } catch (error) {
        if (lifetime !== this.lifetime) return;
        this.set(
          unreachable(error) ? { connection: "unreachable" } : { connection: "unreachable", reject: message(error) },
        );
        this.scheduleRetry();
        return;
      } finally {
        if (lifetime === this.lifetime) this.subscribing = false;
      }
    }
    await this.read();
  }

  stop(): void {
    ++this.lifetime;
    this.running = false;
    this.starting = undefined;
    this.readAgain = false;
    this.reading = false;
    this.subscribing = false;
    this.cancelRetry();
    if (typeof document !== "undefined") document.removeEventListener("visibilitychange", this.onVisibility);
    this.unsubscribe?.();
    this.unsubscribe = undefined;
    this.unpage?.();
    this.unpage = undefined;
  }

  private visible(): boolean {
    if (this.options.visible) return this.options.visible();
    return typeof document === "undefined" || document.visibilityState !== "hidden";
  }

  /** Reads the snapshot; events that came meanwhile apply on top of it. */
  private async read(): Promise<void> {
    if (!this.client) return;
    if (this.reading) {
      this.readAgain = true;
      return;
    }
    const lifetime = this.lifetime;
    this.reading = true;
    this.early = [];
    try {
      const snapshot = await this.client.call<Snapshot>(TasksOps.snapshot, {});
      if (lifetime !== this.lifetime) return;
      let mirror = fromSnapshot(snapshot);
      const echoes: string[] = [];
      for (const event of this.early ?? []) {
        mirror = applyEvent(mirror, event);
        if (event.tx) echoes.push(event.tx);
      }
      this.early = null;
      this.cancelRetry();
      this.retryDelay = this.options.backoff?.initial ?? 200;
      this.setMirror(mirror, { connection: "connected", everConnected: true }, echoes);
    } catch (error) {
      if (lifetime !== this.lifetime) return;
      this.early = null;
      if (transient(error)) {
        // A lost link or a slow owner: unreachable for now, read again on the backoff.
        this.set({ connection: "unreachable" });
        this.scheduleRetry();
      } else {
        this.set({ connection: "unreachable", reject: message(error) });
      }
    } finally {
      if (lifetime === this.lifetime) {
        this.reading = false;
        if (this.readAgain) {
          this.readAgain = false;
          void this.read();
        }
      }
    }
  }

  private scheduleRetry(now = false): void {
    if (!this.running || this.retryTimer !== undefined || !this.visible()) return;
    const delay = now ? 0 : this.retryDelay;
    this.retryDelay = Math.min(this.retryDelay * 2, this.options.backoff?.maximum ?? 10_000);
    const run = () => {
      this.retryTimer = undefined;
      if (this.running && this.visible()) void this.connect();
    };
    this.retryTimer = this.options.schedule ? this.options.schedule(run, delay) : timeout(run, delay);
  }

  private cancelRetry(): void {
    this.retryTimer?.();
    this.retryTimer = undefined;
  }

  private onChanged(data: TasksChanged): void {
    if (data.resync) {
      // The relay reconnected or dropped events: keep the rows and pending intents, read again.
      void this.read();
      return;
    }
    if (data.lost) {
      // The daemon's link to the owner ended: keep the rows, refuse changes, read again.
      this.set({ connection: "unreachable" });
      void this.read();
      return;
    }
    const event = data.change;
    if (!event) return;
    if (this.early) {
      this.early.push(event);
      return;
    }
    if (this.snapshot.connection !== "connected") return;
    this.setMirror(applyEvent(this.snapshot.mirror, event), {}, event.tx ? [event.tx] : []);
  }

  // MARK: view state

  setScope(scope: Scope): void {
    if (scope !== this.snapshot.scope) this.recompute({ scope });
  }

  select(selection: string | undefined): void {
    if (selection !== this.snapshot.selection) this.set({ selection });
  }

  private newTaskHandled = 0;

  /** A user-run New Task: the field takes focus. */
  requestNewTask(): void {
    this.set({ newTaskRequest: this.snapshot.newTaskRequest + 1 });
  }

  /** True once per New Task request: the field that honors it consumes it, so a field mounted
   * later (the switch out of the owner-not-running view) never takes focus for an old request. */
  takeNewTaskRequest(): boolean {
    if (this.snapshot.newTaskRequest <= this.newTaskHandled) return false;
    this.newTaskHandled = this.snapshot.newTaskRequest;
    return true;
  }

  clearReject(): void {
    if (this.snapshot.reject) this.set({ reject: undefined });
  }

  // MARK: intents

  isPending(task: string): boolean {
    return this.snapshot.pending.some((intent) => intentTask(intent.kind) === task);
  }

  /** Where the create of task `id` stands: in flight, unsent (unknown outcome), done (in the
   * mirror) or refused (the owner said no; the reason is in `reject`). */
  createOutcome(id: string): { state: "sending" | "unsent"; key: string } | { state: "done" | "refused" } {
    const intent = this.snapshot.pending.find(
      (candidate) => candidate.kind.type === "create" && candidate.kind.id === id,
    );
    if (intent) return { state: intent.unsent ? "unsent" : "sending", key: intent.key };
    return { state: this.snapshot.mirror.tasks.has(id) ? "done" : "refused" };
  }

  /** Creates a task titled `title` (trimmed) in the owner's default status and selects it. */
  createTask(title: string): string | undefined {
    const trimmed = title.trim();
    if (!trimmed) return undefined;
    const id = this.newId("task_");
    if (!this.send({ type: "create", id, title: trimmed })) return undefined;
    this.select(id);
    return id;
  }

  setStatus(task: string, status: string): void {
    if (this.snapshot.tasks.find((candidate) => candidate.id === task)?.status === status) return;
    this.send({ type: "setStatus", task, status });
  }

  archive(task: string): void {
    this.send({ type: "archive", task });
  }

  move(task: string, after?: string, before?: string): void {
    this.send({ type: "move", task, after, before });
  }

  /** A person sends `update {assignee}`, an agent `delegate`, nobody `update {unassign}`. */
  choose(task: string, choice: AssigneeChoice): boolean {
    const item = this.snapshot.tasks.find((candidate) => candidate.id === task);
    if (!item) return false;
    const kind = choiceIntent(this.snapshot.mirror, item, choice, () => this.newId("asess_"));
    return kind ? this.send(kind) : false;
  }

  /** Sends an intent; refused while the owner is unreachable (nothing queues offline). */
  send(kind: IntentKind): boolean {
    if (!this.client || this.snapshot.connection !== "connected") return false;
    const intent: Intent = { key: this.options.newKey?.() ?? `idem_${crypto.randomUUID()}`, kind };
    this.recompute({ pending: [...this.snapshot.pending, intent], reject: undefined });
    void this.dispatch(intent);
    return true;
  }

  /** `resync`: a retry. Its first send may have committed with its echo lost, so the owner's reply
   * names a sequence no event will bring; the snapshot is read again after it. */
  private async dispatch(intent: Intent, resync = false): Promise<void> {
    if (!this.client) return;
    const lifetime = this.lifetime;
    const { verb, params } = intentWire(intent.kind);
    const op = TasksOps[verb as keyof typeof TasksOps];
    try {
      const reply = await this.client.call<MutationReply>(op, { ...params, idempotency_key: intent.key });
      if (lifetime !== this.lifetime) return;
      const settle = Number(reply.seq);
      // Its echo may already be in: the intent leaves now; else when the mirror reaches `settle`.
      const pending = this.snapshot.pending.flatMap((candidate) => {
        if (candidate.key !== intent.key) return [candidate];
        return settle <= this.snapshot.mirror.seq ? [] : [{ ...candidate, settle }];
      });
      this.recompute({ pending });
      if (resync) void this.read();
    } catch (error) {
      if (lifetime !== this.lifetime) return;
      if (uncertain(error)) {
        // Not the owner's refusal. If its echo already came or the mirror holds its result, it
        // committed: it settles. Else the person's change stays, unsent, until it shows in the mirror
        // or they retry or discard it. A gesture refusal says why; a broken link or a timeout reads
        // the snapshot again, which settles a change that did commit.
        const done = this.echoed.has(intent.key) || committedIn(this.snapshot.mirror, intent.kind);
        const pending = this.snapshot.pending.flatMap((candidate) => {
          if (candidate.key !== intent.key) return [candidate];
          return done ? [] : [{ ...candidate, unsent: true as const }];
        });
        const lost = unreachable(error);
        this.recompute({
          pending,
          ...(lost ? { connection: "unreachable" as const } : {}),
          ...(gestureRefused(error) ? { reject: message(error) } : {}),
        });
        if (!done && transient(error)) void this.read();
        return;
      }
      this.recompute({
        pending: this.snapshot.pending.filter((candidate) => candidate.key !== intent.key),
        reject: message(error),
      });
    }
  }

  /** Every unsent intent, oldest first (the Unsent changes strip). */
  unsentAll(): Intent[] {
    return this.snapshot.pending.filter((intent) => intent.unsent);
  }

  /** The unsent intent on `task` (a change whose outcome is unknown), if any. */
  unsent(task: string): Intent | undefined {
    return this.snapshot.pending.find((intent) => intent.unsent && intentTask(intent.kind) === task);
  }

  /** Sends an unsent intent again, from the person's click (a fresh gesture), with its original key:
   * the owner answers a key it already applied with its first reply, so nothing is done twice. */
  retry(key: string): boolean {
    if (!this.client || this.snapshot.connection !== "connected") return false;
    const intent = this.snapshot.pending.find((candidate) => candidate.key === key && candidate.unsent);
    if (!intent) return false;
    const { unsent: _, ...again } = intent;
    this.recompute({
      pending: this.snapshot.pending.map((candidate) => (candidate === intent ? again : candidate)),
      reject: undefined,
    });
    void this.dispatch(again, true);
    return true;
  }

  /** Drops an unsent intent: the person gave the change up. */
  discard(key: string): void {
    const pending = this.snapshot.pending.filter((candidate) => !(candidate.key === key && candidate.unsent));
    if (pending.length !== this.snapshot.pending.length) this.recompute({ pending });
  }

  private newId(prefix: "task_" | "asess_"): string {
    return this.options.newId?.(prefix) ?? `${prefix}${crypto.randomUUID()}`;
  }

  // MARK: state

  /** A new mirror: settled intents it covers leave, then the visible rows are derived again. */
  private setMirror(mirror: Mirror, patch: Partial<TasksSnapshot> = {}, echoes: readonly string[] = []): void {
    for (const tx of echoes) {
      this.echoed.delete(tx);
      this.echoed.add(tx);
      if (this.echoed.size > ECHO_MEMORY) this.echoed.delete(this.echoed.values().next().value!);
    }
    const pending = this.snapshot.pending.filter((intent) => {
      // An unsent change whose result or echo is in the mirror committed after all.
      if (intent.unsent) return !echoes.includes(intent.key) && !committedIn(mirror, intent.kind);
      return intent.settle === undefined || intent.settle > mirror.seq;
    });
    this.recompute({ ...patch, mirror, pending });
  }

  private recompute(patch: Partial<TasksSnapshot>): void {
    const next = { ...this.snapshot, ...patch };
    const tasks =
      next.mirror === this.snapshot.mirror && next.pending === this.snapshot.pending
        ? this.snapshot.tasks
        : visibleTasks(next.mirror, next.pending);
    const shown =
      tasks === this.snapshot.tasks && next.scope === this.snapshot.scope && next.mirror.me === this.snapshot.mirror.me
        ? this.snapshot.shown
        : scoped(tasks, next.scope, next.mirror.me);
    this.snapshot = { ...next, tasks, shown };
    this.emit();
  }

  private set(patch: Partial<TasksSnapshot>): void {
    this.snapshot = { ...this.snapshot, ...patch };
    this.emit();
  }

  private emit(): void {
    for (const listener of this.listeners) listener();
  }
}

type TaskEventLike = Parameters<typeof applyEvent>[1];
