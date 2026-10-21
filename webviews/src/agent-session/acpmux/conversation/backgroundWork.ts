// The chat's work that goes on outside its turn: commands it runs in the background, chats its
// agent started and its subagents. The Inspector lists them (inspector/TasksSection.tsx,
// inspector/SubagentsSection.tsx), as the summary card does with the Inspector off; the running
// turn's line counts them (WorkingFor.tsx), and after the turn one compact row at the transcript's
// end says what still runs (BackgroundWorkRow.tsx). The commands themselves are
// inspector/processes.ts `backgroundCommands`.

/// The row kind App.tsx appends after the transcript's rows (BackgroundWorkRow.tsx).
export const BACKGROUND_WORK = "backgroundWork";

/// What still runs in the background: commands, started chats and subagents.
export type BackgroundCounts = { commands: number; sessions: number; agents: number };

export const NO_BACKGROUND: BackgroundCounts = { commands: 0, sessions: 0, agents: 0 };

/// Whether the transcript ends with the "Running in background" row: no turn runs (the running
/// turn's line counts the same work) and something still does.
export const backgroundRowShown = (working: boolean, counts: BackgroundCounts): boolean =>
  !working && counts.commands + counts.sessions + counts.agents > 0;
