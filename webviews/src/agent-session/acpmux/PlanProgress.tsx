import { useLab } from "./labs";
import { useT } from "./i18n";
import type { AcpmuxRow } from "./model";
import "./planProgress.css";

/// Only the running turn's latest plan (Lucas 2026-10-18). A queued prompt starts no new turn.
export function runningPlan(rows: readonly AcpmuxRow[], working: boolean): AcpmuxRow | undefined {
  if (!working) return undefined;
  for (let index = rows.length - 1; index >= 0; index -= 1) {
    const row = rows[index]!;
    if (row.kind === "turnSummary" || (row.kind === "user" && !row.pending && !row.failed)) return undefined;
    if (row.kind === "plan") return row.plan?.length ? row : undefined;
  }
  return undefined;
}

/// One quiet line in the bottom stack; the transcript still owns the plan and its states.
export function PlanProgress({
  rows,
  working,
  onReveal,
}: {
  rows: readonly AcpmuxRow[];
  working: boolean;
  onReveal(rowId: string): void;
}) {
  const enabled = useLab("planProgress");
  const t = useT();
  const row = enabled ? runningPlan(rows, working) : undefined;
  if (!row?.plan) return null;
  const entries = row.plan;
  const current =
    entries.find((entry) => entry.status === "in_progress") ??
    entries.find((entry) => entry.status === "pending") ??
    entries[entries.length - 1]!;
  const done = entries.filter((entry) => entry.status === "completed").length;
  return (
    <button type="button" className="acpmux-plan-progress" onClick={() => onReveal(row.id)}>
      <span className="acpmux-plan-progress__text">{current.content}</span>
      <span className="acpmux-plan-progress__count">{t("find.count", { current: done, total: entries.length })}</span>
      <progress max={entries.length} value={done} aria-label={t("plan.progress", { done, total: entries.length })} />
    </button>
  );
}
