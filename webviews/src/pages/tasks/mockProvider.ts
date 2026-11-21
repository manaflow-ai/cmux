// An in-memory `cmux.tasks` owner for the browser dev loop (`/tasks/?mock`), the gallery and tests.
// It is not the backend: the Tasks owner (cmux-tui/crates/cmux-tasks) and its reducer own the rules.
// The mock keeps only enough of them (statuses, archive, assign, delegate) to drive the page, and its
// own rules, not the page model's, so tests compare the page's overlay with an independent owner.
// l10n-allow-file: sample data, not shipped UI.
import { pageError, type PageClient, type PageHandler } from "../shared/pageClient";
import { MockPageStreams } from "../shared/pageStreams";
import { OWNER_UNREACHABLE } from "./store";
import {
  TasksOps,
  type AgentRef,
  type Principal,
  type Session,
  type Snapshot,
  type Task,
  type TaskEvent,
  type TasksChanged,
} from "./types";

export interface MockCall {
  op: string;
  params: Record<string, unknown>;
}

export class MockTasksProvider implements PageClient {
  state: Snapshot;
  readonly calls: MockCall[] = [];
  /** No owner answers (`tasks.owner_unreachable`). */
  ownerDown = false;
  /** Keys whose mutation the owner refuses. */
  readonly rejectKeys = new Set<string>();
  /** When false, replies wait for `release()` (tests of the pending overlay). */
  answerImmediately = true;
  /** When true, a reply arrives before its echo events (`release` sends the events later). */
  echoAfterReply = false;
  /** The next mutations fail, in order, with these errors (`owner` is the owner's code). With
   * `commit` the owner applies it first and its echo is lost (the reply never came back). */
  readonly failNext: { code: string; owner?: string; commit?: boolean; echo?: boolean }[] = [];
  /** The next snapshot reads fail, in order, with these errors (a slow or lost owner). */
  readonly failSnapshots: { code: string; owner?: string }[] = [];
  /** How many `cmux.tasks.changed` subscribes fail before one works (a relay still recovering). */
  failSubscribes = 0;
  readonly page = new MockPageStreams();
  private readonly subs = new Map<number, (data: unknown, seq: number) => void>();
  private nextSub = 1;
  private readonly held: (() => void)[] = [];
  private readonly committed = new Set<string>();

  constructor(state: Snapshot = sampleSnapshot()) {
    this.state = structuredClone(state);
  }

  async call<R>(op: string, raw: unknown): Promise<R> {
    const params = (raw ?? {}) as Record<string, unknown>;
    this.calls.push({ op, params });
    if (this.ownerDown) {
      throw pageError("cmux.operation.failed", "Tasks is not running. Start it with cmux task serve.", false, {
        extra: { code: OWNER_UNREACHABLE },
      });
    }
    // As the daemon's page router: `machine` and `session` are host selectors, never an op's field.
    for (const selector of ["machine", "session"]) {
      const value = params[selector];
      if (value !== undefined && value !== "current" && value !== "local")
        throw pageError("validation.invalid", "a routed operation runs on this daemon: the selector must be current");
    }
    if (op === TasksOps.snapshot) {
      const failure = this.failSnapshots.shift();
      if (failure)
        throw pageError(
          failure.code,
          "no answer",
          true,
          failure.owner ? { extra: { code: failure.owner } } : undefined,
        );
      return structuredClone(this.state) as R;
    }
    const key = String(params.idempotency_key ?? "");
    if (!key) throw pageError("cmux.validation.invalid", "a Tasks mutation needs an idempotency_key");
    const failure = this.failNext.shift();
    if (failure) {
      if (failure.commit) {
        this.muted = !failure.echo;
        try {
          this.commit(op, params, key);
        } finally {
          this.muted = false;
        }
      }
      throw pageError(failure.code, "no answer", true, failure.owner ? { extra: { code: failure.owner } } : undefined);
    }
    const answer = () => this.commit(op, params, key);
    if (this.answerImmediately) return answer() as R;
    return new Promise<R>((resolve, reject) => {
      this.held.push(() => {
        try {
          resolve(answer() as R);
        } catch (error) {
          reject(error);
        }
      });
    });
  }

  /** Answers every held mutation, in order. */
  release(): void {
    for (const answer of this.held.splice(0)) answer();
  }

  private pendingEvents: TaskEvent[] = [];
  /** A failed call's commit: its events never reach the page. */
  private muted = false;

  /** Sends the echo events a reply went out before (`echoAfterReply`). */
  flushEvents(): void {
    for (const event of this.pendingEvents.splice(0)) this.publish({ change: event });
  }

