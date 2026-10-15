// Where the chat's summary (summary/SummaryCard.tsx) shows, as in the ChatGPT desktop app (Leo
// 2026-10-14): always a card pinned under the header's summary button. A press elsewhere never
// closes it; only that button, its close button or Escape does. A pane with room makes room for it:
// the chat's column moves left so the card sits beside the transcript (`push`). A narrow pane lays
// it over the transcript and the chat keeps its width. Resizing between the two moves the chat, not
// the card (summary.css), and an open card stays open.
//
// Closing it is one choice for every chat (localStorage, shared by the panes, which follow each
// other's change), so closing it once is enough. A pane that starts narrow starts with it closed,
// though, so it does not cover a prompt's buttons or an agent's offer until its button opens it.
import { useCallback, useEffect, useId, useState, useSyncExternalStore } from "react";

/// The room the card takes from the chat in a wide pane: its 300px width, 10px from the pane's edge
/// and a 12px gap (summary.css `--acpmux-summary-room`: change both), and the narrowest chat beside it.
export const CARD_ROOM = 322;
const CHAT_MIN_WIDTH = 660;

const KEY = "cmux.acpmux.summaryPanel";
const listeners = new Set<() => void>();
let hidden: boolean | undefined;

function readHidden(): boolean {
  if (hidden !== undefined) return hidden;
  try {
    hidden = globalThis.localStorage?.getItem(KEY) === "hidden";
  } catch {
    hidden = false;
  }
  return hidden;
}

function setHidden(next: boolean) {
  hidden = next;
  try {
    if (next) globalThis.localStorage?.setItem(KEY, "hidden");
    else globalThis.localStorage?.removeItem(KEY);
  } catch {
    // Storage may be absent (tests, private windows): the choice holds for this page.
  }
  for (const listener of listeners) listener();
}

/// Forgets the closed choice: the gallery mounts each variant on a clean slate.
export function resetSummaryCards() {
  setHidden(false);
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  // Another pane's choice.
  const storage = (event: StorageEvent) => {
    if (event.key !== KEY && event.key !== null) return;
    hidden = undefined;
    listener();
  };
  globalThis.addEventListener?.("storage", storage);
  return () => {
    listeners.delete(listener);
    globalThis.removeEventListener?.("storage", storage);
  };
};

/// Whether the pane (the page: the chat fills its webview) has room for the card beside a chat
/// column of CHAT_MIN_WIDTH. `blocked` (a side panel already takes the right) gives no room.
/// It measures the page, not the chat's element: a ref that set state as the chat mounted
/// re-rendered the pane then, and a relaunched new chat lost its kept draft.
export function useSummaryRoom(blocked: boolean): boolean {
  const [room, setRoom] = useState(false);
  useEffect(() => {
    if (blocked) return setRoom(false);
    const page = document.documentElement;
    const measure = () => setRoom(page.clientWidth >= CHAT_MIN_WIDTH + CARD_ROOM);
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(page);
    return () => observer.disconnect();
  }, [blocked]);
  return room;
}

/// The summary of a pane with (`push`) or without room beside the chat for the card. It stays open
/// as the pane changes between the two.
export function useSummaryCard(push: boolean) {
  const closed = useSyncExternalStore(subscribe, readHidden, () => false);
  // Open in this pane without room: it was open beside the chat, or its button opened it here.
  const [kept, setKept] = useState(false);
  useEffect(() => {
    if (push && !closed) setKept(true);
  }, [push, closed]);
  const shown = !closed && (push || kept);
  const show = useCallback(() => {
    setKept(true);
    setHidden(false);
  }, []);
  const close = useCallback(() => {
    setKept(false);
    setHidden(true);
  }, []);
  const toggle = useCallback(() => (shown ? close() : show()), [shown, close, show]);
  // The card's id, for the header's button (aria-controls).
  const id = useId();
  return { id, shown, push, toggle, show, close };
}

export type SummaryCardControl = ReturnType<typeof useSummaryCard>;
