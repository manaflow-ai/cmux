// The last launch's copy (firstPaint.ts) shows the chat's draft, so a chat read from a kept tail waits for
// the composer's read of its saved draft (Composer `onDraftSettled`) before the page says it drew the chat,
// at most DRAFT_SETTLE_HOLD_MS: a composer that never mounts, or a read that never answers, ends the wait.
//
// The hold is armed only while the draft is still out. A chat whose draft settled before or with its rows
// (every chat switch, where the composer reads the draft from memory) arms no timer, and one that settles
// during the hold clears it: before, every chat read armed a 2 s timer that woke the pane at rest and
// rendered it once more (bench/chat-switch.bench.ts, chat_switch.*.idle_wakeups). Leo, 2026-11-12:
// "infinite everything feels like nothing".
//
// Nor does the copy wait on a read whose answer it already shows (`promptShown`): after a restart the
// read needs acpmux, which may be seconds from answering, while the prompt already holds what the copy
// shows (no draft, or the one the page's own cache put back). The copy then gave way only when the hold
// ran out, 2 s after the chat's rows were in (first-load-after-restart.bench.ts MODE=down: live at about
// 2.5 s, the rows in at 0.4 s). The read still lands when it answers and merges with what was typed
// meanwhile (Composer `applyDraftRead`). A draft only acpmux holds still waits, so the prompt never
// steps back to its placeholder (restore-monotonic-trace.test.tsx).
import { useEffect, useState, useInsertionEffect, useRef } from "react";

/// The longest the last launch's copy waits on the chat's draft read once its rows are in (firstPaint.ts).
export const DRAFT_SETTLE_HOLD_MS = 2_000;

/// How a wait ran out: the composer showed what it waits for when the rows came in (`shown`) or
/// later (`match`), or DRAFT_SETTLE_HOLD_MS passed first (`cap`).
export type DraftWaitEnd = "shown" | "match" | "cap";

/// The chat whose wait for its draft ran out: `rowsReadFor` (the chat whose rows are in) once
/// DRAFT_SETTLE_HOLD_MS passed with `draftSettled` (the chat whose draft the composer read) not naming it.
/// `promptShown` says whether the composer already shows what the wait is for (its prompt, attachments,
/// queued prompts and picks, at the copy's height: chatSnapshot/live.ts); the wait ends as soon as it
/// does, checked once the rows are in and again as the composer changes (`promptRoot`), until the hold
/// runs out. `ended` hears how each wait ran out; a read that answers first ends none.
export function useDraftWaitOver(
  rowsReadFor: string | undefined,
  draftSettled: string | undefined,
  promptShown: () => boolean = () => false,
  promptRoot: () => Node | null = () => null,
  ended: (by: DraftWaitEnd) => void = () => {},
): string | undefined {
  const [draftWaitOver, setDraftWaitOver] = useState<string>();
  const waiting = rowsReadFor !== undefined && draftSettled !== rowsReadFor ? rowsReadFor : undefined;
  // The checks and `ended` are read when they run, the latest of each, written as the render commits: a
  // new set each render arms nothing again, and a lint rule turned off keeps the hook out of the React Compiler.
  const checks = useRef({ promptShown, promptRoot, ended });
  useInsertionEffect(() => {
    checks.current = { promptShown, promptRoot, ended };
  });
  useEffect(() => {
    if (waiting === undefined) return;
    const { promptShown, promptRoot, ended } = checks.current;
    if (promptShown()) {
      ended("shown");
      setDraftWaitOver(waiting);
      return;
    }
    let watch: MutationObserver | undefined;
    const end = (by: DraftWaitEnd) => {
      watch?.disconnect();
      watch = undefined;
      window.clearTimeout(timer);
      ended(by);
      setDraftWaitOver(waiting);
    };
    const timer = window.setTimeout(() => end("cap"), DRAFT_SETTLE_HOLD_MS);
    const root = promptRoot();
    const Observer = window.MutationObserver;
    if (root && Observer) {
      watch = new Observer(() => {
        if (promptShown()) end("match");
      });
      // Attributes too: a chip that finishes loading, or a strip shown, changes a class or a style.
      watch.observe(root, { childList: true, characterData: true, attributes: true, subtree: true });
    }
    return () => {
      watch?.disconnect();
      window.clearTimeout(timer);
    };
  }, [waiting]);
  return draftWaitOver;
}
