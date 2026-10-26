import { useEffect, useRef, useState } from "react";
import type { ComposerAttachment } from "../attachments";
import { holdWebSwap } from "../../../pages/shared/webSwap";

/// Where the host keeps each chat's unsent chips (AgentPaneDraftAttachments.swift), so reopening
/// the chat, restoring it from the archive or relaunching after a crash brings them back with the
/// draft's text (Leo 2026-10-20). A chip's contents travel once: a later write names it without
/// them and the host keeps the file it has. `write` answers the ids of the chips whose contents the
/// host holds (`{held}`); a chip it does not hold goes with its contents next time.
export type KeptAttachments = {
  read(sessionId: string): Promise<ComposerAttachment[]>;
  write(sessionId: string, attachments: ComposerAttachment[]): Promise<{ held?: unknown } | null | undefined>;
};

/// How long the chips rest before they go to the host, so several picks or a paste of four
/// screenshots write once.
export const KEPT_ATTACHMENTS_SETTLE_MS = 300;

/// The chips a chat keeps: a shell run's chip stays with its page (its output fills when the prompt goes).
/// A video's poster and frames stay too: the host reads them again when the chip comes back
/// (composer/videoAttachments.ts), so a draft write never carries them.
export function keptChips(attachments: readonly ComposerAttachment[]): ComposerAttachment[] {
  return attachments.flatMap((chip) => {
    if (chip.shellRun) return [];
    if (!chip.video) return [chip];
    const { video: _video, ...kept } = chip;
    return [kept];
  });
}

type Pending = { sessionId: string; chips: ComposerAttachment[]; timer: ReturnType<typeof setTimeout> };

