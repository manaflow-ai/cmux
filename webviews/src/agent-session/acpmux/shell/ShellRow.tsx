// A shell mode command's block in the transcript: the command, its status in one fixed slot
// (Stop while it runs, then its exit status and time), the end of its output (all of it once
// opened), and "Open in terminal", which types the command into a new terminal tab in the same
// folder without running it.
import { createContext, useContext } from "react";
import { useT } from "../i18n";
import type { AcpmuxRow } from "../model";
import { Check, Spinner } from "../conversation/icons";
import type { ShellRun } from "./shellRuns";

/// Lines of output a closed block shows: the last ones, where results and errors are.
export const SHELL_COLLAPSED_LINES = 8;

export type ShellActions = { stop(id: string): void; openInTerminal(run: ShellRun): void };
export const ShellActionsContext = createContext<ShellActions | undefined>(undefined);

export function ShellRow({
  row,
  expanded,
  onToggleActivity,
}: {
  row: AcpmuxRow;
  expanded: boolean;
  onToggleActivity: (id: string) => void;
}) {
  const t = useT();
  const actions = useContext(ShellActionsContext);
  const run = row.shell;
  if (!run) return null;
  const output = run.output.replace(/\n$/, "");
  const lines = output ? output.split("\n") : [];
  const long = lines.length > SHELL_COLLAPSED_LINES;
  const shown = long && !expanded ? lines.slice(-SHELL_COLLAPSED_LINES) : lines;
  const seconds = run.endedAt !== undefined ? (run.endedAt - run.startedAt) / 1000 : undefined;
  const time = seconds === undefined ? "" : seconds < 10 ? `${seconds.toFixed(1)}s` : `${Math.round(seconds)}s`;
  return (
    <div className="acpmux-shell-block" data-status={run.status}>
      <div className="acpmux-shell-block-head">
        <span className="acpmux-shell-block-glyph" aria-hidden="true">
          !
        </span>
        <code className="acpmux-shell-block-command" title={run.command}>
          {run.command}
        </code>
        <span className="acpmux-shell-block-status">
          {run.status === "running" ? (
            <button type="button" className="acpmux-shell-block-stop" onClick={() => actions?.stop(run.id)}>
              <Spinner size={12} />
              {t("shell.stop")}
              <kbd>⌃C</kbd>
            </button>
          ) : (
            <>
              {run.status === "done" ? (
                <span className="acpmux-shell-block-ok">
                  <Check size={14} />
                  <span className="visually-hidden">{t("shell.succeeded")}</span>
                </span>
              ) : (
                <span className="acpmux-shell-block-failed">
                  {run.status === "stopped"
                    ? t("shell.stopped")
                    : run.exitCode !== undefined
                      ? t("shell.exit", { code: run.exitCode })
                      : t("shell.failed")}
                </span>
              )}
              {time && <span className="acpmux-shell-block-time">{time}</span>}
            </>
          )}
        </span>
        <button type="button" className="acpmux-shell-block-open" onClick={() => actions?.openInTerminal(run)}>
          {t("shell.openInTerminal")}
        </button>
      </div>
      {(shown.length > 0 || run.error) && (
        <pre className="acpmux-shell-block-output selectable">
          {(run.truncated || (long && !expanded)) && (
            <span className="acpmux-shell-block-cut" aria-hidden="true">
              …
            </span>
          )}
          {shown.join("\n")}
          {run.error && <span className="acpmux-shell-block-error">{run.error}</span>}
        </pre>
      )}
      {long && (
        <button
          type="button"
          className="acpmux-shell-block-more"
          aria-expanded={expanded}
          onClick={() => onToggleActivity(row.id)}
        >
          {expanded ? t("shell.showLess") : t("shell.showAll")}
        </button>
      )}
    </div>
  );
}
