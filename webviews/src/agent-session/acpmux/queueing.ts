// Whether a prompt sent while a turn runs waits in the queue. On (the default), Return steers it
// into the turn and ⌘Return or Send queues it for after the turn (Composer.tsx). Off, as ChatGPT's
// and Codex's "Turn off queueing" (Leo, 2026-10-21), ⌘Return and Send steer too, so nothing new
// waits; an agent that cannot steer still runs it after the turn, which is all it can do.
//
// A queued row's ⋯ menu turns it off (ComposerQueue.tsx) and back on; so does a right-click on the
// composer's button row while it is off (composerChrome.tsx). It is the page's own choice, kept in
// local storage for every chat in the app, and followed by every open page. It is not a cmux.json
// key yet: a new setting's default needs a defaults call (scripts/ci/defaults_guard.py).
import { useSyncExternalStore } from "react";

const STORAGE_KEY = "cmux.acpmux.queueing";

function stored(): boolean {
  try {
    return globalThis.localStorage?.getItem(STORAGE_KEY) !== "off";
  } catch {
    return true;
  }
}

let on = stored();
const listeners = new Set<() => void>();

/** Whether a prompt sent mid-turn can wait in the queue. */
export function queueingOn(): boolean {
  return on;
}

/** Turns queueing on or off for every chat, and keeps the choice. */
export function setQueueing(next: boolean) {
  if (next === on) return;
  on = next;
  try {
    if (next) globalThis.localStorage?.removeItem(STORAGE_KEY);
    else globalThis.localStorage?.setItem(STORAGE_KEY, "off");
  } catch {
    // A blocked store keeps the choice for this page only.
  }
  for (const listener of listeners) listener();
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  // Another page (another chat's tab) changed it.
  const changed = (event: StorageEvent) => {
    if (event.key !== STORAGE_KEY && event.key !== null) return;
    const next = stored();
    if (next === on) return;
    on = next;
    for (const each of listeners) each();
  };
  globalThis.addEventListener?.("storage", changed);
  return () => {
    listeners.delete(listener);
    globalThis.removeEventListener?.("storage", changed);
  };
}

export function useQueueing(): boolean {
  return useSyncExternalStore(subscribe, queueingOn, queueingOn);
}
