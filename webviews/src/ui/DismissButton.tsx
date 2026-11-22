// The one close × of a card that can be put away (ui/Notice.tsx, the agent pane's composer hat,
// question/HatQuestions.tsx). Leo, 2026-11-11, on the hat's question from a started chat: "there's
// no close button :(".
//
// It always holds its room in the card's layout: `reveal="hover"` only fades it in while the pointer
// is over its card or the focus is inside it (the card marks itself `data-dismiss-host`), so a
// hover never moves a word and the card's text is cut to the room left beside it either way. Escape
// is the card's to wire (Notice: inside it; the hat: while the focus is in it), as only the card knows
// what dismissing means. Its glyph is drawn here, 12 by 12, so every card closes with the same ×.
import { Button } from "./Button";
import { cx } from "./cx";
import "./dismiss.css";

export function DismissButton({
  label,
  onDismiss,
  reveal = "always",
  className,
}: {
  /** The ×'s accessible name and tooltip ("Dismiss"). */
  label: string | undefined;
  onDismiss(): void;
  /** always: shown at rest. hover: faded in while its `data-dismiss-host` card is hovered or focused. */
  reveal?: "always" | "hover";
  className?: string;
}) {
  return (
    <Button
      variant="ghost"
      size="sm"
      icon
      className={cx("ui-dismiss", className)}
      data-reveal={reveal}
      aria-label={label}
      /* tooltip-allow: the × has no text; the tooltip names it */
      title={label}
      onClick={onDismiss}
    >
      <svg viewBox="0 0 12 12" width="12" height="12" aria-hidden="true">
        <path d="M3 3l6 6M9 3l-6 6" stroke="currentColor" strokeWidth="1.25" strokeLinecap="round" />
      </svg>
    </Button>
  );
}
