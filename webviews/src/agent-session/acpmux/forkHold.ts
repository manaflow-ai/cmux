// A started chat's pick of another harness's model, held as its next message's target (Leo
// 2026-11-06: "if you select anything that's not a step, you should be able to, like, see, preview,
// select anything, and you can pick it" ... "it should only need to necessarily fork when you enter
// a message on that new model"). The model menu holds it (ComposerPickers), the chip draws it with a
// fork mark, and the composer's send forks the chat onto it in the same pane (App.tsx `chat.forkTo`,
// Leo 2026-11-11: "it should just be able to seamlesly within the same pane do stuff and stop
// asking so much bullshit"). Nothing forks until then.
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
  /// The harness's name as the menu labels it ("Claude (work)"): a launch profile folded into its
  /// family's tab has no catalog entry of its own to name it.
  name?: string;
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
/// necessarily fork when you enter a message on that new model"; Leo 2026-11-11: "if i switch to a
/// different model in a chat, it should just be able to seamlesly within the same pane do stuff and
/// stop asking so much bullshit ... across any and all conditions of
/// workspaces/folders/models/provides/harnesses"): the message forks the chat onto the pick's
/// harness and model in this same pane (`chat.forkTo`, App.tsx: acpmux `acp.session.fork {live,
/// harness, model}`), with no review, no question and no new tab, and goes to the fork as its first
/// message, attachments and all. Undefined: nothing is held, the send goes on as usual. Else the
/// promise the composer holds the message on: it clears once the fork took the message, and keeps
/// it, with the pick, when the fork failed.
export function sendHeldFork(
  sessionId: string | undefined,
  {
    fork,
    sent,
  }: {
    /// Forks the chat onto the pick in this pane and sends it the message; resolves the fork's id.
    fork(params: HeldForkParams): Promise<string>;
    /// The fork took the message: the source chat's draft is cleared (the message went with the fork).
    sent?(sessionId: string): void;
  },
): Promise<string> | undefined {
  const pick = heldFork(sessionId);
  if (!pick) return undefined;
  return fork({
    harness: pick.harness,
    ...(pick.model ? { model: pick.model } : {}),
    ...(pick.effort ? { effort: pick.effort } : {}),
    ...(pick.fast ? { fast: true } : {}),
  }).then(
    (target) => {
      clearHeldFork(pick.sessionId);
      sent?.(pick.sessionId);
      return target;
    },
    (error: unknown) => {
      // The fork selected its new chat before it failed, which closed this chat's composer and
      // dropped the pick with it: the pick comes back, unless another was made since (review of
      // #37196: a failed fork lost the held model).
      if (!heldFork(pick.sessionId)) holdFork(pick);
      throw error;
    },
  );
}

/// What `chat.forkTo` gets from a send with a held pick (sendHeldFork).
export type HeldForkParams = {
  harness: string;
  model?: string;
  effort?: string;
  fast?: boolean;
};
