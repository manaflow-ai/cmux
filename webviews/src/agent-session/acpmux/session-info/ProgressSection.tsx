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
import type { AcpmuxPlanEntry, AcpmuxRow } from "../model";

/// The plan Progress draws: its steps, and whether the turn that wrote them has ended. `done` is the
/// steps already counted where the plan was published (liveProgress.ts), so no render counts again.
export type SessionInfoPlan = {
  readonly entries: readonly AcpmuxPlanEntry[];
  readonly ended: boolean;
  readonly done?: number;
};

const STATUS: Record<AcpmuxPlanEntry["status"], StringKey> = {
  completed: "plan.status.completed",
  in_progress: "plan.status.inProgress",
  pending: "plan.status.pending",
};

/// The chat's current plan: its latest plan row with steps. It has ended when the chat is not working
/// or a later prompt came after it (a new turn's plan is a new row, direct.ts). The scan walks back
/// from the newest row and stops at the first plan, so a chat with a plan reads only its last turn.
export function currentPlan(rows: readonly AcpmuxRow[], working: boolean): SessionInfoPlan | undefined {
  let later = false;
  for (let at = rows.length - 1; at >= 0; at -= 1) {
    const row = rows[at]!;
    if (row.kind === "plan" && row.plan && row.plan.length > 0) return { entries: row.plan, ended: !working || later };
    if (row.kind === "user") later = true;
  }
  return undefined;
}

/// How many of the plan's steps are done.
export const planDone = (plan: SessionInfoPlan) =>
  plan.done ?? plan.entries.filter((entry) => entry.status === "completed").length;

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
