// The Tasks page's pure model: the confirmed mirror of the owner (written only by its snapshot and
// events), the pending intents shown on top of it, and the layouts' grouping. No I/O; bun tests.
//
// An intent stays shown until the mirror reaches the sequence its reply named (its echo events
// arrived), or until the owner refuses it, so a change never snaps back and forth.
import type {
  AgentRef,
  Category,
  Label,
  Principal,
  Priority,
  Session,
  Settings,
  Snapshot,
  Status,
  Task,
  TaskEvent,
  Scope,
} from "./types";

export interface Mirror {
  /** The owner's sequence the mirror holds. */
  seq: number;
  /** The snapshot's sequence: an event at or below it is already in the snapshot. */
  base: number;
  me?: Principal;
  settings: Settings;
  /** In workflow order (category rank, then position). */
  statuses: Status[];
  labels: Map<string, Label>;
  tasks: Map<string, Task>;
  sessions: Map<string, Session>;
}

export type IntentKind =
  | { type: "setStatus"; task: string; status: string }
  | { type: "move"; task: string; after?: string; before?: string }
  | { type: "create"; id: string; title: string; status?: string }
  | { type: "archive"; task: string }
  /** The accountable person; `person` undefined unassigns. */
  | { type: "assign"; task: string; person?: string }
  /** `session` is the client-chosen `asess_` id, so a resend replays the same session. */
  | { type: "delegate"; task: string; session: string; harness: string };

export interface Intent {
  /** The idempotency key; the echo events carry it as `tx`. */
  key: string;
  kind: IntentKind;
  /** The owner's sequence after the request (its reply); the intent leaves once the mirror has it. */
  settle?: number;
  /** The outcome is unknown (the link broke, the call timed out, or a retry lacked the person's
   * gesture): the change may or may not have applied. It is listed under Unsent changes and its row
   * is marked, until the mirror shows its result or its echo, or the person retries it (with the same
   * key) or discards it. It is not drawn over the rows, so an unsent archive or cancel never hides
   * the row it names. It is never sent again on its own: a Tasks change needs the person's gesture. */
  unsent?: true;
}

/** The intent's result is already in the mirror (it committed while its reply was lost). A move
 * cannot be told from the mirror; it waits for its echo, a retry or a discard. */
export function committedIn(mirror: Mirror, kind: IntentKind): boolean {
  if (kind.type === "create") return mirror.tasks.has(kind.id);
  if (kind.type === "delegate") return mirror.sessions.has(kind.session);
  const task = mirror.tasks.get(kind.task);
  switch (kind.type) {
    case "setStatus":
      return task?.status === kind.status;
    case "archive":
      return !task || Boolean(task.archived);
    case "assign":
      return task !== undefined && (task.assignee?.id ?? undefined) === kind.person;
    case "move":
      return false;
  }
}

export const EMPTY_MIRROR: Mirror = {
  seq: 0,
  base: 0,
  settings: { key_prefix: "CMX" },
  statuses: [],
  labels: new Map(),
  tasks: new Map(),
  sessions: new Map(),
};

export function categoryRank(category: Category | undefined): number {
  switch (category) {
    case "triage":
      return 0;
    case "backlog":
      return 1;
    case "unstarted":
      return 2;
    case "started":
      return 3;
    default:
      return 4;
  }
}

export function isOpen(category: Category | undefined): boolean {
  return categoryRank(category) < 4;
}

export function priorityRank(priority: Priority | undefined): number {
  switch (priority) {
    case "urgent":
      return 0;
    case "high":
      return 1;
    case "medium":
      return 2;
    case "low":
      return 3;
    default:
      return 4;
  }
}

export function isTerminal(status: Session["status"]): boolean {
  return status === "done" || status === "failed" || status === "canceled";
}

/** `usr_…` or `agt_…`. */
export function stableId(principal: Principal | null | undefined): string {
  return principal?.id ?? principal?.principal ?? "";
}

/** The part after the id prefix (`usr_lawrence` is `lawrence`). */
export function shortName(id: string): string {
  const at = id.indexOf("_");
  return at >= 0 ? id.slice(at + 1) : id;
}

function sortStatuses(statuses: Iterable<Status>): Status[] {
  return [...statuses].sort((a, b) => categoryRank(a.category) - categoryRank(b.category) || a.position - b.position);
}

