import "./buttonKeycaps.css";
import { splitShortcutKeycaps, useShortcutKeycapLook } from "./shortcutKeycaps";

/// A button's shortcut drawn inside it as keycaps (shortcut-keycaps experiment). Nothing while the
/// experiment is off or the action has no shortcut, so the button is exactly today's. Decoration
/// only: the button keeps its label as its accessible name and the key in its tooltip.
export function ShortcutKeycaps({ shortcut }: { shortcut: string | undefined }) {
  const look = useShortcutKeycapLook();
  if (look === "off" || !shortcut) return null;
  const strokes = splitShortcutKeycaps(shortcut);
  if (strokes.length === 0) return null;
  return (
    <span className="acpmux-shortcut-keycaps" data-look={look} aria-hidden="true">
      {look === "compact" ? (
        <kbd className="acpmux-shortcut-keycap">{strokes.map((caps) => caps.join("")).join(" ")}</kbd>
      ) : (
        strokes.map((caps, stroke) => (
          <span key={stroke} className="acpmux-shortcut-keycaps-stroke">
            {caps.map((cap, index) => (
              <kbd key={index} className="acpmux-shortcut-keycap">
                {cap}
              </kbd>
            ))}
          </span>
        ))
      )}
    </span>
  );
}
