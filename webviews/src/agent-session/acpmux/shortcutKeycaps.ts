import { createContext, useContext } from "react";
import { experimentArm } from "../../experiments/experiment";
import { shortcutKeycaps, type ShortcutKeycapLook } from "./shortcutKeycaps.experiment";

/// Modifier glyphs as the host draws them (Shortcut+Display.swift modifierGlyphs), with their
/// `aria-keyshortcuts` names.
const MODIFIERS: Readonly<Record<string, string>> = { "⌃": "Control", "⌥": "Alt", "⇧": "Shift", "⌘": "Meta" };

/// Key glyphs the host draws for non-printing keys (Shortcut+Display.swift keyGlyph), as
/// `aria-keyshortcuts` key names.
const KEY_NAMES: Readonly<Record<string, string>> = {
  "↑": "ArrowUp",
  "↓": "ArrowDown",
  "←": "ArrowLeft",
  "→": "ArrowRight",
  "↩": "Enter",
  "⇥": "Tab",
  "⎋": "Escape",
  "⌫": "Backspace",
};

/// A shortcut's display string as one cap per key, in order: "⇧⌘P" is ["⇧", "⌘", "P"]. A chord
/// ("⌘K ⌘S") keeps its strokes apart, so the result is one list of caps per stroke. The key after
/// the modifiers stays whole ("F12", "Space").
export function splitShortcutKeycaps(display: string | undefined): string[][] {
  if (!display) return [];
  return display
    .trim()
    .split(/\s+/)
    .filter(Boolean)
    .map((stroke) => {
      const caps: string[] = [];
      const chars = Array.from(stroke);
      let index = 0;
      while (index < chars.length && chars[index]! in MODIFIERS) caps.push(chars[index++]!);
      const key = chars.slice(index).join("");
      if (key) caps.push(key);
      return caps;
    });
}

/// The display string in `aria-keyshortcuts` syntax: "⇧⌘P" is "Shift+Meta+P", a chord's strokes
/// joined by a space. Undefined when there is no shortcut.
export function ariaKeyshortcuts(display: string | undefined): string | undefined {
  const strokes = splitShortcutKeycaps(display);
  if (strokes.length === 0) return undefined;
  return strokes.map((caps) => caps.map((cap) => MODIFIERS[cap] ?? KEY_NAMES[cap] ?? cap).join("+")).join(" ");
}

/// The gallery pins a look here; the app leaves it unset and reads the experiment.
export const ShortcutKeycapLookContext = createContext<ShortcutKeycapLook | undefined>(undefined);

/// The keycap look buttons draw now: the gallery's pin, else the experiment's arm (off by default).
export function useShortcutKeycapLook(): ShortcutKeycapLook {
  return useContext(ShortcutKeycapLookContext) ?? experimentArm(shortcutKeycaps);
}
