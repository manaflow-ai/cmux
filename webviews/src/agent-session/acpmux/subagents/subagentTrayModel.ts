import { type Translate } from "../i18n";
import type { AcpmuxPlanEntry } from "../model";
import { planStepTitle } from "../conversation/planStepText";

/// The header's plan part: "2 of 5 · Write the tests", the step at work (else the next one waiting)
/// after the progress, by its title line (planStepText.ts); a list all done reads only its progress.
export function planHead(t: Translate, plan: readonly AcpmuxPlanEntry[]): string {
  const done = plan.filter((entry) => entry.status === "completed").length;
  const progress = t("plan.hat", { done, total: plan.length });
  const step = plan.find((entry) => entry.status === "in_progress") ?? plan.find((entry) => entry.status === "pending");
  return step ? `${progress} · ${planStepTitle(step.content)}` : progress;
}

/// The header's plan part for an earlier turn's list: "Earlier plan · 2 of 5", naming no step, as
/// none is at work in this turn.
export function earlierPlanHead(t: Translate, plan: readonly AcpmuxPlanEntry[]): string {
  const done = plan.filter((entry) => entry.status === "completed").length;
  return `${t("plan.earlier.short")} · ${t("plan.hat", { done, total: plan.length })}`;
}

/// What a plan-only header draws in its icon slot and which clock it shows. While the chat's turn runs,
/// the shared spinner and the turn's running time, as Claude's and Codex's apps show a working turn
/// beside its task list; between turns the Plan mode mark, quiet, with no time. cmux#51039 (the person,
/// 2026-11-22, on "0 of 6 · Read prior fixes" with no spinner anywhere: "this is confusing i wasn't sure
/// if this workspace was doing anything").
export function planHeadMark({ working, turnSince }: { working: boolean; turnSince?: number }): {
  spins: boolean;
  since: number | undefined;
} {
  return working ? { spins: true, since: turnSince } : { spins: false, since: undefined };
}
