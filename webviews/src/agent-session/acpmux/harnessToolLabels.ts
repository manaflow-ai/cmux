// A harness's own tools that have no file, command or MCP server to name them (Claude Code's
// ScheduleWakeup, SendMessage, TaskStop, ...): each reads as what it does, in a running form while it
// runs and a done form after ("Scheduling a wakeup", then "Scheduled a wakeup"), never as its raw
// CamelCase name. Leo, 2026-11-03: "instead of this kind of thing and SendMessage, we can just... make
// it look better? Scheduled Wakeup, sending message (like the sendmessage command is different from
// sent...)".
import type { StringKey, Translate } from "./i18n";
import type { AcpmuxActivity } from "./model";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

/// Each known tool's name and its strings' key stem (`tools.harness.<stem>.running` and `.done`).
export const HARNESS_TOOLS = {
  ScheduleWakeup: "scheduleWakeup",
  SendMessage: "sendMessage",
  TaskStop: "taskStop",
  TaskOutput: "taskOutput",
  CronCreate: "cronCreate",
  CronDelete: "cronDelete",
  CronList: "cronList",
  ListAgents: "listAgents",
  Monitor: "monitor",
  PushNotification: "pushNotification",
  EnterWorktree: "enterWorktree",
  ExitWorktree: "exitWorktree",
} as const;

export type HarnessToolName = keyof typeof HARNESS_TOOLS;

/// The skill a Claude Code Skill call loads (`rawInput.skill`, "cmux:acpmux" for a plugin's), or
/// undefined before its input arrives.
function skillName(tool: Tool): string | undefined {
  if (!tool.inputSummary?.includes("skill")) return undefined;
  try {
    const skill: unknown = (JSON.parse(tool.inputSummary) as { skill?: unknown } | null)?.skill;
    return typeof skill === "string" && skill.trim() ? skill.trim().replace(/^\//, "") : undefined;
  } catch {
    return undefined;
  }
}

/// The friendly label of a known harness tool named `name` (its title, or its row's text), or
/// undefined for any other name. The Skill tool reads with the skill it loads ("Used the
/// code-review skill"), the row the 11-05 audit found still drawn as a bare "Skill".
export function harnessToolLabel(t: Translate, tool: Tool, name: string): string | undefined {
  const running = tool.status === "pending" || tool.status === "in_progress";
  if (name.trim() === "Skill") {
    const skill = skillName(tool);
    if (skill) return t(running ? "tools.skill.running" : "tools.skill.done", { name: skill });
    return t(running ? "tools.skill.runningUnnamed" : "tools.skill.doneUnnamed");
  }
  const stem = (HARNESS_TOOLS as Record<string, string>)[name.trim()];
  if (!stem) return undefined;
  return t(`tools.harness.${stem}.${running ? "running" : "done"}` as StringKey);
}
