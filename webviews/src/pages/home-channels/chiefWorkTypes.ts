/** The current Chief's read-only work inventory, scoped by the owner to this machine. */
export interface HomeChiefWork {
  agents: {
    id: string;
    name: string;
    state: "working" | "waiting" | "idle" | "failed";
    task?: string | null;
    startedAt?: number | null;
    updatedAt?: number | null;
  }[];
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
