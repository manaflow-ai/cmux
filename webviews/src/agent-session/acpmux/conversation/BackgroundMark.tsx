// A shell call's life in the background, at the end of its "Ran" row (CommandRow.tsx, ToolRow.tsx):
// while it runs there, no mark at the row's edge (its words shimmer, ShimmerText.tsx RowShimmer;
// Leo, 2026-11-03, on that spinner a whole column away from the row's words: "this is kinda weird
// looking"), only its state for screen readers; then how it ended, as a call that ran in the
// foreground says it: a check, "Failed", or "Stopped" with the agent's reason on hover. acpmux's
// `background_task_update` changes this row, in whichever turn it sits; it never adds a second one
// (direct.ts `markBackgroundCall`, Leo 2026-10-20).
import { useT } from "../i18n";
import type { AcpmuxBackgroundState } from "../model";

export function BackgroundMark({ background }: { background: AcpmuxBackgroundState }) {
  const t = useT();
  switch (background.state) {
    case "running": {
      const label = t("tools.background.running");
      return (
        // tooltip-allow: nothing shows at the row's edge while it runs; its label is for screen readers only
        <span className="cv-command__bg-state" title={label} data-state="running">
          <span className="cv-command__bg-label" data-find-skip>
            {label}
          </span>
        </span>
      );
    }
    // How it ended draws nothing at the row's edge: Codex marks no command as passed, failed or
    // stopped (Lawrence and Lucas, 2026-11-11 standup).
    default:
      return null;
  }
}
