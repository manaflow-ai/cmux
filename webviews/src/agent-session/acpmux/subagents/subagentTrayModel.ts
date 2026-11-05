import { type Translate } from "../i18n";
import type { AcpmuxPlanEntry } from "../model";

/// The header's plan part: "2 of 5 · Write the tests", the step at work (else the next one waiting)
/// after the progress; a list all done reads only its progress.
export function planHead(t: Translate, plan: readonly AcpmuxPlanEntry[]): string {
  const done = plan.filter((entry) => entry.status === "completed").length;
  const progress = t("plan.hat", { done, total: plan.length });
  const step = plan.find((entry) => entry.status === "in_progress") ?? plan.find((entry) => entry.status === "pending");
  return step ? `${progress} · ${step.content}` : progress;
}
