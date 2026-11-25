// Whether a prompt sent while a turn runs waits in the queue. On (the default), Return steers it
// into the turn and ⌘Return or Send queues it for after the turn (Composer.tsx). Off, as ChatGPT's
// and Codex's "Turn off queueing" (Leo, 2026-10-21), ⌘Return and Send steer too, so nothing new
// waits; an agent that cannot steer still runs it after the turn, which is all it can do.
//
// A queued row's ⋯ menu turns it off (ComposerQueue.tsx) and back on; so does a right-click on the
// composer's button row while it is off (composerChrome.tsx). It is the viewer's choice for every
// chat in the app, kept in cmux-next.json as `agentPane.display.queueing` (Settings > Agent Chat >
// Queue Prompts During a Turn), which the host sends with the chat's keys (chatDisplay.ts) and
// writes when a menu changes it (`pane.setDisplay`). localStorage is only this launch's copy: the
// agent pages' store is not persistent, so a choice kept only there was lost at every restart, as
// the composer's look once was. Until the host's value comes, the launch's copy holds.
import { useSyncExternalStore } from "react";
import {
  changeChatDisplay,
  notePickedElsewhere,
  pickedDisplayValue,
  QUEUEING_KEY,
  subscribeChatDisplay,
} from "./chatDisplay";

const STORAGE_KEY = "cmux.acpmux.queueing";

/// This launch's copy in storage.
function stored(): boolean {
  try {
    return globalThis.localStorage?.getItem(STORAGE_KEY) !== "off";
  } catch {
    return true;
  }
}

/// The page's copy, for a page whose storage is blocked.
let on = stored();
const listeners = new Set<() => void>();

/** Whether a prompt sent mid-turn can wait in the queue: the host's value once it came, else this launch's. */
export function queueingOn(): boolean {
  const kept = pickedDisplayValue(QUEUEING_KEY);
  return kept === undefined ? on : kept !== false;
}

/** Turns queueing on or off for every chat, and keeps the choice. */
export function setQueueing(next: boolean) {
  if (next === queueingOn()) return;
  on = next;
  try {
    if (next) globalThis.localStorage?.removeItem(STORAGE_KEY);
    else globalThis.localStorage?.setItem(STORAGE_KEY, "off");
  } catch {
    // A blocked store keeps the choice for this page only.
  }
  // On is the default: the file keeps only an off.
  changeChatDisplay(QUEUEING_KEY, next ? null : false);
  for (const listener of listeners) listener();
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  // Another page (another chat's tab) changed it in this launch.
  const changed = (event: StorageEvent) => {
    if (event.key !== STORAGE_KEY && event.key !== null) return;
    on = stored();
    // Another page's pick is the newest: it stands over the host's last value until the host's push.
    if (event.key === STORAGE_KEY) notePickedElsewhere(QUEUEING_KEY, on ? null : false);
    listener();
  };
  globalThis.addEventListener?.("storage", changed);
  // The host's value came or changed.
  const unfollow = subscribeChatDisplay(listener);
  return () => {
    listeners.delete(listener);
    globalThis.removeEventListener?.("storage", changed);
    unfollow();
  };
}

export function useQueueing(): boolean {
  return useSyncExternalStore(subscribe, queueingOn, queueingOn);
}
