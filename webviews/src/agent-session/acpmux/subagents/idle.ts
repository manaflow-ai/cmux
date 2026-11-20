// How long a running subagent with no call open goes without a line, a call or new tokens before it
// reads Idle (subagentFold.ts `quietSince`, summary/SubagentStatusList.tsx `subagentStatus`): longer
// than a model's slowest first token, shorter than anyone would wait. Leo, 2026-11-02, on Session
// Info's subagents still "Running" two hours on: "but what's going on with these?"
export const IDLE_AFTER_MS = 3 * 60_000;
