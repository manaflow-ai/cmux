// ⌃S in a composer (the chat's, the New Tab page's): the draft goes on its chat's stack in acpmux
// (draftStash.ts) and the prompt empties; on an empty prompt, or a pick from the Stashed chip, the
// newest (or the picked) one comes back, before whatever was typed meanwhile, so nothing typed is
// ever replaced. The composer gives its own draft's reads and writes.
import { useEffect, useRef } from "react";
import type { ComposerAttachment } from "../attachments";
import { dropStashed, readStashed, stashDraft, useStash } from "./draftStash";

export type HeldDraft = { text: string; attachments: ComposerAttachment[] };

export type StashedComposer = {
  /// The draft as the prompt holds it now (no shell-run chips).
  held(): HeldDraft;
  /// Empties the prompt and its chips.
  clear(): void;
  /// Whether the prompt is not ready for a stash or a restore: an attachment still loading (its
  /// contents are not in the draft yet, and clearing would cancel it), or the chat's own draft
  /// still being read back over it. ⌃S and a pick wait, and the draft stays where it is.
  loading(): boolean;
  /// Puts a draft back in the prompt, before what is typed there.
  restore(text: string, attachments: ComposerAttachment[]): void;
  focus(): void;
};

/// Whether `event` is ⌃S and nothing else.
export const isStashKey = (event: KeyboardEvent): boolean =>
  event.key === "s" && event.ctrlKey && !event.metaKey && !event.altKey && !event.shiftKey;

export function useDraftStash(chat: string, composer: StashedComposer) {
  const stashed = useStash(chat);
  const io = useRef(composer);
  io.current = composer;
  // Whether the composer still shows `chat`: a stash's answer for a chat it left, or after it
  // closed, changes nothing here (the draft stays stashed, or stays where it was).
  const shownChat = useRef(chat);
  shownChat.current = chat;
  const mounted = useRef(true);
  useEffect(() => {
    mounted.current = true;
    return () => void (mounted.current = false);
  }, []);
  const showing = (on: string) => mounted.current && shownChat.current === on;
  // Still the draft `held` (a stash waits on acpmux's answer): what was typed since stays.
  const stillHeld = (held: HeldDraft) => {
    const now = io.current.held();
    return (
      now.text === held.text &&
      now.attachments.length === held.attachments.length &&
      // The same chips, unchanged: one that changed since (an original's upload retried, adding its
      // path) is not what acpmux holds.
      now.attachments.every((chip, index) => chip === held.attachments[index])
    );
  };
  // One stash or restore at a time, each to its end (a restore's drop included): a second ⌃S while
  // acpmux takes the draft would stash it twice, a second pick would put both back and drop both,
  // and a stash while a restore's drop is out could land first on a full stack and let an older
  // draft go before the drop frees its place.
  const busy = useRef(false);
  const stash = () => {
    if (busy.current) return;
    busy.current = true;
    const on = chat;
    const held = io.current.held();
    // The prompt empties once acpmux holds the draft; a refusal leaves it as it was.
    void stashDraft(on, held.text, held.attachments)
      .then((done) => done && showing(on) && stillHeld(held) && !io.current.loading() && io.current.clear())
      .finally(() => {
        busy.current = false;
      });
  };
  const unstash = (id?: string) => {
    const on = chat;
    const target = id ?? stashed[0]?.id;
    if (!target || busy.current || io.current.loading()) return;
    busy.current = true;
    void (async () => {
      // Read whole, put back before what the prompt holds, and dropped only once this composer has
      // it again in the same chat: until then acpmux keeps it, so a page that goes loses nothing.
      const entry = await readStashed(on, target);
      if (!entry || !showing(on) || io.current.loading()) return;
      io.current.restore(entry.text, entry.attachments);
      io.current.focus();
      // Dropped once the composer has drawn it back, and only while it still shows the chat: one
      // closed or switched away first keeps the stashed copy.
      await new Promise((resolve) => requestAnimationFrame(() => resolve(undefined)));
      if (showing(on)) await dropStashed(on, entry.id);
    })().finally(() => {
      busy.current = false;
    });
  };
  /// ⌃S: a draft is stashed (one acpmux does not take stays in the prompt); an empty prompt
  /// brings the newest stashed one back. While an attachment loads it does neither.
  const toggle = () => {
    if (io.current.loading()) {
      io.current.focus();
      return;
    }
    const held = io.current.held();
    if (held.text.trim() || held.attachments.length) stash();
    else unstash();
    io.current.focus();
  };
  return { stashed, unstash, toggle };
}
