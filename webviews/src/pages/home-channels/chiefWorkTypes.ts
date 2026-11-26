/** A chat's kept task list as its list row carries it (acpmux `taskList`): counts and two steps. */
export interface HomeChiefPlan {
  source: "harness" | "agent" | "chief";
  done: number;
  total: number;
  /** The step in progress. */
  current?: string | null;
  /** The first pending step after it. */
  next?: string | null;
  updatedAt?: number | null;
}

export interface HomeChiefAgent {
  id: string;
  name: string;
  state: "working" | "waiting" | "idle" | "failed";
  task?: string | null;
  startedAt?: number | null;
  updatedAt?: number | null;
  plan?: HomeChiefPlan | null;
}

/** The current Chief's read-only work inventory, scoped by the owner to this machine. */
export interface HomeChiefWork {
  agents: HomeChiefAgent[];
  /** The Chief's own chats (not subagents) that keep a plan. */
  plans?: HomeChiefAgent[];
  tasks: {
    id: string;
    sessionId: string;
    title: string;
    status: "running" | "done" | "failed" | "cancelled" | "unknown";
    command?: string;
    startedAt?: number | null;
    endedAt?: number | null;
    detail?: string | null;
  }[];
  truncated: boolean;
  /** A snapshot must say when only harness background commands are available. */
  taskSources?: readonly string[];
}
