// The agent's todo list (cx-ncc.80, Claude parity): an ACP `plan` update (Claude's TodoWrite through
// acpmux, or Codex's own plan) draws as a checklist under its progress, and a turn's later updates
// redraw its one list (direct.ts). Done items are struck through, the one in progress is bold; a
// screen reader hears each item's state.
import { useT, type StringKey } from "../i18n";
import type { AcpmuxPlanEntry } from "../model";
import { Check } from "./icons";

const STATUS: Record<AcpmuxPlanEntry["status"], StringKey> = {
  completed: "plan.status.completed",
  in_progress: "plan.status.inProgress",
  pending: "plan.status.pending",
};

export function PlanList({ entries }: { entries: readonly AcpmuxPlanEntry[] }) {
  const t = useT();
  const done = entries.filter((entry) => entry.status === "completed").length;
  return (
    <div className="cv-plan">
      <div className="cv-plan__heading">
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
            {/* The marks and strike-through are drawn only; a screen reader hears the state. */}
            <span className="cv-plan__state">{t(STATUS[entry.status])}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}
