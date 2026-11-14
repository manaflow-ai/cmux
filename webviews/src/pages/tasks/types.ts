// Wire types of the Tasks page: the local Tasks owner's JSON (cmux-tui/crates/cmux-tasks-core, snake
// case) as the daemon relays it (cmux-tui/spec/page-router.md, routed namespace `tasks`).

export const TasksOps = {
  snapshot: "cmux.tasks.snapshot",
  create: "cmux.tasks.create",
  update: "cmux.tasks.update",
  move: "cmux.tasks.move",
  archive: "cmux.tasks.archive",
  delegate: "cmux.tasks.delegate",
  /** Daemon event `tasks-changed`: `{change: TaskEvent}` per owner commit event, or `{lost: true}`. */
  changed: "cmux.tasks.changed",
} as const;

export type Category = "triage" | "backlog" | "unstarted" | "started" | "completed" | "canceled";
export type Priority = "none" | "urgent" | "high" | "medium" | "low";
export type Attention = "needs_input" | "failed" | "review";
export type SessionStatus = "pending" | "claimed" | "working" | "awaiting_input" | "done" | "failed" | "canceled";

/** `{kind: user, id}` or `{kind: agent, principal, harness, …}`. */
export interface Principal {
  kind: string;
  id?: string;
  principal?: string;
  harness?: string;
  on_behalf_of?: string;
}

export interface AgentRef {
  principal: string;
  harness: string;
  on_behalf_of: string;
}

export interface Task {
  id: string;
  /** The owner's view carries it; an event's raw entity does not (the mirror derives it). */
  key?: string;
  number: number;
  title: string;
  status: string;
  /** As `key`: the view's, else the status's. */
  category?: Category;
  priority?: Priority;
  assignee?: Principal | null;
  delegate?: AgentRef | null;
  labels?: string[];
  project?: string | null;
  sort_key: string;
  attention?: Attention | null;
  updated_at?: number;
  archived?: boolean;
  deleted?: boolean;
}

export interface Status {
  id: string;
  name: string;
  category: Category;
  position: number;
  /** Ghostty palette index 0...15. */
  color: number;
}

export interface Label {
  id: string;
  name: string;
  color: number;
  archived?: boolean;
}

export interface Project {
  id: string;
  name: string;
  archived?: boolean;
}

export interface PlanStep {
  content: string;
  status: string;
}

export interface Session {
  id: string;
  task: string;
  agent: AgentRef;
  status: SessionStatus;
  plan: PlanStep[];
}

export interface Settings {
  key_prefix: string;
  next_number?: number;
  default_status?: string;
  started_status?: string | null;
  review_status?: string | null;
}

export interface Snapshot {
  seq: number;
  me: Principal;
  settings: Settings;
  statuses: Status[];
  labels: Label[];
  projects: Project[];
  tasks: Task[];
  sessions: Session[];
}

export type Entity =
  | ({ entity: "task" } & Task)
  | ({ entity: "status" } & Status)
  | ({ entity: "label" } & Label)
  | ({ entity: "project" } & Project)
  | ({ entity: "session" } & Session)
  | ({ entity: "settings" } & Settings)
  | { entity: "relation" | "comment" };

export type Change = { type: "upsert"; value: Entity } | { type: "remove"; entity: string; id: string };

/** One committed owner event (cmux-tasks-core `Event`). */
export interface TaskEvent {
  seq: number;
  index?: number;
  tx: string;
  kind: string;
  change: Change;
}

export interface TasksChanged {
  change?: TaskEvent;
  lost?: boolean;
  /** From the page relay after a reconnect or an event overflow: events may be missing. */
  resync?: boolean;
}

/** A mutation's reply: the owner's result and its committed sequence after the request. */
export interface MutationReply {
  result?: unknown;
  seq: number | string;
  /** The key had already applied: this is its first reply again. */
  replay?: boolean;
}

/** The layouts (user setting `tasks.layout`, decision T2). */
export type Layout = "list" | "board" | "inbox";
/** Which tasks the layouts show (client view state; My Tasks sets `mine`). */
export type Scope = "all" | "mine";
