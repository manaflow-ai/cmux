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

/// The friendly label of a known harness tool named `name` (its title, or its row's text), or
/// undefined for any other name.
export function harnessToolLabel(t: Translate, tool: Tool, name: string): string | undefined {
  const stem = (HARNESS_TOOLS as Record<string, string>)[name.trim()];
  if (!stem) return undefined;
  const running = tool.status === "pending" || tool.status === "in_progress";
  return t(`tools.harness.${stem}.${running ? "running" : "done"}` as StringKey);
}
