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
// trust answer, and the host keeps one ticket per held prompt (AgentPaneGestureIntent.slot). A
// ticket is spent when its prompt goes, so a prompt acpmux refuses again goes back into the
// composer, to be sent with a new gesture. A prompt acpmux refused for the folder's trust before
// the pane knew to hold it joins the hold too (App.tsx `holdRefused`).
//
// The prompts live with the page: a hidden page that holds or sends any is not let go
// (`pane.wakeState` `holdsPrompts`, AgentPageHibernation.swift), and quitting puts them back into
// drafts (`release`).
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

/// Whether `entry` was sent in the chat shown: its session, or for a new chat (no session yet) its
/// folder, so a new chat's prompts never go to another new chat picked meanwhile.
export function sentIn(entry: TrustHeldPrompt, chat: string | undefined, cwd: string | undefined): boolean {
  return entry.chat === chat && (chat !== undefined || entry.cwd === cwd);
}

/// Where prompts the hold gives back go (a refusal, or a page that quits), each list in order: the
/// shown chat's into its composer; another chat's into that chat's draft, as the shown chat's when
/// no composer shows (a hand-off review in its place); a new chat's into the composer, the only
/// draft such a chat has, or with none shown into what the next composer gets (`later`).
export function whereHeldGoes(
  entries: readonly TrustHeldPrompt[],
  shownChat: string | undefined,
  composerShows: boolean,
): { composer: TrustHeldPrompt[]; drafts: Map<string, TrustHeldPrompt[]>; later: TrustHeldPrompt[] } {
  const composer: TrustHeldPrompt[] = [];
  const drafts = new Map<string, TrustHeldPrompt[]>();
  const later: TrustHeldPrompt[] = [];
  for (const entry of entries) {
    if (entry.chat !== undefined && (entry.chat !== shownChat || !composerShows))
      drafts.set(entry.chat, [...(drafts.get(entry.chat) ?? []), entry]);
    else if (composerShows) composer.push(entry);
    else later.push(entry);
  }
  return { composer, drafts, later };
}

/// A held prompt's send found another chat shown than its own once its ticket came: it did not go.
/// `session`: the session a new chat's start made for it, which it and its backlog belong to now.
export function movedOn(session?: string): Error {
  // l10n-allow: never shown; the hold reads only `moved` and `session`.
  return Object.assign(new Error("the chat shown changed"), { moved: true, ...(session ? { session } : {}) });
}

