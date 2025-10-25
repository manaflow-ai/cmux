export type RunBranchSyncStatus = "unknown" | "up_to_date" | "behind";

export interface RunBranchStatus {
  baseBranch: string;
  headBranch: string;
  headCommit: string;
  baseCommit?: string;
  mergeBase?: string;
  ahead: number;
  behind: number;
  status: RunBranchSyncStatus;
  dirty: boolean;
  mergeInProgress: boolean;
  warnings: string[];
  timestamp: number;
}

export interface RunSyncLogs {
  stdout: string;
  stderr: string;
}

export type RunSyncResponse =
  | {
      ok: true;
      status: RunBranchStatus;
      previousStatus?: RunBranchStatus;
      logs: RunSyncLogs;
    }
  | {
      ok: false;
      error: string;
      status?: RunBranchStatus;
      previousStatus?: RunBranchStatus;
      logs?: Partial<RunSyncLogs>;
    };

export interface RunSyncStatusResponse {
  ok: boolean;
  status?: RunBranchStatus;
  error?: string;
}

export interface RunSyncRequest {
  taskRunId: string;
}
