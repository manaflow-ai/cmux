// Prompts sent while the folder's trust question is open (Leo 2026-10-21, P0: a pending trust
// prompt never blocks sending, steering or answering a question). Send stays on: a prompt sent
// while useFolderTrustAsk holds prompts (`blocked`: the question is open, the folder is not
// trusted, or its trust is still being read) waits in the pane, every one of them, in the
// composer's queue under "Waiting for folder trust" (ComposerQueue.tsx), and they go in order,
// each once acpmux took the one before, when the folder is trusted. Not now keeps them there to
// edit or remove; none is dropped. None goes before the answer: acpmux would refuse it
// (`trust_gate.rs`). A steer waits the same way and goes as an ordinary prompt, so the held
// prompts keep their order.
//
// Each keeps the gesture of its own send (heldPrompt.ts): the Trust click's gesture goes to the
// trust answer, and the host keeps one ticket per held prompt (AgentPaneGestureIntent.slot).
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { ComposerAttachment } from "./attachments";
import { attachedImages } from "./direct";
import type { QueueEdit, QueuedPrompt } from "./model";

export type TrustHeldPrompt = {
  /// Its prompt id, kept when it goes (its gesture ticket names it).
  id: string;
  /// The chat it was sent in, undefined for a new chat before its start, and that chat's folder.
  chat: string | undefined;
  cwd: string | undefined;
  text: string;
  attachments: ComposerAttachment[];
  /// The gesture ticket its send reserves for its prompt id (`transport.gesture`); none when the
  /// host gave none. It goes once this settles: the reserve took the send's gesture.
  ticket: Promise<string | undefined>;
};

/// The held prompts of `chat`, as the composer's queue rows.
export function heldQueueRows(held: readonly TrustHeldPrompt[], chat: string | undefined): QueuedPrompt[] {
  return held
    .filter((entry) => entry.chat === chat)
    .map((entry) => {
      const images = attachedImages(entry.attachments);
      return { id: entry.id, prompt: entry.text, held: true, ...(images.length ? { images } : {}) };
    });
}

/// `held` with `edit` made to its prompt `id`: new text, and the images the edit kept.
export function editHeld(held: readonly TrustHeldPrompt[], id: string, edit: QueueEdit): TrustHeldPrompt[] {
  if (edit.op !== "update") return [...held];
  return held.map((entry) => {
    if (entry.id !== id) return entry;
    const kept = edit.images && new Set(edit.images);
    const attachments = kept
      ? entry.attachments.filter((attachment) => attachment.kind !== "image" || kept.has(attachment.id))
      : entry.attachments;
    return { ...entry, text: edit.text, attachments };
  });
}

export function useTrustHeldPrompts({
  chat,
  cwd,
  holds,
  send,
  reserve,
  putBack,
  refusedForTrust,
}: {
  /// The chat shown: its session, undefined for a new chat before its start.
  chat: string | undefined;
  /// The chat's folder, whose trust holds the prompts.
  cwd: string | undefined;
  /// The folder's trust holds prompts now (useFolderTrustAsk `blocked`).
  holds: boolean;
  /// Sends a held prompt; settles once acpmux took it, or rejects with its refusal.
  send(entry: TrustHeldPrompt): Promise<unknown>;
  /// Reserves the current gesture for prompt `promptId` (`transport.gesture`).
  reserve(promptId: string): Promise<string | undefined>;
  /// A held prompt acpmux refused for another reason goes back into the composer.
  putBack(entry: TrustHeldPrompt): void;
  /// Whether a refusal is acpmux's trust gate: the prompt waits again.
  refusedForTrust(error: unknown): boolean;
}) {
  const [held, setHeld] = useState<TrustHeldPrompt[]>([]);
  const latest = useRef({ send, putBack, refusedForTrust });
  latest.current = { send, putBack, refusedForTrust };
  // What a flush reads before each prompt: a prompt removed or edited meanwhile, another chat
  // shown, or the folder held again counts.
  const now = useRef({ held, chat, holds });
  now.current = { held, chat, holds };
  const flushing = useRef(false);
  // Bumped when a flush ends, so prompts that came due meanwhile (a new chat's session started) go.
  const [rounds, setRounds] = useState(0);

  // A new chat's held prompts follow it into its session: the first one sent started it.
  const lastChat = useRef(chat);
  useEffect(() => {
    const was = lastChat.current;
    lastChat.current = chat;
    if (was !== undefined || chat === undefined) return;
    setHeld((list) =>
      list.some((entry) => entry.chat === undefined && entry.cwd === cwd)
        ? list.map((entry) => (entry.chat === undefined && entry.cwd === cwd ? { ...entry, chat } : entry))
        : list,
    );
  }, [chat, cwd]);

  useEffect(() => {
    if (holds || flushing.current || !held.some((entry) => entry.chat === chat)) return;
    flushing.current = true;
    void (async () => {
      // One at a time, each once acpmux took the one before. A new chat's first prompt starts it;
      // the rest go once its session shows.
      for (let sent = 0; chat !== undefined || sent === 0; sent++) {
        const shown = now.current;
        const entry = shown.held.find((item) => item.chat === chat);
        if (!entry || shown.holds || shown.chat !== chat) break;
        now.current = { ...shown, held: shown.held.filter((item) => item.id !== entry.id) };
        setHeld((list) => list.filter((item) => item.id !== entry.id));
        try {
          await latest.current.send(entry);
        } catch (error) {
          if (latest.current.refusedForTrust(error)) {
            // acpmux holds the folder again: this prompt and the rest wait for the next answer.
            setHeld((list) => [entry, ...list]);
            break;
          }
          latest.current.putBack(entry);
        }
      }
      flushing.current = false;
      setRounds((count) => count + 1);
    })();
  }, [holds, chat, held, rounds]);

  /// Holds a prompt sent now, with its send's gesture.
  const hold = useCallback(
    (text: string, attachments: ComposerAttachment[]) => {
      const id = crypto.randomUUID();
      const ticket = reserve(id).catch(() => undefined);
      setHeld((list) => [...list, { id, chat, cwd, text, attachments, ticket }]);
    },
    [chat, cwd, reserve],
  );

  // The same rows until a held prompt comes, goes or changes (the composer's snapshot keeps them).
  const rows = useMemo(() => heldQueueRows(held, chat), [held, chat]);
  return {
    /// The shown chat's held prompts, for the composer's queue.
    rows,
    hold,
    /// Whether `id` is a held prompt (its queue row's actions are the pane's).
    has: (id: string) => held.some((entry) => entry.id === id),
    remove: (id: string) => setHeld((list) => list.filter((entry) => entry.id !== id)),
    edit: (id: string, edit: QueueEdit) => setHeld((list) => editHeld(list, id, edit)),
  };
}