/// The held prompts of the chat shown (`chat`, and `cwd` for a new chat), as the composer's queue rows.
export function heldQueueRows(
  held: readonly TrustHeldPrompt[],
  chat: string | undefined,
  cwd: string | undefined,
): QueuedPrompt[] {
  return held
    .filter((entry) => sentIn(entry, chat, cwd))
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
  /// Sends a held prompt; settles once acpmux took it (with the session a new chat's start made),
  /// or rejects with its refusal.
  send(entry: TrustHeldPrompt): Promise<string | undefined>;
  /// Reserves the current gesture for prompt `promptId` (`transport.gesture`).
  reserve(promptId: string): Promise<string | undefined>;
  /// A held prompt acpmux refused for another reason goes back into the composer.
  /// `behind`: after one a harness switch already gave back (they were sent after it).
  putBack(entries: TrustHeldPrompt[], behind?: boolean): void;
  /// Whether a refusal is acpmux's trust gate: the prompt waits again.
  refusedForTrust(error: unknown): boolean;
}) {
  const [held, setHeld] = useState<TrustHeldPrompt[]>([]);
  const latest = useRef({ send, putBack, refusedForTrust });
  latest.current = { send, putBack, refusedForTrust };
  // What a flush reads before each prompt: a prompt removed or edited meanwhile, another chat
  // shown, or the folder held again counts.
  const now = useRef({ held, chat, cwd, holds });
  now.current = { held, chat, cwd, holds };
  const flushing = useRef(false);
  // Bumped when a flush ends, so prompts that came due meanwhile (a new chat's session started) go.
  const [rounds, setRounds] = useState(0);

  /// A new chat's first held prompt is starting it: no other new chat's prompt goes meanwhile.
  const starting = useRef(false);
  /// The prompt being sent, until acpmux took or refused it (a page that quits keeps it, `release`).
  const going = useRef<TrustHeldPrompt | undefined>(undefined);
  /// Prompts a quitting page took out (`release`): a send of one that settles later puts nothing back.
  const released = useRef(new Set<string>());

  useEffect(() => {
    if (holds || flushing.current || !held.some((entry) => sentIn(entry, chat, cwd))) return;
    // A new chat's first prompt is starting it: the rest wait for its session.
    if (chat === undefined && starting.current) return;
    flushing.current = true;
    void (async () => {
      // One at a time, each once acpmux took the one before. A new chat's first prompt starts it;
      // the rest go once its session shows.
      for (let sent = 0; chat !== undefined || sent === 0; sent++) {
        const shown = now.current;
        const entry = shown.held.find((item) => sentIn(item, chat, cwd));
        if (!entry || shown.holds || shown.chat !== chat || shown.cwd !== cwd) break;
        now.current = { ...shown, held: shown.held.filter((item) => item.id !== entry.id) };
        setHeld((list) => list.filter((item) => item.id !== entry.id));
        if (chat === undefined) starting.current = true;
        going.current = entry;
        try {
          const started = await latest.current.send(entry);
          going.current = undefined;
          if (released.current.has(entry.id)) break;
          // A new chat's other prompts in that folder follow it into the session its start made,
          // whatever chat shows by then. Without that session they go back into the composer
          // rather than start a second chat.
          if (chat === undefined) {
            const ours = (item: TrustHeldPrompt) => item.chat === undefined && item.cwd === entry.cwd;
            const rest = now.current.held.filter(ours);
            const bound = now.current.held.map((item) => (ours(item) && started ? { ...item, chat: started } : item));
            now.current = { ...now.current, held: started ? bound : now.current.held.filter((item) => !ours(item)) };
            setHeld((list) =>
              started
                ? list.map((item) => (ours(item) ? { ...item, chat: started } : item))
                : list.filter((item) => !ours(item)),
            );
            if (!started && rest.length) latest.current.putBack(rest);
          }
        } catch (error) {
          going.current = undefined;
          // Released by a quitting page: it is in a draft already.
          if (released.current.has(entry.id)) break;
          // Another chat showed before it went (`movedOn`): unsent, its ticket unspent, it waits
          // again first in its own chat.
          // A new chat's start that made its session binds it and its folder's backlog there.
          const moved = error as { moved?: unknown; session?: unknown } | null;
          if (moved?.moved === true) {
            const session = chat === undefined && typeof moved.session === "string" ? moved.session : undefined;
            const ours = (item: TrustHeldPrompt) => item.chat === undefined && item.cwd === entry.cwd;
            const bind = (list: TrustHeldPrompt[]) =>
              session ? list.map((item) => (ours(item) ? { ...item, chat: session } : item)) : list;
            now.current = { ...now.current, held: bind([entry, ...now.current.held]) };
            setHeld((list) => bind([entry, ...list]));
            break;
          }
          // Refused: its ticket is spent, so it goes back into the composer, unless a harness
          // switch already handed it back there (harnessSwitch.ts). A trust refusal (acpmux holds
          // the folder again) in a chat that has a session leaves the rest waiting for the next
          // answer. Any other refusal, or any in a new chat (whose start may have made a session
          // its backlog no longer shows in), gives the rest back with it, in their order: none goes
          // ahead of one refused, and none is left where it no longer shows.
          const handedBack = (error as { handedBack?: unknown } | null)?.handedBack === true;
          const waits = chat !== undefined && latest.current.refusedForTrust(error);
          const rest = waits
            ? []
            : now.current.held.filter((item) =>
                chat === undefined ? item.chat === undefined && item.cwd === entry.cwd : item.chat === chat,
              );
          if (rest.length) {
            const back = new Set(rest.map((item) => item.id));
            now.current = { ...now.current, held: now.current.held.filter((item) => !back.has(item.id)) };
            setHeld((list) => list.filter((item) => !back.has(item.id)));
          }
          const given = [...(handedBack ? [] : [entry]), ...rest];
          if (given.length) latest.current.putBack(given, handedBack);
          break;
        } finally {
          if (chat === undefined) starting.current = false;
        }
      }
      flushing.current = false;
      setRounds((count) => count + 1);
    })();
  }, [holds, chat, cwd, held, rounds]);

  /// Holds a prompt sent now, with its send's gesture, in the chat shown, or in `sentFrom`: the chat
  /// and folder it was sent in, for a refusal that came after the person moved on.
  const hold = useCallback(
    (
      text: string,
      attachments: ComposerAttachment[],
      sentFrom?: { chat: string | undefined; cwd: string | undefined },
    ) => {
      const id = crypto.randomUUID();
      const ticket = reserve(id).catch(() => undefined);
      const entry = { id, ...(sentFrom ?? { chat, cwd }), text, attachments, ticket };
      now.current = { ...now.current, held: [...now.current.held, entry] };
      setHeld((list) => [...list, entry]);
    },
    [chat, cwd, reserve],
  );

  // The same rows until a held prompt comes, goes or changes (the composer's snapshot keeps them).
  const rows = useMemo(() => heldQueueRows(held, chat, cwd), [held, chat, cwd]);
  return {
    /// The shown chat's held prompts, for the composer's queue.
    rows,
    hold,
    /// Whether `id` is a held prompt (its queue row's actions are the pane's).
    has: (id: string) => held.some((entry) => entry.id === id),
    /// Whether the chat shown still has prompts held or going: a prompt sent now waits behind them,
    /// so it never goes before one sent earlier.
    pending: () =>
      flushing.current || now.current.held.some((entry) => sentIn(entry, now.current.chat, now.current.cwd)),
    /// Whether any chat's prompt is held or going: a hidden page that has one is not let go.
    holdsAny: () => flushing.current || now.current.held.length > 0,
    /// Takes every held prompt out, and the one going, for a page that quits (`pane.wakeState`):
    /// their tickets end with it, so they go back into drafts. The one going may also reach
    /// acpmux; its copy in a draft is then only a draft, never sent twice.
    release: () => {
      const all = [...(going.current ? [going.current] : []), ...now.current.held];
      going.current = undefined;
      for (const entry of all) released.current.add(entry.id);
      now.current = { ...now.current, held: [] };
      setHeld([]);
      return all;
    },
    remove: (id: string) => setHeld((list) => list.filter((entry) => entry.id !== id)),
    edit: (id: string, edit: QueueEdit) => setHeld((list) => editHeld(list, id, edit)),
  };
}
