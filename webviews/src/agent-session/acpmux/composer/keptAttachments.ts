import { useEffect, useRef, useState } from "react";
import type { ComposerAttachment } from "../attachments";

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
export function keptChips(attachments: readonly ComposerAttachment[]): ComposerAttachment[] {
  return attachments.filter((chip) => !chip.shellRun);
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

  const send = (sessionId: string, chips: ComposerAttachment[]) => {
    if (!store) return;
    // Only chips still here keep their "already sent": one sent, then put back, goes again in full.
    const had = written.current.sessionId === sessionId ? written.current.stored : new Set<string>();
    const stored = new Set(chips.filter((chip) => had.has(chip.id)).map((chip) => chip.id));
    written.current = { sessionId, ids: signature(chips), stored };
    const sent = chips.map((chip) => (chip.data && stored.has(chip.id) ? { ...chip, data: undefined } : chip));
    const write = ++sequence.current;
    const settle = (held: Set<string>, failed = false) => {
      if (write !== sequence.current || written.current.sessionId !== sessionId) return;
      written.current.stored = held;
      // A refused write holds nothing: the same chips coming back go again.
      if (failed) written.current.ids = "\u0000refused";
    };
    void store.write(sessionId, sent).then(
      (reply) => settle(new Set(Array.isArray(reply?.held) ? reply.held.filter((id) => typeof id === "string") : [])),
      () => settle(new Set(), true),
    );
  };
  const flush = () => {
    const next = pending.current;
    if (!next) return;
    clearTimeout(next.timer);
    pending.current = undefined;
    send(next.sessionId, next.chips);
  };
  const flushNow = useRef(flush);
  flushNow.current = flush;

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
        const back = Array.isArray(kept) ? kept : [];
        written.current = { sessionId, ids: signature(back), stored: new Set(back.map((chip) => chip.id)) };
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