  private commit(op: string, params: Record<string, unknown>, key: string): { result: unknown; seq: number } {
    if (this.committed.has(key)) return { result: { replay: true }, seq: this.state.seq };
    if (this.rejectKeys.has(key))
      throw pageError("cmux.operation.failed", "rejected by the owner", false, { extra: { code: "tasks.invalid" } });
    const changed: TaskEvent["change"][] = [];
    const task = (id: unknown) => {
      const found = this.state.tasks.find((candidate) => candidate.id === id);
      if (!found)
        throw pageError("cmux.operation.failed", "task not found", false, { extra: { code: "tasks.not_found" } });
      return found;
    };
    const upsert = (value: Task) => changed.push({ type: "upsert", value: { entity: "task", ...value } });
    switch (op) {
      case TasksOps.create: {
        const number = Math.max(0, ...this.state.tasks.map((t) => t.number)) + 1;
        const created: Task = {
          id: String(params.id),
          number,
          title: String(params.title),
          status: String(params.status ?? this.state.settings.default_status ?? "st_backlog"),
          sort_key: `${
            this.state.tasks
              .map((t) => t.sort_key)
              .sort()
              .at(-1) ?? ""
          }5`,
          priority: "none",
          labels: [],
          updated_at: Date.now(),
        };
        this.state.tasks.push(created);
        this.state.settings = { ...this.state.settings, next_number: number + 1 };
        upsert(created);
        break;
      }
      case TasksOps.update: {
        const target = task(params.task);
        if (typeof params.status === "string") {
          if (!this.state.statuses.some((status) => status.id === params.status)) {
            throw pageError("cmux.operation.failed", "unknown status", false, { extra: { code: "tasks.invalid" } });
          }
          target.status = params.status;
        }
        if (typeof params.assignee === "string") {
          if (!params.assignee.startsWith("usr_")) {
            throw pageError("cmux.operation.failed", "assign agents with task.delegate", false, {
              extra: { code: "tasks.invalid" },
            });
          }
          target.assignee = { kind: "user", id: params.assignee };
        }
        if (params.unassign === true) target.assignee = null;
        target.updated_at = Date.now();
        upsert(target);
        break;
      }
      case TasksOps.archive: {
        const target = task(params.task);
        target.archived = true;
        upsert(target);
        break;
      }
      case TasksOps.move: {
        const target = task(params.task);
        const order = this.state.tasks
          .filter((t) => !t.archived && t.id !== target.id)
          .sort((a, b) => (a.sort_key < b.sort_key ? -1 : 1));
        const after = order.findIndex((t) => t.id === params.after);
        const before = order.findIndex((t) => t.id === params.before);
        order.splice(after >= 0 ? after + 1 : before >= 0 ? before : order.length, 0, target);
        order.forEach((t, rank) => {
          const sortKey = String((rank + 1) * 10).padStart(6, "0");
          if (t.sort_key !== sortKey) {
            t.sort_key = sortKey;
            upsert(t);
          }
        });
        break;
      }
      case TasksOps.delegate: {
        const target = task(params.task);
        const harness = String(params.harness);
        const me = this.state.me.id ?? "";
        const agent: AgentRef = { principal: `agt_${harness}-${me.replace(/^usr_/, "")}`, harness, on_behalf_of: me };
        const session: Session = {
          id: String(params.agent_session),
          task: target.id,
          agent,
          status: "pending",
          plan: [],
        };
        this.state.sessions.push(session);
        target.delegate = agent;
        target.assignee ??= { kind: "user", id: me };
        upsert(target);
        changed.push({ type: "upsert", value: { entity: "session", ...session } });
        break;
      }
      default:
        throw pageError("cmux.operation.failed", "unknown Tasks operation", false, { extra: { code: "tasks.usage" } });
    }
    this.committed.add(key);
    this.state.seq += 1;
    const events = changed.map((change, index): TaskEvent => ({
      seq: this.state.seq,
      index,
      tx: key,
      kind: "task.updated",
      change,
    }));
    if (this.muted) return { result: { ok: true }, seq: this.state.seq };
    if (this.echoAfterReply) this.pendingEvents.push(...events);
    else for (const event of events) this.publish({ change: event });
    return { result: { ok: true }, seq: this.state.seq };
  }

  /** Delivers `data` on `cmux.tasks.changed` as the daemon would. */
  publish(data: TasksChanged): void {
    for (const sub of this.subs.values()) sub(structuredClone(data), 0);
  }

  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    const pageStream = this.page.subscribe(stream, onEvent as (data: unknown, seq: number) => void);
    if (pageStream) return pageStream;
    if (stream !== TasksOps.changed) throw pageError("cmux.protocol.unknown_op", stream);
    if (this.failSubscribes > 0) {
      this.failSubscribes -= 1;
      throw pageError("cmux.protocol.closed", "the relay is not connected", true);
    }
    const sub = this.nextSub++;
    this.subs.set(sub, onEvent as (data: unknown, seq: number) => void);
    return () => {
      this.subs.delete(sub);
    };
  }

  handle(_op: string, _handler: PageHandler): () => void {
    return () => {};
  }

  get subscriberCount(): number {
    return this.subs.size;
  }

  /** The host's link to the daemon went down or came back. */
  setHostConnected(connected: boolean): void {
    this.page.setConnected(connected);
  }

  /** The daemon's link to the owner ended (`tasks-changed {lost: true}`). */
  loseOwner(): void {
    this.ownerDown = true;
    this.publish({ lost: true });
  }
}

