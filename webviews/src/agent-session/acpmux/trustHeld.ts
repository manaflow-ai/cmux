// Prompts sent while the folder's trust question is open (Leo 2026-10-21, P0: a pending trust
// prompt never blocks sending, steering or answering a question). Send stays on: a prompt sent
// while useFolderTrustAsk holds prompts (`blocked`: the question is open, the folder is not
// trusted, or its trust is still being read) waits in the pane, every one of them, in the
// composer's queue under "Waiting for folder trust" (ComposerQueue.tsx), and they go in order,
// each once acpmux took the one before, when the folder is trusted. Not now keeps them there to
// edit or remove; none is dropped. None goes before the answer: acpmux would refuse it
// (`trust_gate.rs`). A steer waits the same way and goes as an ordinary prompt, so the held
// prompts keep their order. A trust read still in flight holds nothing (#28088): a prompt sent
// then goes, and one acpmux refuses for the folder's trust joins the hold (App.tsx `holdRefused`).
//
// Each keeps the gesture of its own send (heldPrompt.ts): the Trust click's gesture goes to the
// trust answer, and the host keeps one ticket per held prompt (AgentPaneGestureIntent.slot,
// `session/prompt#<promptId>`), for AgentPaneUserGestures.heldPromptLifetime. A ticket is spent
// when its prompt goes, so a prompt acpmux refuses again goes back into the composer, to be sent
// with a new gesture; one kept in the chat as its own failed row (App.tsx `keptInChat`) stays there.
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
  /// Held while the chat's Cloud machine wakes (cloudWake.ts), not for the folder's trust: it
  /// reserves no ticket (a ticket ends with the connection the wake replaces) and goes with the
  /// send's gesture once the chat is back.
  waking?: true;
};

/// Whether `entry` was sent in the chat shown: its session, or for a new chat (no session yet) its
/// folder, so a new chat's prompts never go to another new chat picked meanwhile.
export function sentIn(entry: TrustHeldPrompt, chat: string | undefined, cwd: string | undefined): boolean {
  return entry.chat === chat && (chat !== undefined || entry.cwd === cwd);
}

