// Each chat's composer hat (SubagentTray.tsx): hidden or N rows tall, and the height it last had
// open (hatRows.ts). The hat starts folded to its one line header: a list of commands and subagents
// above the composer took the transcript's room (https://github.com/manaflow-ai/cmux/issues/28875).
// The person's click, drag or keys hold for that chat, across a switch to another chat and back (the
// tray remounts per chat, App.tsx `key={shownSessionId}`), for as long as the pane lives. Bounded: the
// chats least recently shown or changed drop first. App.tsx reads `useHatState` too: a chat whose hat
// was dragged away shows the pull tab (TrayPullTab.tsx) in its place.
import { useSyncExternalStore } from "react";
import { type HatAction, HAT_DEFAULT_ROWS, HAT_FOLDED, hatReducer, type HatState } from "./hatRows";

const MAX_CHATS = 200;
const states = new Map<string, HatState>();
const listeners = new Set<() => void>();

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};

/// The chat's hat as the person left it; folded when they never touched it.
export const hatStateFor = (chat: string | undefined): HatState =>
  (chat === undefined ? undefined : states.get(chat)) ?? HAT_FOLDED;

/// Sets the chat's hat to `next` and tells every reader, when it changed.
export function setHatState(chat: string | undefined, next: HatState): void {
  if (chat === undefined) return;
  const before = states.get(chat);
  states.delete(chat);
  states.set(chat, next);
  if (states.size > MAX_CHATS) states.delete(states.keys().next().value!);
  if (before !== next) for (const listener of listeners) listener();
}

/// Applies `action` to the chat's hat (hatRows.ts `hatReducer`).
export function dispatchHat(chat: string | undefined, action: HatAction): HatState {
  const next = hatReducer(hatStateFor(chat), action);
  setHatState(chat, next);
  return next;
}

/// The chat's hat, drawn again when it changes.
export function useHatState(chat: string | undefined): HatState {
  const snapshot = () => hatStateFor(chat);
  return useSyncExternalStore(subscribe, snapshot, snapshot);
}

/// The person's last choice for this chat's hat: open (more than its header) or folded; undefined
/// until they changed it.
export function trayOpenFor(chat: string | undefined): boolean | undefined {
  const state = chat === undefined ? undefined : states.get(chat);
  if (state === undefined || state.view.kind === "hidden") return undefined;
  setHatState(chat, state);
  return state.view.rows > 1;
}

/// Opens this chat's hat to its last height, or folds it to its header (`fallback`: the rows an
/// open takes when it never had a height of its own).
export function rememberTrayOpen(chat: string | undefined, open: boolean, fallback?: number): void {
  if (chat === undefined) return;
  const state = hatStateFor(chat);
  // The pull tab's click brings a hidden hat back as it asks.
  const action: HatAction =
    state.view.kind === "hidden"
      ? { type: "show", open, fallback: fallback ?? DEFAULT_FALLBACK }
      : { type: "open", open, fallback: fallback ?? DEFAULT_FALLBACK };
  setHatState(chat, hatReducer(state, action));
}

/// The rows an open takes with no height of its own: the header and the default five lines. The
/// tray passes the height the person last gave any hat (trayResize.ts) where it has one.
const DEFAULT_FALLBACK = HAT_DEFAULT_ROWS;

/// The chat a drag from its pull tab is bringing the hat back in (hatDrag.ts), while it runs: the hat
/// shows as it comes back, even where the chat's look tucks every hat away.
let pulling: string | undefined;
export function setHatPulling(chat: string | undefined): void {
  if (pulling === chat) return;
  pulling = chat;
  for (const listener of listeners) listener();
}

/// Whether a drag from the chat's pull tab is bringing its hat back now.
export const hatPullingNow = (chat: string | undefined): boolean => chat !== undefined && pulling === chat;

/// Whether the chat shows its pull tab instead of its hat: the person dragged it away, or the chat's
/// look tucks every hat away (`tucked`, chatDisplay.ts) and no drag is bringing it back.
export function useHatPulled(chat: string | undefined, tucked: boolean): boolean {
  const snapshot = () =>
    hatStateFor(chat).view.kind === "hidden" || (tucked && (chat === undefined || pulling !== chat));
  return useSyncExternalStore(subscribe, snapshot, snapshot);
}

/// Tests only: forget every chat's hat.
export function resetTrayOpenMemory(): void {
  pulling = undefined;
  states.clear();
  for (const listener of listeners) listener();
}
