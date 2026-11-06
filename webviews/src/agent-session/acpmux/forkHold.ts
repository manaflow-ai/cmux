// A started chat's pick of another harness's model, held as its next message's target (Leo
// 2026-11-06: "if you select anything that's not a step, you should be able to, like, see, preview,
// select anything, and you can pick it" ... "it should only need to necessarily fork when you enter
// a message on that new model"). The model menu holds it (ComposerPickers), the chip draws it with a
// fork mark, and the composer's send runs Continue In… with it (App.tsx). Nothing forks until then.
// Kept per chat in this page only: a pick in one chat never forks another, and leaving the chat
// drops it (ComposerPickers).
import { useCallback, useSyncExternalStore } from "react";

export type HeldFork = {
  /// The chat the pick was made in; only its next send forks.
  sessionId: string;
  /// The acpmux harness (profile) the fork starts the new chat on.
  harness: string;
  /// The model picked there; none for a launch profile's tab, which starts on its own default.
  model?: string;
  /// A typed combo's effort and Fast ("gpt high fast"), applied with the model.
  effort?: string;
  fast?: boolean;
};

const held = new Map<string, HeldFork>();
const listeners = new Set<() => void>();

function changed(): void {
  for (const listener of listeners) listener();
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/// Holds `pick` as its chat's next send's target, replacing any earlier one.
export function holdFork(pick: HeldFork): void {
  held.set(pick.sessionId, pick);
  changed();
}

/// Drops the chat's held pick (a pick of its own harness again, a send that forked, leaving it).
export function clearHeldFork(sessionId: string | undefined): void {
  if (!sessionId || !held.delete(sessionId)) return;
  changed();
}

/// The chat's held pick, read at send time.
export function heldFork(sessionId: string | undefined): HeldFork | undefined {
  return sessionId ? held.get(sessionId) : undefined;
}

/// The chat's held pick, redrawn when it changes.
export function useHeldFork(sessionId: string | undefined): HeldFork | undefined {
  const read = useCallback(() => heldFork(sessionId), [sessionId]);
  return useSyncExternalStore(subscribe, read, read);
}

/// The composer's send in a chat with a held pick (Leo 2026-11-06: "it should only need to
/// necessarily fork when you enter a message on that new model"): the message forks the chat to the
/// pick's harness through Continue In… (`chat.handoff.prepare`, App.tsx), which lands the model on
/// the new chat and adds the message to its review. Undefined: nothing is held, the send goes on
/// as usual. False: the composer keeps the message (the chat can't fork now: a turn or queue runs,
/// a review is open; or it carries images, which the review's text can't hold). Else the promise
/// the composer holds the message on: it clears once the review is ready, and keeps it when the
/// fork fails.
export function sendHeldFork(
  sessionId: string | undefined,
  text: string,
  {
    images,
    ready,
    prepare,
    sent,
  }: {
    images: number;
    /// Continue In… can start now (canContinueIn).
    ready: boolean;
    prepare(params: Record<string, unknown>): Promise<string | undefined>;
    /// The fork started: the source chat's draft is cleared (the message went with the fork).
    sent?(sessionId: string): void;
  },
): false | Promise<string> | undefined {
  const pick = heldFork(sessionId);
  if (!pick) return undefined;
  if (images > 0 || !ready) return false;
  return prepare({
    harness: pick.harness,
    ...(pick.model ? { model: pick.model } : {}),
    ...(pick.effort ? { effort: pick.effort } : {}),
    ...(pick.fast ? { fast: true } : {}),
    message: text,
  }).then((target) => {
    // l10n-allow: a developer error for the composer's promise; the composer keeps the text, never shows this.
    if (!target) throw new Error("chat.handoff.prepare made no review");
    clearHeldFork(pick.sessionId);
    sent?.(pick.sessionId);
    return target;
  });
}
