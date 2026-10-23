// A background shell's end in the transcript (cx-ncc.84, Claude parity), when the call that started
// it is not in the transcript (a page not loaded): a shell whose call is there ends on that call's
// own "Ran" row instead (BackgroundMark.tsx, direct.ts `markBackgroundCall`). Noted where it ended
// as Claude desktop notes it, "Background task stopped · <reason>: <command>", the command cut to
// its working step (shortCommand.ts). It is drawn as a tool row, in their font, height and rhythm,
// with nothing on hover (Leo 2026-10-13).
//
// A click opens it in place, as a command row opens (CommandRow.tsx): the turn's fold motion and
// rotating chevron, the clicked line held where it is (foldAnchor.ts), and under it the Shell card
// with the whole command, the end of what it printed and its exit code when acpmux knows them
// (backgroundTaskOutput.ts), then the harness's own words on its end and Open in terminal. A click
// never opens anything else (Leo 2026-10-21: it replaced the window with an empty terminal); only
// Open in terminal opens the task's terminal beside the chat (background-task-terminal-DESIGN.md).
import { useId } from "react";
import { useT } from "../i18n";
import type { AcpmuxBackgroundTask } from "../model";
import { openProcessTerminal } from "../processTerminal";
import { useBackgroundTaskOutput } from "./backgroundTaskOutput";
import { useAnchoredCollapse } from "./useAnchoredCollapse";
import { ChevronRight, TerminalSquare } from "./icons";
import { ShellBlock } from "./ShellBlock";
import { shortCommand } from "./shortCommand";
import { useTranscriptDisclosure } from "./transcriptDisclosure";

export function BackgroundTaskNote({ task }: { task: AcpmuxBackgroundTask }) {
  const t = useT();
  const { state, reason } = task;
  const [open, setOpen] = useTranscriptDisclosure(`bgtask:${task.toolCallId}`);
  const fold = useAnchoredCollapse({ open, onOpenChange: setOpen });
  const detailsId = useId();
  const read = useBackgroundTaskOutput(task.toolCallId, open);
  const command = shortCommand(task.command);
  const text =
    state === "completed"
      ? t("bgTask.completed", { command })
      : state === "failed"
        ? t("bgTask.failed", { command })
        : reason
          ? t("bgTask.stoppedReason", { reason, command })
          : t("bgTask.stopped", { command });
  // The event's exit code (Codex sends one), else the registry's.
  const exitCode = task.exitCode ?? read.exitCode;
  // What the harness said of its end beyond the row's words: Claude Code's summary, else a reason the
  // row does not already name (it names a stop's).
  const detail = task.summary || (state === "stopped" ? undefined : reason);
  return (
    <div className="cv-tools">
      <button
        type="button"
        className="cv-tool cv-bgtask is-toggle"
        data-state={state}
        aria-expanded={open}
        aria-controls={open ? detailsId : undefined}
        ref={fold.headerRef}
        onClick={fold.toggle}
      >
        <span className="cv-tool__icon">
          <TerminalSquare />
        </span>
        <span className="cv-tool__text">{text}</span>
        <ChevronRight
          size={14}
          strokeWidth={1.2}
          className={`cv-tool__chevron cv-rotor${open ? " is-open" : " is-hover"}`}
        />
      </button>
      {fold.present && (
        <div {...fold.bodyProps}>
          <ShellBlock
            id={detailsId}
            command={task.command}
            output={read.output?.replace(/\n$/, "")}
            cut={read.cut}
            exitCode={exitCode}
            footer={
              <div className="cv-bgtask__foot">
                {detail && <span className="cv-bgtask__detail">{detail}</span>}
                {task.toolCallId && (
                  <button
                    type="button"
                    className="cv-bgtask__open"
                    onClick={() => void openProcessTerminal(task.toolCallId)}
                  >
                    <TerminalSquare />
                    {t("shell.openInTerminal")}
                  </button>
                )}
              </div>
            }
          />
        </div>
      )}
    </div>
  );
}
