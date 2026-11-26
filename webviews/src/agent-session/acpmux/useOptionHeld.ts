// Whether Option is held, the Mac menus' way to show more (a menu's alternate items, Finder's
// "Show Inspector"). The harness updates footer shows its versions only while it is (HarnessUpdates.tsx).
import { useEffect, useState } from "react";

/// True while Option is down. It reads a keydown or keyup of Option, and the `altKey` of a pointer
/// move (Option held before the menu opened, so no key event came), at capture on the window so a
/// menu that handles its own keys never hides them; leaving the window lets go of it.
export function useOptionHeld(): boolean {
  const [held, setHeld] = useState(false);
  useEffect(() => {
    const view = globalThis.window;
    if (!view) return;
    const key = (event: KeyboardEvent) => setHeld(event.key === "Alt" ? event.type === "keydown" : event.altKey);
    const pointer = (event: MouseEvent) => setHeld(event.altKey);
    const release = () => setHeld(false);
    view.addEventListener("keydown", key, true);
    view.addEventListener("keyup", key, true);
    view.addEventListener("pointermove", pointer, true);
    view.addEventListener("blur", release);
    return () => {
      view.removeEventListener("keydown", key, true);
      view.removeEventListener("keyup", key, true);
      view.removeEventListener("pointermove", pointer, true);
      view.removeEventListener("blur", release);
    };
  }, []);
  return held;
}