/** A task as the mirror keeps it: its key and category filled from the settings and its status. */
function normalize(task: Task, mirror: Pick<Mirror, "settings" | "statuses">): Task {
  const status = mirror.statuses.find((candidate) => candidate.id === task.status);
  return {
    ...task,
    key: `${mirror.settings.key_prefix}-${task.number}`,
    category: status?.category ?? task.category ?? "backlog",
  };
}

export function fromSnapshot(snapshot: Snapshot): Mirror {
  const seq = Number(snapshot.seq);
  const statuses = sortStatuses(snapshot.statuses);
  const base = { settings: snapshot.settings, statuses };
  return {
    seq,
    base: seq,
    me: snapshot.me,
    settings: snapshot.settings,
    statuses,
    labels: new Map(snapshot.labels.filter((label) => !label.archived).map((label) => [label.id, label])),
    tasks: new Map(snapshot.tasks.map((task) => [task.id, normalize(task, base)])),
    sessions: new Map(snapshot.sessions.map((session) => [session.id, session])),
  };
}

/** The mirror after one owner event (a new object; the old one is unchanged). */
export function applyEvent(mirror: Mirror, event: TaskEvent): Mirror {
  const seq = Number(event.seq);
  if (seq <= mirror.base) return mirror;
  const next: Mirror = { ...mirror, seq: Math.max(mirror.seq, seq) };
  const change = event.change;
  if (change.type === "remove") {
    if (change.entity === "status") {
      next.statuses = mirror.statuses.filter((status) => status.id !== change.id);
    }
    return next;
  }
  const value = change.value;
  switch (value.entity) {
    case "task": {
      const { entity: _entity, ...task } = value;
      next.tasks = new Map(mirror.tasks).set(task.id, normalize(task, mirror));
      break;
    }
    case "status": {
      const { entity: _entity, ...status } = value;
      next.statuses = sortStatuses([...mirror.statuses.filter((s) => s.id !== status.id), status]);
      // A status's category change reaches the tasks in it.
      next.tasks = new Map([...mirror.tasks].map(([id, task]) => [id, normalize(task, next)]));
      break;
    }
    case "label": {
      const { entity: _entity, ...label } = value;
      next.labels = new Map(mirror.labels);
      if (label.archived) next.labels.delete(label.id);
      else next.labels.set(label.id, label);
      break;
    }
    case "session": {
      const { entity: _entity, ...session } = value;
      next.sessions = new Map(mirror.sessions).set(session.id, session);
      break;
    }
    case "settings": {
      const { entity: _entity, ...settings } = value;
      next.settings = settings;
      // A new key prefix reaches every task's key.
      if (settings.key_prefix !== mirror.settings.key_prefix) {
        next.tasks = new Map([...mirror.tasks].map(([id, task]) => [id, normalize(task, next)]));
      }
      break;
    }
    default:
      break;
  }
  return next;
}

/** The op and params an intent sends (cmux-tasks-core ops; `cmux.tasks.<verb>` is `task.<verb>`). */
export function intentWire(kind: IntentKind): { verb: string; params: Record<string, unknown> } {
  switch (kind.type) {
    case "setStatus":
      return { verb: "update", params: { task: kind.task, status: kind.status } };
    case "move":
      return {
        verb: "move",
        params: {
          task: kind.task,
          ...(kind.after ? { after: kind.after } : {}),
          ...(kind.before ? { before: kind.before } : {}),
        },
      };
    case "create":
      return {
        verb: "create",
        params: { id: kind.id, title: kind.title, ...(kind.status ? { status: kind.status } : {}) },
      };
    case "archive":
      return { verb: "archive", params: { task: kind.task } };
    case "assign":
      return {
        verb: "update",
        params: kind.person ? { task: kind.task, assignee: kind.person } : { task: kind.task, unassign: true },
      };
    case "delegate":
      // `agent_session`, not `session`: the page router takes `session` as the host selector.
      return { verb: "delegate", params: { task: kind.task, agent_session: kind.session, harness: kind.harness } };
  }
}

export function intentTask(kind: IntentKind): string {
  return kind.type === "create" ? kind.id : kind.task;
}

function byOrder(a: Task, b: Task): number {
  return a.sort_key < b.sort_key ? -1 : a.sort_key > b.sort_key ? 1 : a.number - b.number;
}

/**
 * The live tasks the page shows, in manual order: the mirror with every pending intent applied the
 * way the owner will (its echo then confirms or corrects the row).
 */