/// Puts chat `sessionId`'s kept chips back when it shows and keeps them as they change. `carrying`
/// says, when the session changes, whether the chips held now move to the new one (a harness
/// switch's new session, as the typed prompt does); otherwise the chat shows only its own. Nothing
/// is written for a chat before its read, so a page that opens empty never erases what it gets back.
export function useKeptAttachments(
  sessionId: string | undefined,
  attachments: ComposerAttachment[],
  setAttachments: (update: (current: ComposerAttachment[]) => ComposerAttachment[]) => void,
  store: KeptAttachments | undefined,
  carrying: () => boolean,
): void {
  const [readFor, setReadFor] = useState<string>();
  /// The chips' ids the host holds for the chat as last written, and which of them it has contents for.
  const written = useRef<{ sessionId?: string; ids: string; stored: Set<string> }>({ ids: "", stored: new Set() });
  const pending = useRef<Pending | undefined>(undefined);
  /// The newest write: only its answer says what the host holds.
  const sequence = useRef(0);
  const carry = useRef(carrying);
  carry.current = carrying;
  /// A chat was read on this page before: the page's first chat keeps what it was opened with.
  const readOne = useRef(false);
  /// Writes sent and not answered yet.
  const inFlight = useRef(0);
  /// Each chat's newest write, and the chats whose newest write the host refused (with what it held).
  const lastWrite = useRef(new Map<string, number>());
  const refused = useRef(new Map<string, ComposerAttachment[]>());
  /// What a web update's reload would bring back (pages/shared/webSwap.ts).
  const shown = useRef({ sessionId, attachments, readFor, store });
  shown.current = { sessionId, attachments, readFor, store };

  /// Writes chat `sessionId`'s chips: the shown chat's (`shownChat`) also says what the host holds now.
  const write = (sessionId: string, chips: ComposerAttachment[], sent: ComposerAttachment[], shownChat: boolean) => {
    if (!store) return;
    const n = ++sequence.current;
    lastWrite.current.set(sessionId, n);
    inFlight.current += 1;
    const settle = (held: Set<string>, failed = false) => {
      inFlight.current -= 1;
      // Only the chat's newest write says what the host keeps for it.
      if (lastWrite.current.get(sessionId) !== n) return;
      // A refused write goes again on the next ask, even once another chat shows.
      if (failed) refused.current.set(sessionId, chips);
      else refused.current.delete(sessionId);
      if (!shownChat || written.current.sessionId !== sessionId) return;
      written.current.stored = held;
      // A refused write holds nothing: the same chips coming back go again.
      if (failed) written.current.ids = "\u0000refused";
    };
    void store.write(sessionId, sent).then(
      (reply) => settle(new Set(Array.isArray(reply?.held) ? reply.held.filter((id) => typeof id === "string") : [])),
      () => settle(new Set(), true),
    );
  };
  const send = (sessionId: string, chips: ComposerAttachment[]) => {
    if (!store) return;
    // Only chips still here keep their "already sent": one sent, then put back, goes again in full.
    const had = written.current.sessionId === sessionId ? written.current.stored : new Set<string>();
    const stored = new Set(chips.filter((chip) => had.has(chip.id)).map((chip) => chip.id));
    written.current = { sessionId, ids: signature(chips), stored };
    const sent = chips.map((chip) => (chip.data && stored.has(chip.id) ? { ...chip, data: undefined } : chip));
    write(sessionId, chips, sent, true);
  };
  const writeNow = useRef(write);
  writeNow.current = write;
  const flush = () => {
    const next = pending.current;
    if (!next) return;
    clearTimeout(next.timer);
    pending.current = undefined;
    send(next.sessionId, next.chips);
  };
  const flushNow = useRef(flush);
  flushNow.current = flush;
  const sendNow = useRef(send);
  sendNow.current = send;

  useEffect(() => {
    if (!sessionId || !store) return;
    // The last chat's chips reach the host before this chat's are read.
    flush();
    const keepHeld = carry.current();
    let current = true;
    void store
      .read(sessionId)
      .catch(() => [])
      .then((kept) => {
        if (!current) return;
        const read = Array.isArray(kept) ? kept : [];
        written.current = { sessionId, ids: signature(read), stored: new Set(read.map((chip) => chip.id)) };
        // This chat's last write was refused: what the page showed then comes back with it, and goes
        // again (the swap's hold resends a refused write) until the host keeps it.
        const unkept = refused.current.get(sessionId);
        const back = unkept ? [...read, ...unkept.filter((chip) => !read.some((k) => k.id === chip.id))] : read;
        if (unkept) written.current.ids = "\u0000refused";
        const keep = keepHeld || !readOne.current;
        readOne.current = true;
        setAttachments((held) => {
          const others = keep ? held.filter((chip) => !back.some((k) => k.id === chip.id)) : [];
          return back.length || others.length !== held.length ? [...back, ...others] : held;
        });
        setReadFor(sessionId);
      });
    return () => {
      current = false;
    };
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- flush only sends what rests; a chat is read once per session.
  }, [sessionId, store, setAttachments]);

  useEffect(() => {
    if (!sessionId || !store || readFor !== sessionId) return;
    const chips = keptChips(attachments);
    // Back to what the host has (a chip pasted and sent or removed before it rested): a write still
    // resting would put back what is gone, so it is dropped.
    if (written.current.sessionId === sessionId && written.current.ids === signature(chips)) {
      if (pending.current) clearTimeout(pending.current.timer);
      pending.current = undefined;
      return;
    }
    if (pending.current?.sessionId === sessionId && signature(pending.current.chips) === signature(chips)) return;
    if (pending.current) clearTimeout(pending.current.timer);
    pending.current = {
      sessionId,
      chips,
      timer: setTimeout(() => {
        pending.current = undefined;
        send(sessionId, chips);
      }, KEPT_ATTACHMENTS_SETTLE_MS),
    };
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- send is this render's; the timer sends what this render held.
  }, [sessionId, store, readFor, attachments]);

  // WEB-SWAP: a web update reloads the page only once the host holds every chip as shown, with
  // its contents: a chip still resting, in flight, refused or not read back yet waits for it.
  useEffect(
    () =>
      holdWebSwap(() => {
        const { sessionId, attachments, readFor, store } = shown.current;
        if (attachments.some((chip) => chip.shellRun)) return "composer.shell-run";
        // A write resting or in flight (a removal's empty list too): what a reload reads back is not known yet.
        if (pending.current || inFlight.current) return "composer.attachments-unsaved";
        // Another chat's refused write: it goes again now, in full, once per ask.
        let other = false;
        for (const [chat, chips] of refused.current) {
          if (chat === sessionId) continue;
          writeNow.current(chat, chips, chips, false);
          other = true;
        }
        if (other) return "composer.attachments-unsaved";
        const chips = keptChips(attachments);
        // The host's chips not read back yet: a page that reloads now reads them then.
        if (sessionId && store && readFor !== sessionId) return "composer.attachments-unread";
        if (!sessionId || !store) return chips.length ? "composer.attachments-unkept" : null;
        const kept = written.current;
        const behind =
          kept.sessionId !== sessionId ||
          kept.ids !== signature(chips) ||
          chips.some((chip) => chip.data && !kept.stored.has(chip.id));
        if (!behind) return null;
        // The host refused the last write: it goes again now, once per ask, so a passing refusal
        // does not hold the update for good. (A host that keeps fewer bytes than shown holds it.)
        if (kept.ids === "\u0000refused") sendNow.current(sessionId, chips);
        return "composer.attachments-unsaved";
      }),
    [],
  );

  // A page closing or going away (its tab closed, the chat archived) with a write still resting
  // sends it now: the web page may be gone before React unmounts anything.
  useEffect(() => {
    const away = () => flushNow.current();
    const hidden = () => {
      if (document.visibilityState === "hidden") flushNow.current();
    };
    window.addEventListener("pagehide", away);
    document.addEventListener("visibilitychange", hidden);
    return () => {
      window.removeEventListener("pagehide", away);
      document.removeEventListener("visibilitychange", hidden);
      flushNow.current();
    };
  }, []);
}

const signature = (chips: readonly ComposerAttachment[]) => chips.map((chip) => chip.id).join("\n");
