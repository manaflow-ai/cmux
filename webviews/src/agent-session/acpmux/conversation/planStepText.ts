// A plan step's words as one surface draws them: its first line with words is the step's title, the
// lines after it its detail. A step written as several lines (an ops note: a title, then what it
// means) names itself by its title wherever one line names it (the composer hat, the turn's live
// line, a sidebar card), and a list draws the detail muted under it (PlanList.tsx PlanStep). acpmux's
// task-list summary names `current` and `next` the same way (task_list.rs `step_title`). Leo,
// 2026-11-22, on a two-line note drawn as a plan's step: "these shouldn't have been shown like that."

export function planStepParts(content: string): { title: string; detail: string } {
  const lines = content.split("\n");
  const at = lines.findIndex((line) => line.trim() !== "");
  if (at < 0) return { title: "", detail: "" };
  return {
    title: lines[at]!.trim(),
    detail: lines
      .slice(at + 1)
      .join("\n")
      .trim(),
  };
}

export function planStepTitle(content: string): string {
  return planStepParts(content).title;
}
