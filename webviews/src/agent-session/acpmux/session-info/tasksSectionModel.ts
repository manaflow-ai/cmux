import { type StringKey, type Translate } from "../i18n";
import { type BackgroundCommand } from "./processes";

/// What a command's state says (the summary card's rows say the same, summary/SummaryTasks.tsx).
export const COMMAND_STATE: Record<BackgroundCommand["state"], StringKey> = {
  running: "bgTask.state.running",
  completed: "bgTask.state.completed",
  failed: "bgTask.state.failed",
  stopped: "bgTask.state.stopped",
  lost: "sessionInfo.tasks.lost",
};

/// How a finished command ended, as every surface says it (conversation/CommandEndCard.tsx): its exit
/// code once acpmux has one ("Exit code 0"), else its state's word.
export function commandEndWord(t: Translate, command: Pick<BackgroundCommand, "state" | "exitCode">): string {
  return command.state !== "running" && command.exitCode !== undefined
    ? t("shell.exit", { code: command.exitCode })
    : t(COMMAND_STATE[command.state]);
}
