// A background shell's end in the transcript (cx-ncc.84, Claude parity), when the call that started
// it is not in the transcript (a page not loaded): a shell whose call is there ends on that call's
// own "Ran" row instead (BackgroundMark.tsx, direct.ts `markBackgroundCall`). Noted where it ended
// as Claude desktop notes it, "Background task stopped · <reason>: <command>", the command cut to
// its working step (shortCommand.ts), the whole of it on hover. It is drawn as a tool row, in their
// font, height and rhythm, with nothing on hover (Leo 2026-10-13). A click opens the task's terminal
// beside the chat: everything it printed, then how it ended (background-task-terminal-DESIGN.md).
import { useT } from "../i18n";
import type { AcpmuxBackgroundTask } from "../model";
import { openProcessTerminal } from "../processTerminal";
import { TerminalSquare } from "./icons";
import { shortCommand } from "./shortCommand";

export function BackgroundTaskNote({ task }: { task: AcpmuxBackgroundTask }) {
  const t = useT();
  const { state, reason } = task;
  const command = shortCommand(task.command);
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
      <button
        type="button"
        className="cv-tool cv-bgtask"
        data-state={state}
        /* tooltip-allow: the row shows the command cut to its working step; the whole command is on hover */
        title={task.command || undefined}
        onClick={() => void openProcessTerminal(task.toolCallId)}
      >
        <span className="cv-tool__icon">
          <TerminalSquare />
        </span>
        <span className="cv-tool__text">{text}</span>
      </button>
    </div>
  );
}
