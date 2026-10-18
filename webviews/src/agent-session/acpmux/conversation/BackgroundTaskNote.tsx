// A background shell's end in the transcript (cx-ncc.84, Claude parity): Claude's Bash calls that
// run in the background end with acpmux's `background_task_update`, noted where it happened as
// Claude desktop notes it, "Background task stopped · <reason>: <command>". It is drawn as a tool
// row, in their font, height and rhythm; live process rows add tail and stop affordances.
import { useState } from "react";
import { useT } from "../i18n";
import type { AcpmuxBackgroundTask } from "../model";
import { TerminalSquare } from "./icons";

export function BackgroundTaskNote({ task }: { task: AcpmuxBackgroundTask }) {
  const t = useT();
  const [output, setOutput] = useState<string>();
  const [busy, setBusy] = useState(false);
  const { command, state, reason } = task;
  const text =
    state === "running"
      ? `${t("bgTask.state.running")}: ${command}`
      : state === "completed"
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
        {task.processId && task.onTail && (
          <button
            type="button"
            className="cv-tool__detail"
            disabled={busy}
            onClick={() => {
              if (output !== undefined) {
                setOutput(undefined);
                return;
              }
              setBusy(true);
              void task
                .onTail!()
                .then((tail) => {
                  try {
                    const bytes = Uint8Array.from(atob(tail.data), (char) => char.charCodeAt(0));
                    setOutput(new TextDecoder().decode(bytes));
                  } catch {
                    setOutput(tail.data);
                  }
                })
                .catch(() => setOutput(t("shell.failed")))
                .finally(() => setBusy(false));
            }}
          >
            {output === undefined ? t("shell.showAll") : t("shell.showLess")}
          </button>
        )}
        {task.state === "running" && task.onStop && (
          <button
            type="button"
            className="cv-tool__detail"
            disabled={busy}
            onClick={() => {
              setBusy(true);
              void task
                .onStop!()
                .catch(() => undefined)
                .finally(() => setBusy(false));
            }}
          >
            {t("shell.stop")}
          </button>
        )}
      </div>
      {output !== undefined && <pre className="cv-tool-output">{output}</pre>}
    </div>
  );
}
