// The agent's todo list (cx-ncc.80, Claude parity): an ACP `plan` update (Claude's TodoWrite through
// acpmux, or Codex's own plan) draws as a quiet card, and a turn's later updates redraw its one list
// (direct.ts). As in Claude desktop, the marks carry the state: a filled check is done, a thin
// spinner runs and a dashed circle waits, with no heading, strike-through or bold. While the turn
// runs the list is pinned under its latest message (turns.ts shapeLiveTurn, Leo, 2026-11-03: "yo wtf
// i want this kind of feature in cmux-next too", on Claude Code desktop's pinned task list), and a
// step's change fades in place. Once the turn ends the card folds, where it stood, to its one
// "3 of 3 tasks done" line, which opens the list again; a step left in progress stops spinning. A
// screen reader hears the progress and each state. An earlier turn's list with steps left, pinned
// under a running turn that has none of its own yet, says it is from before the person's last
// message, as Claude desktop's does, and nothing in it spins (turns.ts `earlierTurnPlan`).
// Memoized on its immutable entries: tokens streaming elsewhere in the turn never redraw it.
import { memo, useCallback, useState } from "react";
import { useT, type StringKey } from "../i18n";
import type { AcpmuxPlanEntry } from "../model";
import { Check, ChevronRight, Spinner } from "./icons";
import { planOpen, setPlanOpen } from "./planOpen";

const STATUS: Record<AcpmuxPlanEntry["status"], StringKey> = {
  completed: "plan.status.completed",
  in_progress: "plan.status.inProgress",
  pending: "plan.status.pending",
};

export const PlanList = memo(function PlanList({
  entries,
  ended = false,
  earlier = false,
  id,
}: {
  entries: readonly AcpmuxPlanEntry[];
  ended?: boolean;
  /// An earlier turn's list, shown under the running turn until the agent writes a new one.
  earlier?: boolean;
  /// The plan row's id: an ended list the reader opened stays open when its row draws again.
  id?: string;
}) {
  const t = useT();
  const [open, setOpen] = useState(() => planOpen(id));
  const toggle = useCallback(() => {
    setOpen((was) => {
      setPlanOpen(id, !was);
      return !was;
    });
  }, [id]);
  const done = entries.filter((entry) => entry.status === "completed").length;
  const progress =
    entries.length === 1 ? t("plan.progress.one", { done }) : t("plan.progress", { done, total: entries.length });
  const folded = ended && !open;
  return (
    <div
      className="cv-plan"
      data-ended={ended ? "" : undefined}
      data-earlier={earlier && !ended ? "" : undefined}
      data-folded={folded ? "" : undefined}
    >
      {earlier && !ended && (
        // Drawn and heard: the list is the agent's last plan, not the running turn's.
        <div className="cv-plan__earlier">{t("plan.earlier")}</div>
      )}
      {ended ? (
        // The finished list's one line: the progress, a chevron that opens the steps.
        <button type="button" className="cv-plan__summary" aria-expanded={open} onClick={toggle}>
          <span className="cv-plan__mark" data-status={done === entries.length ? "completed" : "pending"} aria-hidden>
            {/* icon-scale-allow: the check sits inside the 12 px plan mark */}
            {done === entries.length && <Check size={10} />}
          </span>
          <span className="cv-plan__text">{progress}</span>
          <ChevronRight size={14} className={`cv-rotor cv-plan__chevron${open ? " is-open" : ""}`} />
        </button>
      ) : (
        // Heard, not drawn: the marks show the progress.
        <div className="cv-plan__progress cv-plan__state">{progress}</div>
      )}
      {!folded && (
        <ul className="cv-plan__items">
          {entries.map((entry, index) => (
            // Items have no ids, and a list only grows or changes status in place.
            // oxlint-disable-next-line react/no-array-index-key -- the plan's order is its identity.
            <li key={index} className="cv-plan__item" data-status={entry.status}>
              <span className="cv-plan__mark" aria-hidden="true">
                {/* icon-scale-allow: the check sits inside the 12 px plan mark */}
                {entry.status === "completed" && <Check size={10} />}
                {/* The step at work turns the one shared spinner (icons.tsx), never a ring of its own. */}
                {entry.status === "in_progress" && !ended && !earlier && <Spinner size={12} />}
              </span>
              <span className="cv-plan__text">{entry.content}</span>
              {/* The marks are drawn only; a screen reader hears the state. */}
              <span className="cv-plan__state">{t(STATUS[entry.status])}</span>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
});