export function visibleTasks(mirror: Mirror, pending: readonly Intent[]): Task[] {
  const tasks = new Map(mirror.tasks);
  const moves: Extract<IntentKind, { type: "move" }>[] = [];
  // Each pending create takes the next number in turn (the owner does not echo `next_number`).
  let nextNumber = Math.max(mirror.settings.next_number ?? 0, maxNumber(tasks) + 1);
  for (const { kind, unsent } of pending) {
    // An unsent change is not drawn: its row keeps its confirmed state and place (an unsent archive
    // or cancel would hide it), and the Unsent changes strip lists it. An unsent create's text is
    // back in the New Task field.
    if (unsent) continue;
    if (kind.type === "move") {
      moves.push(kind);
      continue;
    }
    if (kind.type === "create") {
      if (tasks.has(kind.id)) continue;
      const status = kind.status ?? mirror.settings.default_status ?? firstStatus(mirror)?.id ?? "";
      const number = nextNumber++;
      tasks.set(
        kind.id,
        normalize({ id: kind.id, number, title: kind.title, status, sort_key: "￿", updated_at: Date.now() }, mirror),
      );
      continue;
    }
    const task = tasks.get(kind.task);
    if (!task) continue;
    switch (kind.type) {
      case "setStatus":
        tasks.set(task.id, normalize({ ...task, status: kind.status }, mirror));
        break;
      case "archive":
        tasks.set(task.id, { ...task, archived: true });
        break;
      case "assign":
        tasks.set(task.id, { ...task, assignee: kind.person ? { kind: "user", id: kind.person } : null });
        break;
      case "delegate": {
        const me = stableId(mirror.me);
        const agent: AgentRef = {
          principal: `agt_${kind.harness}-${shortName(me)}`,
          harness: kind.harness,
          on_behalf_of: me,
        };
        tasks.set(task.id, { ...task, delegate: agent, assignee: task.assignee ?? mirror.me ?? null });
        break;
      }
    }
  }
  let order = [...tasks.values()].filter((task) => !task.archived && !task.deleted).sort(byOrder);
  for (const move of moves) {
    const moving = order.find((task) => task.id === move.task);
    if (!moving) continue;
    order = order.filter((task) => task.id !== move.task);
    const after = move.after ? order.findIndex((task) => task.id === move.after) : -1;
    const before = move.before ? order.findIndex((task) => task.id === move.before) : -1;
    const at = after >= 0 ? after + 1 : before >= 0 ? before : order.length;
    order.splice(at, 0, moving);
  }
  return order;
}

function maxNumber(tasks: Map<string, Task>): number {
  let max = 0;
  for (const task of tasks.values()) max = Math.max(max, task.number);
  return max;
}

function firstStatus(mirror: Mirror): Status | undefined {
  return mirror.statuses.find((status) => status.category === "backlog") ?? mirror.statuses[0];
}

/** `tasks` narrowed by the scope (My Tasks: the local person is accountable). */
export function scoped(tasks: readonly Task[], scope: Scope, me: Principal | undefined): Task[] {
  if (scope === "all") return [...tasks];
  const id = stableId(me);
  if (!id) return [];
  return tasks.filter((task) => stableId(task.assignee) === id);
}

export interface StatusGroup {
  status: Status;
  tasks: Task[];
}

/** One group per status in workflow order, canceled left out (list sections, board columns). */
export function statusGroups(statuses: readonly Status[], tasks: readonly Task[]): StatusGroup[] {
  const byStatus = new Map<string, Task[]>();
  for (const task of tasks) {
    const rows = byStatus.get(task.status);
    if (rows) rows.push(task);
    else byStatus.set(task.status, [task]);
  }
  return statuses
    .filter((status) => status.category !== "canceled")
    .map((status) => ({ status, tasks: byStatus.get(status.id) ?? [] }));
}

export type InboxGroupId = "needsInput" | "review" | "failed" | "mine" | "rest";

export interface InboxGroup {
  id: InboxGroupId;
  tasks: Task[];
}

