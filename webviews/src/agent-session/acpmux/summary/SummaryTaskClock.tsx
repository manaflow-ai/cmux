import { createContext, useContext, type ReactNode } from "react";
import { formatDuration } from "../conversation/turns";
import { useNow } from "../subagents/SubagentGroup";

// One page clock subscription for this entire Summary, however many tasks it lists.
// Only elapsed labels consume its value: finished rows are never revisited on a tick.
const TaskNow = createContext(0);

export function SummaryTaskClock({ live, children }: { live: boolean; children: ReactNode }) {
  const now = useNow(live);
  return <TaskNow.Provider value={now}>{children}</TaskNow.Provider>;
}

export function RunningElapsed({ startedAt }: { startedAt: number }) {
  const now = useContext(TaskNow);
  return formatDuration(Math.max(0, now - startedAt));
}
