import { usePageNow } from "../../ui/pageClock";
import type { TaskGoal } from "./goal";
import { usePaneLanguage, useT } from "./i18n";
import { loopNextText } from "./taskGoalStripModel";

/** What a Claude Code /loop says between its runs, wherever it is drawn (TaskGoalStrip.tsx
 *  `LoopStrip`, LoopQuiet.tsx): `label` is the sentence ("Checking back in 15 min.", "Repeats every
 *  5 minutes"), `short` the time alone ("in 15 min.", "every 5 minutes"), `tooltip` the agent's own
 *  wake prompt and reason, never shown inline (cmux#38051). */
export function useLoopLabel(goal: TaskGoal, now: () => number) {
  const t = useT();
  const lang = usePaneLanguage();
  // The page's shared second clock (ui/pageClock.ts), only while the next run is ahead: the render
  // after that time passes stops it, as does unmounting, and a hidden page runs no timer.
  // The caption reads the newer of the clock's sample and the time now: a render between the run
  // time and the clock's next tick stops the clock, and its older sample would keep the countdown up.
  const at = goal.nextRunAt;
  const current = now();
  const time = usePageNow(at !== undefined && current < at && !goal.schedule, now);
  const next = at === undefined ? undefined : loopNextText(Math.max(time, current), at, lang);
  // An interval loop says its schedule ("Repeats every 5 minutes"), a self-wake when it checks back.
  const label = goal.schedule
    ? t("goal.loopSchedule", { schedule: goal.schedule })
    : next
      ? t("goal.loopNext", { when: next })
      : t("goal.loop");
  const prompt = goal.autonomous ? undefined : goal.objective.trim() || undefined;
  const tooltip = [prompt ?? t("goal.loopAutonomous"), goal.reason].filter(Boolean).join("\n\n");
  return { label, short: goal.schedule ?? next ?? label, prompt, tooltip };
}
