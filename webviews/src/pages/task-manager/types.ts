// The Task Manager page's wire types: `cmux.task_manager.snapshot` events and the two calls
// (CmuxNextApp TaskManagerPageService.payload, TaskManagerPageProvider).

export const TaskManagerOps = {
  /** Stream: one `TaskManagerSnapshot` at once, then one per sample (about once a second). */
  snapshot: "cmux.task_manager.snapshot",
  /** `{ids}`: the selected rows, for `cmux app kill-process` with no pid; every page then gets a snapshot with it. */
  select: "cmux.task_manager.select",
  /** `{id}`: Kill Process for one row; the host runs it only on a click, key or menu choice. */
  kill: "cmux.task_manager.kill",
} as const;

/** One process: what it does for cmux and its numbers. */
export interface TaskManagerRow {
  /** `host:pid` (`local:4242`): the row's identity across samples. */
  id: string;
  /** `local` for this Mac, else a machine id. */
  host: string;
  pid: number;
  /** The tab titles it works for, else its kind's name ("cmux daemon"). */
  task: string;
  /** The executable name. */
  name: string;
  /** Share of one core over the last second; null until a second sample. */
  cpu: number | null;
  /** The CPU column's text, formatted by the app (a dash until a second sample). */
  cpuText: string;
  memoryBytes: number;
  memoryText: string;
  /** Why Kill Process will not end it (the app, a daemon, another machine), else null. */
  refusal: string | null;
}

export interface TaskManagerSnapshot {
  /** The sample's number; 0 before the first. */
  revision: number;
  /** In the app's order: the app, daemons and shared processes, then tab processes. */
  rows: TaskManagerRow[];
  /** The footer's numbers ("CPU 2.3% · Memory 145.2 MB"). */
  total: string;
  /**
   * The app's one selected row (every open page's), else null. The app sends it with each sample and
   * after every `select` from any page; Kill Process and `cmux app kill-process` act on it.
   * Absent from a host that does not hold the selection (the page then keeps its own).
   */
  selected?: string | null;
}

export type SortKey = "task" | "name" | "pid" | "cpu" | "memory";

/** A column's order; none keeps the app's order. */
export interface SortOrder {
  key: SortKey;
  ascending: boolean;
}

export const COLUMNS: readonly { key: SortKey; label: string; numeric: boolean }[] = [
  { key: "task", label: "taskManager.column.task", numeric: false },
  { key: "name", label: "taskManager.column.process", numeric: false },
  { key: "pid", label: "taskManager.column.pid", numeric: true },
  { key: "cpu", label: "taskManager.column.cpu", numeric: true },
  { key: "memory", label: "taskManager.column.memory", numeric: true },
];