const user = (id: string): Principal => ({ kind: "user", id });

/** A believable team backlog with agents at work. */
export function sampleSnapshot(now = 1_759_400_000_000): Snapshot {
  const lawrence = user("usr_lawrence");
  const austin = user("usr_austin");
  const claude: AgentRef = { principal: "agt_claude-lawrence", harness: "claude", on_behalf_of: "usr_lawrence" };
  const codex: AgentRef = { principal: "agt_codex-lawrence", harness: "codex", on_behalf_of: "usr_lawrence" };
  type Row = [string, string, Task["priority"], Principal | null, AgentRef | null, string[], Task["attention"]];
  const rows: Row[] = [
    [
      "Drag a tab onto a docked column loses the tab",
      "st_in_progress",
      "urgent",
      lawrence,
      claude,
      ["lbl_bug", "lbl_agent"],
      "needs_input",
    ],
    ["Tasks: board drag between statuses", "st_in_review", "high", lawrence, codex, ["lbl_agent"], "review"],
    ["iOS: reconnect after Wi-Fi handoff", "st_todo", "high", austin, null, ["lbl_ios"], null],
    ["Idle wakeups above 1/s with an open browser tab", "st_in_progress", "medium", lawrence, null, ["lbl_perf"], null],
    ["Palette: show the task key next to the title", "st_backlog", "low", null, null, [], null],
    ["Agent session plan renders twice after reconnect", "st_triage", "none", null, null, ["lbl_bug"], null],
    ["Team VM: wake latency p95 under 300 ms", "st_todo", "medium", austin, null, ["lbl_perf"], null],
    ["Link PRs to tasks by branch name", "st_in_progress", "medium", lawrence, codex, ["lbl_agent"], "failed"],
    ["Localize the Tasks pane in Japanese", "st_done", "low", lawrence, null, [], null],
    ["Remove the old importer flag", "st_backlog", "none", null, null, [], null],
    ["Status follows agent activity: setting in Settings", "st_todo", "low", lawrence, null, ["lbl_agent"], null],
  ];
  return {
    seq: 42,
    me: lawrence,
    settings: { key_prefix: "CMX", next_number: rows.length + 1, default_status: "st_backlog" },
    statuses: [
      { id: "st_triage", name: "Triage", category: "triage", position: 0, color: 13 },
      { id: "st_backlog", name: "Backlog", category: "backlog", position: 1, color: 8 },
      { id: "st_todo", name: "Todo", category: "unstarted", position: 2, color: 7 },
      { id: "st_in_progress", name: "In Progress", category: "started", position: 3, color: 3 },
      { id: "st_in_review", name: "In Review", category: "started", position: 4, color: 2 },
      { id: "st_done", name: "Done", category: "completed", position: 5, color: 10 },
      { id: "st_canceled", name: "Canceled", category: "canceled", position: 6, color: 8 },
    ],
    labels: [
      { id: "lbl_bug", name: "bug", color: 1 },
      { id: "lbl_agent", name: "agent", color: 5 },
      { id: "lbl_ios", name: "ios", color: 4 },
      { id: "lbl_perf", name: "perf", color: 3 },
    ],
    projects: [],
    tasks: rows.map(([title, status, priority, assignee, delegate, labels, attention], index) => ({
      id: `task_${index + 1}`,
      number: index + 1,
      title,
      status,
      priority,
      assignee,
      delegate,
      labels,
      attention,
      sort_key: String((index + 1) * 3).padStart(2, "0"),
      updated_at: now - index * 3_600_000,
    })),
    sessions: [
      {
        id: "asess_1",
        task: "task_1",
        agent: claude,
        status: "awaiting_input",
        plan: [
          { content: "Reproduce the drop on a docked column", status: "completed" },
          { content: "Add a failing reducer test", status: "completed" },
          { content: "Fix the drop resolver", status: "in_progress" },
        ],
      },
      {
        id: "asess_2",
        task: "task_2",
        agent: codex,
        status: "done",
        plan: [
          { content: "Board columns from statuses", status: "completed" },
          { content: "Drop sends task.update", status: "completed" },
        ],
      },
      {
        id: "asess_3",
        task: "task_8",
        agent: codex,
        status: "failed",
        plan: [
          { content: "Parse the key from the branch", status: "completed" },
          { content: "GitHub App webhook", status: "pending" },
        ],
      },
    ],
  };
}
