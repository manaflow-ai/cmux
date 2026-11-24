import { useShortcutKeycapLook } from "./shortcutKeycaps";

/// Whether buttons draw keycaps now: a button that widens for them reads this to drop its fixed size.
export function useShortcutKeycapsOn(shortcut: string | undefined): boolean {
  return useShortcutKeycapLook() !== "off" && !!shortcut;
}
