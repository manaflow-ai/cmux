// A started chat's pick of another harness's model, held as its next message's target (Leo
// 2026-11-06: "if you select anything that's not a step, you should be able to, like, see, preview,
// select anything, and you can pick it" ... "it should only need to necessarily fork when you enter
// a message on that new model"). The model menu holds it (ComposerPickers), the chip draws it with a
// fork mark, and the composer's send runs Continue In… with it (App.tsx). Nothing forks until then.
// Kept per chat in this page only: a pick in one chat never forks another, and leaving the chat
// drops it (ComposerPickers).
import { useCallback, useSyncExternalStore } from "react";
import type { Handoff } from "./handoff/protocol";
import type { HandoffReviewInput } from "./handoff/review";

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
  }).then(
    (target) => {
      // l10n-allow: a developer error for the composer's promise; the composer keeps the text, never shows this.
      if (!target) throw new Error("chat.handoff.prepare made no review");
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

/// What `chat.handoff.prepare` gets from a send with a held pick (sendHeldFork).
export type HeldForkParams = {
  harness: string;
  model?: string;
  effort?: string;
  fast?: boolean;
  message?: string;
};

/// `chat.handoff.prepare`'s work for a held pick (App.tsx): Continue In… to the pick's harness,
/// the held model landed on the new chat before its review is ready (so Start never runs the
/// message on that chat's default model), its effort and Fast best effort, then the message added
/// to the review's context after a blank line. The review's checkpoint stays as the draft has it:
/// the person still confirms it before Start. Resolves the new chat; undefined when Continue In…
/// made no review. Throws when the model did not land or the message did not join the review (a
/// refused or conflicting save, a review no longer shown), so the composer keeps the message and
/// the hold (review of #37196).
export async function prepareHeldFork(
  params: HeldForkParams,
  {
    continueIn,
    pickModel,
    options,
    record,
    refresh,
    save,
    saved,
  }: {
    continueIn(harness: string): Promise<string | undefined>;
    /// Lands the model on the new chat; false when it did not take it.
    pickModel(model: string, target: string): Promise<boolean>;
    /// Sets the held effort and Fast on the new chat, best effort.
    options?(target: string, picked: { effort?: string; fast?: boolean }): Promise<void>;
    /// The review's record as it is now.
    record(): Handoff | undefined;
    /// Reads the shown chat's review again.
    refresh?(): Promise<unknown>;
    save(review: HandoffReviewInput): Promise<Handoff | undefined>;
    /// The message joined the review: the review draws its draft again.
    saved?(): void;
  },
): Promise<string | undefined> {
  const target = await continueIn(params.harness);
  if (!target) return target;
  if (params.model) {
    // l10n-allow: the composer's promise only; the person sees the pick's own notice.
    if (!(await pickModel(params.model, target))) throw new Error("model not set");
    if (params.effort || params.fast)
      await options?.(target, {
        ...(params.effort ? { effort: params.effort } : {}),
        ...(params.fast ? { fast: true } : {}),
      }).catch(() => undefined);
  }
  const message = params.message ?? "";
  if (!message.trim()) return target;
  // The selection of the new chat starts its review's read: one not in yet is read here
  // (review of #37196: the message failed to join a review still loading).
  let shown = record();
  if (shown?.target.sessionId !== target) {
    await refresh?.();
    shown = record();
  }
  // l10n-allow: the composer's promise only; the composer keeps the text, never shows this.
  if (shown?.target.sessionId !== target) throw new Error("review not shown");
  const accepted = await save({
    capsule: shown.capsule.text.trim() ? `${shown.capsule.text}\n\n${message}` : message,
    checkpoint: { reference: shown.capsule.checkpoint?.ref ?? "", confirmed: !!shown.capsule.checkpoint },
    approvedMemoryReferences: shown.capsule.memoryRefs,
    revision: shown.revision,
  });
  // l10n-allow: the composer's promise only; the composer keeps the text, never shows this.
  if (!accepted) throw new Error("message not saved");
  saved?.();
  return target;
}
