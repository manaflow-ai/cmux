const PLAN_MODE_MENTION = "[$plan](skill://plan)";

export function promptTextWithPlanMode(input: string, isPlanMode: boolean): string {
  if (!isPlanMode || inputHasPlanMode(input)) {
    return input;
  }
  return input.trim().length > 0 ? `${input}\n\n${PLAN_MODE_MENTION}` : PLAN_MODE_MENTION;
}

function inputHasPlanMode(input: string): boolean {
  return input.includes("skill://plan") || /(?:^|\s)\$plan(?:\s|$)/.test(input);
}
