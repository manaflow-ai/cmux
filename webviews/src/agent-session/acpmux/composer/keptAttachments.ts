import { useEffect, useRef, useState } from "react";
import { type ComposerAttachment, MAX_ATTACHMENTS } from "../attachments";

/// Where the host keeps each chat's unsent chips (AgentPaneDraftAttachments.swift), so reopening
/// the chat, restoring it from the archive or relaunching after a crash brings them back with the
/// draft's text (Leo 2026-10-20). A chip's contents travel once: a later write names it without
/// them and the host keeps the file it has.
export type KeptAttachments = {
  read(sessionId: string): Promise<ComposerAttachment[]>;
  write(sessionId: string, attachments: ComposerAttachment[]): Promise<unknown>;
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
  const carry = useRef(carrying);
  carry.current = carrying;
  /// A chat was read on this page before: the page's first chat keeps what it was opened with.
  const readOne = useRef(false);

  const send = (sessionId: string, chips: ComposerAttachment[]) => {
    if (!store) return;
    const stored = written.current.sessionId === sessionId ? written.current.stored : new Set<string>();
    written.current = { sessionId, ids: signature(chips), stored };
    const sent = chips.map((chip) => (chip.data && stored.has(chip.id) ? { ...chip, data: undefined } : chip));
    void store.write(sessionId, sent).then(
      () => {
        if (written.current.sessionId !== sessionId) return;
        for (const chip of chips) if (chip.data) written.current.stored.add(chip.id);
      },
      () => undefined,
    );
  };
  const flush = () => {
    const next = pending.current;
    if (!next) return;
    clearTimeout(next.timer);
    pending.current = undefined;
    send(next.sessionId, next.chips);
  };

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
          return back.length || others.length !== held.length ? [...back, ...others].slice(0, MAX_ATTACHMENTS) : held;
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
    if (written.current.sessionId === sessionId && written.current.ids === signature(chips)) return;
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

  // A page closing with a write still resting sends it now.
  // oxlint-disable-next-line react-hooks/exhaustive-deps -- once, at unmount.
  useEffect(() => () => flush(), []);
}

const signature = (chips: readonly ComposerAttachment[]) => chips.map((chip) => chip.id).join("\n");
