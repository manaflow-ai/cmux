// Where the chat's summary (summary/SummaryCard.tsx) shows, as in the ChatGPT desktop app
// (Lawrence 2026-10-14: "persistent, not a popover"). A pane with room docks it as a column right
// of the chat: always there, a click elsewhere never closes it, on until the person hides it. A
// narrow pane makes it a popover under the header's summary button, closed until that button opens
// it, closed again by a press outside it or Escape.
//
// Hiding the docked panel is one choice for every chat (localStorage, shared by the panes, which
// follow each other's change), so hiding it once is enough. The popover is the pane's own moment.
import { useCallback, useEffect, useId, useState, useSyncExternalStore } from "react";

/// The docked panel's width (summary.css's dock `flex` basis: change both), and the narrowest chat
/// column beside it.
export const DOCK_WIDTH = 300;
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

/// Forgets the hidden choice: the gallery mounts each variant on a clean slate.
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

/// Whether the pane (the page: the chat fills its webview) has room for the docked panel beside a
/// chat column of CHAT_MIN_WIDTH. `blocked` (a side panel already takes the right) gives no room.
/// It measures the page, not the chat's element: a ref that set state as the chat mounted
/// re-rendered the pane then, and a relaunched new chat lost its kept draft.
export function useDockRoom(blocked: boolean): boolean {
  const [room, setRoom] = useState(false);
  useEffect(() => {
    if (blocked) return setRoom(false);
    const page = document.documentElement;
    const measure = () => setRoom(page.clientWidth >= CHAT_MIN_WIDTH + DOCK_WIDTH);
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(page);
    return () => observer.disconnect();
  }, [blocked]);
  return room;
}

/// The summary of a pane with (`docked`) or without room for the docked panel.
export function useSummaryCard(docked: boolean) {
  const dockHidden = useSyncExternalStore(subscribe, readHidden, () => false);
  const [popover, setPopover] = useState(false);
  // A pane that gains room docks the panel; one that loses it starts with the popover closed.
  useEffect(() => setPopover(false), [docked]);
  const shown = docked ? !dockHidden : popover;
  const show = useCallback(() => (docked ? setHidden(false) : setPopover(true)), [docked]);
  const close = useCallback(() => (docked ? setHidden(true) : setPopover(false)), [docked]);
  const toggle = useCallback(() => (shown ? close() : show()), [shown, close, show]);
  // The panel's id, for the header's button (aria-controls).
  const id = useId();
  return { id, shown, docked, toggle, show, close };
}

export type SummaryCardControl = ReturnType<typeof useSummaryCard>;
