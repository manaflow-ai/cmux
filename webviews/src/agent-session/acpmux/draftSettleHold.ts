// The last launch's copy (firstPaint.ts) shows the chat's draft, so a chat read from a kept tail waits for
// the composer's read of its saved draft (Composer `onDraftSettled`) before the page says it drew the chat,
// at most DRAFT_SETTLE_HOLD_MS: a composer that never mounts, or a read that never answers, ends the wait.
//
// The hold is armed only while the draft is still out. A chat whose draft settled before or with its rows
// (every chat switch, where the composer reads the draft from memory) arms no timer, and one that settles
// during the hold clears it: before, every chat read armed a 2 s timer that woke the pane at rest and
// rendered it once more (bench/chat-switch.bench.ts, chat_switch.*.idle_wakeups). Leo, 2026-11-12:
// "infinite everything feels like nothing".
import { useEffect, useState } from "react";

/// The longest the last launch's copy waits on the chat's draft read once its rows are in (firstPaint.ts).
export const DRAFT_SETTLE_HOLD_MS = 2_000;

/// The chat whose wait for its draft ran out: `rowsReadFor` (the chat whose rows are in) once
/// DRAFT_SETTLE_HOLD_MS passed with `draftSettled` (the chat whose draft the composer read) not naming it.
export function useDraftWaitOver(
  rowsReadFor: string | undefined,
  draftSettled: string | undefined,
): string | undefined {
  const [draftWaitOver, setDraftWaitOver] = useState<string>();
  const waiting = rowsReadFor !== undefined && draftSettled !== rowsReadFor ? rowsReadFor : undefined;
  useEffect(() => {
    if (waiting === undefined) return;
    const timer = window.setTimeout(() => setDraftWaitOver(waiting), DRAFT_SETTLE_HOLD_MS);
    return () => window.clearTimeout(timer);
  }, [waiting]);
  return draftWaitOver;
}
