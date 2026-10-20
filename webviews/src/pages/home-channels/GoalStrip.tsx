import { useMemo } from "react";
import type { Strings } from "../shared/i18n";
import { RunMark, useNow } from "./RunCard";
import { useRunEntry, type RunBook } from "./runs";
import { projectGoal } from "./goal";
import type { HomeRun } from "./types";

export function GoalStrip({
  book,
  conversation,
  strings,
  onOpen,
}: {
  book: RunBook;
  conversation: string;
  strings: Strings;
  onOpen(run: HomeRun): void;
}) {
  const entry = useRunEntry(book, (current) => current.goalEntry(conversation));
  const running = entry?.run.status === "running";
  const now = useNow(running);
  const goal = useMemo(() => projectGoal(entry ? [entry] : [], now), [entry, now]);
  if (!goal) return null;
  const statusKey = goal.state === "stalled" ? "stale" : goal.state === "working" ? "running" : "failed";
  const title = goal.title || strings.t("run.title");
  return (
    <output
      className={`lg-goal-strip ${goal.state}`}
      aria-label={title}
      aria-live="polite"
      aria-busy={goal.state === "working"}
    >
      <RunMark status={statusKey} />
      <span className="lg-goal-copy">
        <span className="lg-goal-state">{strings.t(`run.status.${statusKey}`)}</span>
        <strong className="lg-goal-title" dir="auto">
          {title}
        </strong>
        {goal.detail && (
          <span className="lg-goal-detail" dir="auto">
            {goal.detail}
          </span>
        )}
      </span>
      <button type="button" className="lg-link-button lg-goal-open" onClick={() => onOpen(goal.run)}>
        {strings.t("run.open")}
      </button>
    </output>
  );
}
