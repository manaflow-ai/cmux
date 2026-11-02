// The agent's todo list (cx-ncc.80, Claude parity): an ACP `plan` update (Claude's TodoWrite through
// acpmux, or Codex's own plan) draws as a quiet card, and a turn's later updates redraw its one list
// (direct.ts). As in Claude desktop, the marks carry the state: a filled check is done, a thin
// spinner runs and a dashed circle waits, with no heading, strike-through or bold. Once the turn
// ends a step left in progress stops spinning. A screen reader hears the progress and each state.
// Memoized on its immutable entries: tokens streaming elsewhere in the turn never redraw it.
import { memo } from "react";
import { useT, type StringKey } from "../i18n";
import type { AcpmuxPlanEntry } from "../model";
import { Check } from "./icons";

const STATUS: Record<AcpmuxPlanEntry["status"], StringKey> = {
  completed: "plan.status.completed",
  in_progress: "plan.status.inProgress",
  pending: "plan.status.pending",
};

export const PlanList = memo(function PlanList({
  entries,
  ended = false,
}: {
  entries: readonly AcpmuxPlanEntry[];
  ended?: boolean;
}) {
  const t = useT();
  const done = entries.filter((entry) => entry.status === "completed").length;
  return (
    <div className="cv-plan" data-ended={ended ? "" : undefined}>
      {/* Heard, not drawn: the marks show the progress. */}
      <div className="cv-plan__progress cv-plan__state">
        {entries.length === 1 ? t("plan.progress.one", { done }) : t("plan.progress", { done, total: entries.length })}
      </div>
      <ul className="cv-plan__items">
        {entries.map((entry, index) => (
          // Items have no ids, and a list only grows or changes status in place.
          // oxlint-disable-next-line react/no-array-index-key -- the plan's order is its identity.
          <li key={index} className="cv-plan__item" data-status={entry.status}>
            <span className="cv-plan__mark" aria-hidden="true">
              {entry.status === "completed" && <Check size={10} />}
            </span>
            <span className="cv-plan__text">{entry.content}</span>
            {/* The marks are drawn only; a screen reader hears the state. */}
            <span className="cv-plan__state">{t(STATUS[entry.status])}</span>
          </li>
        ))}
      </ul>
    </div>
  );
});
