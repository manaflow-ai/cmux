/**
 * Auto-Checkpoint Detection Hook
 *
 * Monitors task run state and automatically adds checkpoints when significant
 * actions are detected (commits, status changes, etc.)
 */

import { useEffect, useRef } from "react";
import { useQuery } from "convex/react";
import { api } from "@cmux/convex/api";
import type { Id } from "@cmux/convex/dataModel";
import type { VideoCheckpoint } from "./use-vnc-recorder";

export interface UseAutoCheckpointsOptions {
  /** Team slug or ID */
  teamSlugOrId: string;
  /** Task run ID to monitor */
  runId: Id<"taskRuns">;
  /** Whether auto-checkpoints are enabled */
  enabled: boolean;
  /** Callback to add a checkpoint */
  onCheckpoint: (
    label: string,
    options?: { description?: string; type?: VideoCheckpoint["type"] }
  ) => void;
}

interface TaskRunSnapshot {
  status?: string;
  screenshotCommitSha?: string;
  newBranch?: string;
  vscodeStatus?: string;
}

/**
 * Hook that monitors task run state and triggers checkpoints on significant changes.
 */
export function useAutoCheckpoints(options: UseAutoCheckpointsOptions) {
  const { teamSlugOrId, runId, enabled, onCheckpoint } = options;

  // Subscribe to task run updates
  const taskRun = useQuery(
    api.taskRuns.get,
    enabled ? { teamSlugOrId, id: runId } : "skip"
  );

  // Track previous state to detect changes
  const prevStateRef = useRef<TaskRunSnapshot | null>(null);
  const isFirstUpdateRef = useRef(true);

  useEffect(() => {
    if (!enabled || !taskRun) return;

    const currentState: TaskRunSnapshot = {
      status: taskRun.status,
      screenshotCommitSha: taskRun.screenshotCommitSha,
      newBranch: taskRun.newBranch,
      vscodeStatus: taskRun.vscode?.status,
    };

    const prevState = prevStateRef.current;

    // Skip the first update to avoid checkpoint on initial load
    if (isFirstUpdateRef.current) {
      isFirstUpdateRef.current = false;
      prevStateRef.current = currentState;
      return;
    }

    // Detect changes and create checkpoints

    // 1. Commit detected (new commit SHA)
    if (
      currentState.screenshotCommitSha &&
      currentState.screenshotCommitSha !== prevState?.screenshotCommitSha
    ) {
      const shortSha = currentState.screenshotCommitSha.slice(0, 7);
      onCheckpoint(`Commit ${shortSha}`, {
        description: `New commit pushed: ${currentState.screenshotCommitSha}`,
        type: "commit",
      });
    }

    // 2. Branch created
    if (currentState.newBranch && !prevState?.newBranch) {
      onCheckpoint(`Branch created`, {
        description: `Created branch: ${currentState.newBranch}`,
        type: "milestone",
      });
    }

    // 3. Workspace started
    if (
      currentState.vscodeStatus === "running" &&
      prevState?.vscodeStatus !== "running"
    ) {
      onCheckpoint("Workspace ready", {
        description: "Development workspace is now running",
        type: "milestone",
      });
    }

    // 4. Run completed
    if (currentState.status === "completed" && prevState?.status !== "completed") {
      onCheckpoint("Run completed", {
        description: "Task run completed successfully",
        type: "milestone",
      });
    }

    // 5. Run failed
    if (currentState.status === "failed" && prevState?.status !== "failed") {
      onCheckpoint("Run failed", {
        description: "Task run encountered an error",
        type: "error",
      });
    }

    // Update previous state
    prevStateRef.current = currentState;
  }, [enabled, taskRun, onCheckpoint]);

  // Reset state when run ID changes
  useEffect(() => {
    prevStateRef.current = null;
    isFirstUpdateRef.current = true;
  }, [runId]);
}

export default useAutoCheckpoints;
