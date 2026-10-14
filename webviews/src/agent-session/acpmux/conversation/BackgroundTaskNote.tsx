// A background shell's end in the transcript (cx-ncc.84, Claude parity): Claude's Bash calls that
// run in the background end with acpmux's `background_task_update`, noted where it happened as
// Claude desktop notes it, "Background task stopped · <reason>: <command>". It is drawn as a tool
// row, in their font, height and rhythm, with nothing on hover (Leo 2026-10-13).
import { useT } from "../i18n";
import type { AcpmuxBackgroundTask } from "../model";
import { TerminalSquare } from "./icons";

export function BackgroundTaskNote({ task }: { task: AcpmuxBackgroundTask }) {
  const t = useT();
  const { command, state, reason } = task;
  const text =
    state === "completed"
      ? t("bgTask.completed", { command })
      : state === "failed"
        ? t("bgTask.failed", { command })
        : reason
          ? t("bgTask.stoppedReason", { reason, command })
          : t("bgTask.stopped", { command });
  return (
    <div className="cv-tools">
      <div className="cv-tool cv-bgtask" data-state={state}>
        <span className="cv-tool__icon">
          <TerminalSquare />
        </span>
        <span className="cv-tool__text">{text}</span>
      </div>
    </div>
  );
}
