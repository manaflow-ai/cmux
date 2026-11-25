// Session Info's Progress: the agent's plan, live (Leo, 2026-11-04: "A live Progress section in
// Session Info (medium). Today the plan only shows in the transcript." and "yeah but the big point is
// ofc the styling and theming and spacing too"). It reads the same plan the transcript's todo list
// draws (conversation/PlanList.tsx): the chat's latest ACP `plan` row (Claude's TodoWrite, Codex's
// plan, direct.ts), so a step the agent ticks changes here as it does there. The transcript's list
// stays as it is.
//
// Each step is a row on the panel's grid: its mark in the icon column, its words on the text column,
// wrapping rather than cut, as the steps are sentences. The marks are the todo list's: a filled check
// is done, the one shared spinner runs, a dashed ring waits, and a step left in progress once the turn
// ended is a plain ring, never a spinner frozen mid-turn. A step's change fades in place (colours
// only), so nothing in the panel moves. With no plan the section is not drawn (SessionInfo.tsx).
import { memo } from "react";
import { useScrollEdges } from "../../../ui/scrollEdges";
import { Check, Spinner } from "../conversation/icons";
import { useT, type StringKey } from "../i18n";
import type { AcpmuxPlanEntry } from "../model";
import { type SessionInfoPlan } from "./progressSectionModel";
const STATUS: Record<AcpmuxPlanEntry["status"], StringKey> = {
  completed: "plan.status.completed",
  in_progress: "plan.status.inProgress",
  pending: "plan.status.pending",
};

export const ProgressSection = memo(function ProgressSection({ plan }: { plan: SessionInfoPlan }) {
  const t = useT();
  const edges = useScrollEdges();
  return (
    <div ref={edges} className="acpmux-session-info-scroll ui-scroll-edge-fade">
      <ol className="acpmux-session-info-list acpmux-session-info-progress" data-ended={plan.ended ? "" : undefined}>
        {plan.entries.map((entry, index) => (
          // Steps have no ids, and a plan only grows or changes a step's status in place.
          // oxlint-disable-next-line react/no-array-index-key -- the plan's order is its identity.
          <li key={index} className="acpmux-session-info-progress__step" data-status={entry.status}>
            <span className="acpmux-session-info-progress__mark" aria-hidden="true">
              {entry.status === "in_progress" && !plan.ended ? (
                // The step at work turns the one shared spinner (icons.tsx), never a ring of its own.
                <Spinner size={12} />
              ) : (
                <span className="acpmux-session-info-progress__ring">
                  {/* icon-scale-allow: the check sits inside the 12 px step mark, as the todo list's */}
                  {entry.status === "completed" && <Check size={10} />}
                </span>
              )}
            </span>
            <span className="acpmux-session-info-progress__text">{entry.content}</span>
            {/* The marks are drawn only; a screen reader hears the state. */}
            <span className="acpmux-session-info-sr-only">{t(STATUS[entry.status])}</span>
          </li>
        ))}
      </ol>
    </div>
  );
});
