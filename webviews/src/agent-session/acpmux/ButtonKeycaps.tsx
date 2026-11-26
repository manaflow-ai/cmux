import "./buttonKeycaps.css";
import { KeyHint } from "../../ui/KeyHint";
import { splitShortcutKeycaps, useShortcutKeycapLook } from "./shortcutKeycaps";

/// A button's shortcut drawn inside it with the one key hint (ui/KeyHint; shortcut-keycaps experiment). Nothing while the
/// experiment is off or the action has no shortcut, so the button is exactly today's. Decoration
/// only: the button keeps its label as its accessible name and the key in its tooltip.
export function ShortcutKeycaps({ shortcut }: { shortcut: string | undefined }) {
  const look = useShortcutKeycapLook();
  if (look === "off" || !shortcut) return null;
  if (splitShortcutKeycaps(shortcut).length === 0) return null;
  return (
    <span className="acpmux-button-shortcut" data-look={look} aria-hidden="true">
      <KeyHint keys={shortcut} />
    </span>
  );
}

/// Whether buttons draw keycaps now: a button that widens for them reads this to drop its fixed size.
export function useShortcutKeycapsOn(shortcut: string | undefined): boolean {
  return useShortcutKeycapLook() !== "off" && !!shortcut;
}
