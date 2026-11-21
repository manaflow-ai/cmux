import { type StringKey } from "../i18n";
import { type BackgroundCommand } from "./processes";

/// What a command's state says (the summary card's rows say the same, summary/SummaryTasks.tsx).
export const COMMAND_STATE: Record<BackgroundCommand["state"], StringKey> = {
  running: "bgTask.state.running",
  completed: "bgTask.state.completed",
  failed: "bgTask.state.failed",
  stopped: "bgTask.state.stopped",
  lost: "sessionInfo.tasks.lost",
};
