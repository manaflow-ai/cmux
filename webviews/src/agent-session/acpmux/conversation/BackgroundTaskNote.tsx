// A background shell's end in the transcript (cx-ncc.84, Claude parity): Claude's Bash calls that
// run in the background end with acpmux's `background_task_update`, noted where it happened as
// Claude desktop notes it, "Background task stopped · <reason>: <command>".
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxBackgroundTask } from "../model";

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
    <div className="cv-bgtask" data-state={state} title={command}>
      <Icon name="terminal" size={13} />
      <span className="cv-bgtask__text">{text}</span>
    </div>
  );
}
