// Whether a pasted or dropped image goes into the prompt's text at the caret as well as into the
// strip above it (Leo, 2026-10-25: "the actual input, as a default, I don't think it's gonna be
// worse to put the things inline, like how iMessage on Mac does it"; "i think it'd be interesting
// to ALSO show the top displayed attachments alongside the inline attachments... maybe as toggle
// maybe both?"). On, the default: inline and in the strip. Off: the strip only, as before. The
// prompt's right-click menu turns it off and on (Composer.tsx). It is the page's own choice, kept in
// local storage for every chat and followed by every open page, as queueing.ts is.
import { useSyncExternalStore } from "react";

const STORAGE_KEY = "cmux.acpmux.inlineAttachments";

function stored(): boolean {
  try {
    return globalThis.localStorage?.getItem(STORAGE_KEY) !== "off";
  } catch {
    return true;
  }
}

let on = stored();
const listeners = new Set<() => void>();

/** Whether a pasted or dropped image goes into the prompt's text. */
export function inlinePlacementOn(): boolean {
  return on;
}

/** Turns inline placement on or off for every chat, and keeps the choice. */
export function setInlinePlacement(next: boolean) {
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

export function useInlinePlacement(): boolean {
  return useSyncExternalStore(subscribe, inlinePlacementOn, inlinePlacementOn);
}
