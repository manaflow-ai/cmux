// One icon per kind of background task, so a wakeup, a cron job and a command never look alike
// (Leo, 2026-11-03: "every row has the same icon"). `web` names a cmux pack icon
// (icons/cmuxIcons.json), `native` the SF Symbol the App draws (native/tasks.ts).
export type TaskKind = "wakeup" | "cron" | "command";

export const TASK_ICONS: Record<TaskKind, { web: string; native: string }> = {
  // A clock: it waits for a time.
  wakeup: { web: "history", native: "clock" },
  // A repeat arrow: it runs on a schedule.
  cron: { web: "automation", native: "calendar.badge.clock" },
  command: { web: "terminal.prompt", native: "terminal.prompt" },
};
