// Whether Option is held, the Mac menus' way to show more (a menu's alternate items, Finder's
// "Show Inspector"). The harness updates footer shows its versions only while it is (HarnessUpdates.tsx).
import { useSyncExternalStore } from "react";

// The composer stays mounted while its menus come and go. Keep one observation so a new menu
// immediately sees the modifier the composer already observed, without waiting for another event.
let held = false;
const listeners = new Set<() => void>();
let detach: (() => void) | undefined;
const snapshot = () => held;
const released = () => false;
const inactive = () => () => undefined;
function setHeld(next: boolean) {
  if (held === next) return;
  held = next;
  for (const listener of listeners) listener();
}
function subscribe(listener: () => void) {
  const view = globalThis.window;
  if (!view) return () => undefined;
  if (listeners.size === 0) {
    const key = (event: KeyboardEvent) => setHeld(event.key === "Alt" ? event.type === "keydown" : event.altKey);
    const pointer = (event: MouseEvent) => setHeld(event.altKey);
    const release = () => setHeld(false);
    view.addEventListener("keydown", key, true);
    view.addEventListener("keyup", key, true);
    view.addEventListener("pointermove", pointer, true);
    view.addEventListener("blur", release);
    detach = () => {
      view.removeEventListener("keydown", key, true);
      view.removeEventListener("keyup", key, true);
      view.removeEventListener("pointermove", pointer, true);
      view.removeEventListener("blur", release);
    };
  }
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
    if (listeners.size === 0) {
      detach?.();
      detach = undefined;
      held = false;
    }
  };
}

/// True while Option is down. It reads a keydown or keyup of Option, and the `altKey` of a pointer
/// move (Option held before the menu opened, so no key event came), at capture on the window so a
/// menu that handles its own keys never hides them; leaving the window lets go of it. `enabled` false
/// adds no listeners and reads false (a caller whose experiment arm does not use Option).
export function useOptionHeld(enabled = true): boolean {
  return useSyncExternalStore(enabled ? subscribe : inactive, enabled ? snapshot : released, released);
}