/** Attention first: every visible open task lands in exactly one group, by priority then recency. */
export function inboxGroups(tasks: readonly Task[], me: Principal | undefined): InboxGroup[] {
  const groups: Record<InboxGroupId, Task[]> = { needsInput: [], review: [], failed: [], mine: [], rest: [] };
  const mine = stableId(me);
  const open = tasks
    .filter((task) => isOpen(task.category))
    .sort((a, b) => priorityRank(a.priority) - priorityRank(b.priority) || (b.updated_at ?? 0) - (a.updated_at ?? 0));
  for (const task of open) {
    switch (task.attention) {
      case "needs_input":
        groups.needsInput.push(task);
        break;
      case "review":
        groups.review.push(task);
        break;
      case "failed":
        groups.failed.push(task);
        break;
      default:
        if (mine && stableId(task.assignee) === mine) groups.mine.push(task);
        else groups.rest.push(task);
    }
  }
  return (Object.keys(groups) as InboxGroupId[]).map((id) => ({ id, tasks: groups[id] }));
}

/** The task's active agent session, else its most recent one. */
export function sessionFor(mirror: Mirror, task: string): Session | undefined {
  const sessions = [...mirror.sessions.values()]
    .filter((session) => session.task === task)
    .sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  return sessions.find((session) => !isTerminal(session.status)) ?? sessions.at(-1);
}

/** Agents cmux launches (the Assignee control's agents when the mirror names none). */
export const DEFAULT_AGENTS = ["claude", "codex", "opencode"];

export interface AssigneeChoices {
  /** The local person first, then everyone the mirror names, by id. */
  people: string[];
  /** The known agents, then any the mirror names. */
  agents: string[];
}

/** People and agents for the Assignee control (decision T3). There is no team directory yet. */
export function assigneeChoices(mirror: Mirror, tasks: readonly Task[]): AssigneeChoices {
  const me = stableId(mirror.me);
  const others = new Set<string>();
  for (const task of tasks) {
    if (task.assignee?.kind === "user" && task.assignee.id) others.add(task.assignee.id);
    if (task.delegate) others.add(task.delegate.on_behalf_of);
  }
  for (const session of mirror.sessions.values()) others.add(session.agent.on_behalf_of);
  others.delete(me);
  others.delete("");
  const agents = [...DEFAULT_AGENTS];
  const seen = new Set<string>([
    ...tasks.flatMap((task) => (task.delegate ? [task.delegate.harness] : [])),
    ...[...mirror.sessions.values()].map((session) => session.agent.harness),
  ]);
  for (const harness of [...seen].sort()) if (!agents.includes(harness)) agents.push(harness);
  return { people: [...(me ? [me] : []), ...[...others].sort()], agents };
}

export type AssigneeChoice = { type: "person"; id: string } | { type: "agent"; harness: string } | { type: "nobody" };

/** Whether the task has `choice` now (menu check marks). Only the local person's agent counts. */
export function isCurrentChoice(mirror: Mirror, task: Task, choice: AssigneeChoice): boolean {
  switch (choice.type) {
    case "person":
      return stableId(task.assignee) === choice.id;
    case "nobody":
      return !task.assignee;
    case "agent": {
      const me = stableId(mirror.me);
      return !!task.delegate && task.delegate.harness === choice.harness && (!me || task.delegate.on_behalf_of === me);
    }
  }
}

/** The intent that picks `choice` for `task`, or undefined when the task already has it. */
export function choiceIntent(
  mirror: Mirror,
  task: Task,
  choice: AssigneeChoice,
  newSession: () => string,
): IntentKind | undefined {
  switch (choice.type) {
    case "person":
      return stableId(task.assignee) === choice.id ? undefined : { type: "assign", task: task.id, person: choice.id };
    case "nobody":
      return task.assignee ? { type: "assign", task: task.id } : undefined;
    case "agent": {
      const me = stableId(mirror.me);
      // One working session per agent and task (owner invariant 10).
      const active = [...mirror.sessions.values()].some(
        (session) =>
          session.task === task.id &&
          session.agent.harness === choice.harness &&
          (!me || session.agent.on_behalf_of === me) &&
          !isTerminal(session.status),
      );
      return active ? undefined : { type: "delegate", task: task.id, session: newSession(), harness: choice.harness };
    }
  }
}

/** Product names stay in English (as the agent marks do). */
export function agentName(harness: string): string {
  // l10n-allow: product names.
  const names: Record<string, string> = { claude: "Claude", codex: "Codex", opencode: "OpenCode", pi: "Pi" };
  return names[harness] ?? harness;
}

/** The first task the inbox selects when nothing is selected. */
export function firstInboxTask(groups: readonly InboxGroup[]): Task | undefined {
  for (const group of groups) if (group.tasks.length) return group.tasks[0];
  return undefined;
}
