// Whether the model chip draws its provider's logo left of the model's name (cmux#38053). On (the
// default), off from the chip's right-click (ModelPicker.tsx; Leo 2026-11-08: "we can keep this as
// defualt for now but let's add toggle and make right clicking the model picker let you
// customize"). It is the page's own choice, kept in local storage for every composer in the app and
// followed by every open page, as queueing.ts is. It is not a cmux.json key yet: a new setting's
// default needs a defaults call (scripts/ci/defaults_guard.py).
import { useSyncExternalStore } from "react";

const STORAGE_KEY = "cmux.acpmux.modelChipIcon";

function stored(): boolean {
  try {
    return globalThis.localStorage?.getItem(STORAGE_KEY) !== "off";
  } catch {
    return true;
  }
}

let on = stored();
const listeners = new Set<() => void>();

/** Whether the model chip draws its provider's logo. */
export function modelChipIconShown(): boolean {
  return on;
}

/** Shows or hides the model chip's logo in every composer, and keeps the choice. */
export function setModelChipIcon(next: boolean) {
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
  // Another page (another chat's tab, the New Tab page) changed it.
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

export function useModelChipIcon(): boolean {
  return useSyncExternalStore(subscribe, modelChipIconShown, modelChipIconShown);
}
