/** The current Chief's read-only work inventory, scoped by the owner to this machine. */
export interface HomeChiefWork {
  agents: {
    id: string;
    name: string;
    state: "working" | "waiting" | "idle" | "failed";
    task?: string;
    startedAt?: number;
    updatedAt?: number;
  }[];
  tasks: {
    id: string;
    sessionId: string;
    title: string;
    status: "running" | "done" | "failed" | "cancelled" | "unknown";
    command?: string;
    startedAt?: number;
    endedAt?: number;
    detail?: string;
  }[];
  truncated: boolean;
  /** A snapshot must say when only harness background commands are available. */
  taskSources?: readonly string[];
}
