// Whether the model chip draws its provider's logo left of the model's name (cmux#38053). On (the
// default), off from the chip's right-click (ModelPicker.tsx; Leo 2026-11-08: "we can keep this as
// defualt for now but let's add toggle and make right clicking the model picker let you
// customize"). It is the viewer's choice for every composer in the app, kept in cmux-next.json as
// `agentPane.display.modelChipIcon` (Settings > Agent Chat > Model Logo in Composer), which the
// host sends with the chat's keys (chatDisplay.ts) and writes when the chip's menu changes it
// (`pane.setDisplay`). localStorage is only this launch's copy: the agent pages' store is not
// persistent, so a choice kept only there was lost at every restart, as the composer's look once was
// before cmux#43272. Until the host's value comes, the launch's copy shows; once it came, it wins.
import { useSyncExternalStore } from "react";
import {
  changeChatDisplay,
  notePickedElsewhere,
  MODEL_CHIP_ICON_KEY,
  pickedDisplayValue,
  subscribeChatDisplay,
} from "./chatDisplay";

const STORAGE_KEY = "cmux.acpmux.modelChipIcon";

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

/** Whether the model chip draws its provider's logo: the host's value once it came, else this launch's. */
export function modelChipIconShown(): boolean {
  const kept = pickedDisplayValue(MODEL_CHIP_ICON_KEY);
  return kept === undefined ? on : kept !== false;
}

/** Shows or hides the model chip's logo in every composer, and keeps the choice. */
export function setModelChipIcon(next: boolean) {
  if (next === modelChipIconShown()) return;
  on = next;
  try {
    if (next) globalThis.localStorage?.removeItem(STORAGE_KEY);
    else globalThis.localStorage?.setItem(STORAGE_KEY, "off");
  } catch {
    // A blocked store keeps the choice for this page only.
  }
  // On is the default: the file keeps only an off.
  changeChatDisplay(MODEL_CHIP_ICON_KEY, next ? null : false);
  for (const listener of listeners) listener();
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  // Another page (another chat's tab, the New Tab page) changed it in this launch.
  const changed = (event: StorageEvent) => {
    if (event.key !== STORAGE_KEY && event.key !== null) return;
    on = stored();
    // Another page's pick is the newest: it stands over the host's last value until the host's push.
    if (event.key === STORAGE_KEY) notePickedElsewhere(MODEL_CHIP_ICON_KEY, on ? null : false);
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

export function useModelChipIcon(): boolean {
  return useSyncExternalStore(subscribe, modelChipIconShown, modelChipIconShown);
}