/// Where prompts the hold gives back go (a refusal, or a page that quits), each list in order: the
/// shown chat's into its composer; another chat's into that chat's draft, as the shown chat's when
/// no composer shows (a hand-off review in its place); a new chat's into the composer while the
/// tab's new chat shows (in whichever folder, as its typed text stays), the only draft such a chat
/// has, else into what the tab's new chat gets next (`later`), never into another chat's composer.
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
    else if (composerShows && entry.chat === shownChat) composer.push(entry);
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
      return {
        id: entry.id,
        prompt: entry.text,
        held: true,
        ...(entry.waking ? { waking: true as const } : {}),
        ...(images.length ? { images } : {}),
      };
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
  keptElsewhere,
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
  /// Whether a refused prompt stays in the chat (its failed row with Retry): it is not given back.
  keptElsewhere?(error: unknown): boolean;
}) {
  const [held, setHeld] = useState<TrustHeldPrompt[]>([]);
  const latest = useRef({ send, putBack, refusedForTrust, keptElsewhere });
  latest.current = { send, putBack, refusedForTrust, keptElsewhere };
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
  /// Picks from the new chat still waiting for the chat they open (``pauseNewChat``): no new chat's
  /// prompt goes meanwhile, or it could land in that chat.
  const pausedNewChat = useRef(0);

  useEffect(() => {
    if (holds || flushing.current || !held.some((entry) => sentIn(entry, chat, cwd))) return;
    // A new chat's first prompt is starting it: the rest wait for its session. A pick paused them.
    if (chat === undefined && (starting.current || pausedNewChat.current > 0)) return;
    flushing.current = true;
    void (async () => {
      // One at a time, each once acpmux took the one before. A new chat's first prompt starts it;
      // the rest go once its session shows.
      for (let sent = 0; chat !== undefined || sent === 0; sent++) {
        const shown = now.current;
        const entry = shown.held.find((item) => sentIn(item, chat, cwd));
        if (!entry || shown.holds || shown.chat !== chat || shown.cwd !== cwd) break;
        if (chat === undefined && pausedNewChat.current > 0) break;
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
          const handedBack =
            (error as { handedBack?: unknown } | null)?.handedBack === true ||
            latest.current.keptElsewhere?.(error) === true;
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
  /// and folder it was sent in, for a refusal that came after the person moved on. `waking`: it
  /// waits for the chat's Cloud machine to wake instead (cloudWake.ts), with no ticket.
  const hold = useCallback(
    (
      text: string,
      attachments: ComposerAttachment[],
      sentFrom?: { chat: string | undefined; cwd: string | undefined },
      waking = false,
    ) => {
      const id = crypto.randomUUID();
      const ticket = waking ? Promise.resolve(undefined) : reserve(id).catch(() => undefined);
      const entry: TrustHeldPrompt = {
        id,
        ...(sentFrom ?? { chat, cwd }),
        text,
        attachments,
        ticket,
        ...(waking ? { waking: true as const } : {}),
      };
      now.current = { ...now.current, held: [...now.current.held, entry] };
      setHeld((list) => [...list, entry]);
    },
    [chat, cwd, reserve],
  );

  const rowsInKept = useRef<{ held: TrustHeldPrompt[]; chat: string; rows: QueuedPrompt[] } | undefined>(undefined);
  // The same rows until a held prompt comes, goes or changes (the composer's snapshot keeps them).
  const rows = useMemo(() => heldQueueRows(held, chat, cwd), [held, chat, cwd]);
  // Every new chat's held text, whichever folder it was picked in: the tab's one new chat keeps them.
  const newChatTexts = useMemo(
    () => held.filter((entry) => entry.chat === undefined).map((entry) => entry.text),
    [held],
  );
  return {
    /// The shown chat's held prompts, for the composer's queue.
    rows,
    /// A new chat's held prompts' text, in order, for the host's copy of the tab's new chat.
    newChatTexts,
    hold,
    /// Whether `id` is a held prompt (its queue row's actions are the pane's).
    has: (id: string) => now.current.held.some((entry) => entry.id === id),
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
    /// Takes the shown chat's held prompts out, in order, for a start that leaves its folder (Trust's
    /// "continue without folder", #28198): they go back into the composer before it moves on.
    takeShown: () => {
      const { chat: shownChat, cwd: shownCwd } = now.current;
      const taken = now.current.held.filter((entry) => sentIn(entry, shownChat, shownCwd));
      if (!taken.length) return taken;
      const ids = new Set(taken.map((entry) => entry.id));
      now.current = { ...now.current, held: now.current.held.filter((entry) => !ids.has(entry.id)) };
      setHeld((list) => list.filter((entry) => !ids.has(entry.id)));
      return taken;
    },
    remove: (id: string) => {
      now.current = { ...now.current, held: now.current.held.filter((entry) => entry.id !== id) };
      setHeld((list) => list.filter((entry) => entry.id !== id));
    },
    edit: (id: string, edit: QueueEdit) => {
      now.current = { ...now.current, held: editHeld(now.current.held, id, edit) };
      setHeld((list) => editHeld(list, id, edit));
    },
    /// Holds every new chat's prompt from now, for a pick waiting for the chat it opens; returns
    /// what resumes them (once, however often it is called). A pick that lands takes them first
    /// (``takeNewChat``); one that fails only resumes, and they go as before.
    pauseNewChat: () => {
      pausedNewChat.current += 1;
      let resumed = false;
      return () => {
        if (resumed) return;
        resumed = true;
        pausedNewChat.current -= 1;
        setRounds((count) => count + 1);
      };
    },
    /// Takes every new chat's held prompt out, in order, for a tab that opens another chat: what
    /// they say goes with the new chat's leftover (cmux#32276), and none is sent after.
    /// One going (a start the pick cancelled, not settled yet) is taken first, as `release` takes
    /// it: its send settling later puts nothing back, and a copy that reached acpmux stays a draft.
    takeNewChat: () => {
      const inFlight = going.current?.chat === undefined ? going.current : undefined;
      if (inFlight) {
        going.current = undefined;
        released.current.add(inFlight.id);
      }
      const held = now.current.held.filter((entry) => entry.chat === undefined);
      if (held.length) {
        const ids = new Set(held.map((entry) => entry.id));
        now.current = { ...now.current, held: now.current.held.filter((entry) => !ids.has(entry.id)) };
        setHeld((list) => list.filter((entry) => !ids.has(entry.id)));
      }
      return inFlight ? [inFlight, ...held] : held;
    },
    /// The held prompts of chat `shownChat` as queue rows, for a chat the pane shows under the id its tab
    /// recorded while it is not listed (a Cloud machine that wakes, cloudWake.ts).
    /// The same rows until a held prompt comes, goes or changes, as `rows` keeps them.
    rowsIn: (shownChat: string) => {
      const kept = rowsInKept.current;
      if (kept?.held === held && kept.chat === shownChat) return kept.rows;
      const next = heldQueueRows(held, shownChat, undefined);
      rowsInKept.current = { held, chat: shownChat, rows: next };
      return next;
    },
    /// Whether any prompt waits for a Cloud machine to wake (cloudWake.ts).
    wakingAny: () => now.current.held.some((entry) => entry.waking),
    /// Takes every prompt that waits for a Cloud machine to wake out, in order: the wake failed, so
    /// they go back into the composer.
    takeWaking: () => {
      const taken = now.current.held.filter((entry) => entry.waking);
      if (!taken.length) return taken;
      const ids = new Set(taken.map((entry) => entry.id));
      now.current = { ...now.current, held: now.current.held.filter((entry) => !ids.has(entry.id)) };
      setHeld((list) => list.filter((entry) => !ids.has(entry.id)));
      return taken;
    },
    /// The held prompt `id`, for an edit that takes it back into the composer.
    get: (id: string) => now.current.held.find((entry) => entry.id === id),
  };
}
