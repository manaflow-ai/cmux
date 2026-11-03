// The sub-sessions a finished turn started, kept in sight once its work folds (taskLine.experiment.ts):
// a `start_session` call of the cmux-subsessions tools (subsessionCalls.ts) that named the session it
// started. The line itself (TaskLine.tsx) reads each one's title and state live from the session list.
import type { AcpmuxRow } from "../model";
import { subsessionCall } from "./subsessionCalls";
import type { StartedTask } from "./taskLineKind";

export { TASK_LINE, type StartedTask } from "./taskLineKind";

/// Whether an activity row holds a sub-session start that named its session.
export function startsTask(row: AcpmuxRow): boolean {
  return row.kind === "activity" && (row.items ?? []).some((item) => startOf(item.tool) !== undefined);
}

/// The sub-sessions `rows` started, in order, each once.
export function startedTasks(rows: readonly AcpmuxRow[]): StartedTask[] {
  const tasks: StartedTask[] = [];
  const seen = new Set<string>();
  for (const row of rows) {
    if (row.kind !== "activity") continue;
    for (const item of row.items ?? []) {
      const start = startOf(item.tool);
      if (!start || seen.has(start.sessionId)) continue;
      seen.add(start.sessionId);
      tasks.push(start);
    }
  }
  return tasks;
}

function startOf(tool: Parameters<typeof subsessionCall>[0] | undefined): StartedTask | undefined {
  if (!tool) return undefined;
  const call = subsessionCall(tool);
  if (call?.tool !== "start" || !call.sessionId) return undefined;
  return {
    sessionId: call.sessionId,
    ...(call.name && { name: call.name }),
    ...(call.harness && { harness: call.harness }),
  };
}
