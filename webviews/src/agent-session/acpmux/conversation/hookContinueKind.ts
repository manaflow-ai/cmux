// The hook note's row kind and data (direct.ts and rows/adapter.ts make it from acpmux's
// `hook_feedback`, HookContinueNote.tsx draws it), apart from both so the row model reads them alone.

/// A row where a Stop hook blocked the agent's stop and the turn went on with its reason.
export const HOOK_CONTINUE = "hookContinue";

/// The hook's ask: its event (`Stop`, `SubagentStop`), its command when Claude Code named it, and
/// the reason the agent was given to go on.
export type HookContinue = { event: string; hookName?: string; reason: string };

/// The note of an acpmux `hook_feedback` update (or a row store notice's fields), or none.
export function hookContinueOf(update: Record<string, unknown> | undefined): HookContinue | undefined {
  if (!update) return undefined;
  const reason = typeof update.text === "string" ? update.text.trim() : "";
  const event = typeof update.hookEvent === "string" && update.hookEvent ? update.hookEvent : "Stop";
  const hookName = typeof update.hookName === "string" && update.hookName ? update.hookName : undefined;
  return { event, reason, ...(hookName ? { hookName } : {}) };
}
