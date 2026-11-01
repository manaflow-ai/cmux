// A shell call's life in the background, at the end of its "Ran" row (CommandRow.tsx, ToolRow.tsx):
// the running rows' mark while it runs there, then how it ended, as a call that ran in the
// foreground says it: a check, "Failed", or "Stopped" with the agent's reason on hover. acpmux's
// `background_task_update` changes this row, in whichever turn it sits; it never adds a second one
// (direct.ts `markBackgroundCall`, Leo 2026-10-20).
import { useT } from "../i18n";
import type { AcpmuxBackgroundState } from "../model";
import { Check, Spinner } from "./icons";

export function BackgroundMark({
  background,
  showActivity = true,
}: {
  background: AcpmuxBackgroundState;
  showActivity?: boolean;
}) {
  const t = useT();
  switch (background.state) {
    case "running": {
      const label = t("tools.background.running");
      return (
        // tooltip-allow: the spinner is the row's only visible mark; its label is for screen readers only
        <span className="cv-command__bg-state" title={label} data-state="running">
          {showActivity && <Spinner size={12} />}
          <span className="cv-command__bg-label" data-find-skip>
            {label}
          </span>
        </span>
      );
    }
    case "failed":
      return (
        <span className="cv-command__failed" data-state="failed">
          {t("tools.failed")}
        </span>
      );
    case "stopped":
      return (
        // tooltip-allow: the row shows only "Stopped"; the agent's reason is on hover, not on screen
        <span className="cv-command__stopped" title={background.reason} data-state="stopped">
          {t("bgTask.state.stopped")}
        </span>
      );
    default:
      return <Check size={14} className="cv-command__ok" />;
  }
}
