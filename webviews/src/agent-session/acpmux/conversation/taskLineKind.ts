// The task line row's kind and data (taskLines.ts makes it, TaskLine.tsx draws it), apart from
// both so the row model reads them without importing the sub-session call parsers.

/// A row added by turns.ts for a finished turn's started sub-sessions.
export const TASK_LINE = "taskLine";

export type StartedTask = { sessionId: string; name?: string; harness?: string };
