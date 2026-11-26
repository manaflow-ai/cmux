// How a finished line ends: in the running tray's lines (AgentLine.tsx) and in the composer hat's header
// when it holds one finished item (SubagentTray.tsx). Leo, 2026-11-07, on "Done · 8m 12s": "I just feel
// like there's something off about this ... I know that the thing is aligned, but it just doesn't look
// that... Great." The default is a bare check stroke in the line's muted ink (no success green: an ended line is no
// success state, Leo 2026-11-14) and the total in tabular figures;
// the word stays for screen readers. hatParts.experiment.ts holds the arms.
import type { ReactNode } from "react";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";

/// The arms of hatParts.experiment.ts `hatDoneLook`.
export type DoneLook = "check" | "words" | "accent" | "time";

/// The hat's icon size (the chevron's, the panel button's, a line's own glyph), drawn on the full 24-unit
/// grid as the Stop square is rather than the row icon's cropped one: the hat's stroke weight, and an ink
/// box the Stop square's size, so the check that takes the square's place reads as the same mark (Leo,
/// 2026-11-08, on "47s ✓": "when you look at the symbol and size/whatnot of it it just feels iffy"). As a
/// cropped row icon its ink was 10.3px wide beside the square's 7.5.
const CHECK = rowIconSize(12);

/// The check alone, in a finished line's Stop slot (AgentLine.tsx) or after a lone item's time in the hat's
/// header: the same size and column as the Stop square it takes over, so nothing moves when a line ends
/// (Leo, 2026-11-07: "instead of the done on the left, you can just put like a check mark right where this
/// stop square would be").
export function DoneCheck() {
  return (
    <span className="acpmux-done-mark__check" data-done-check aria-hidden="true">
      <Icon name="status.check" size={CHECK} />
    </span>
  );
}

export function DoneMark({
  state,
  time,
  look,
  checkInSlot = false,
}: {
  state: string;
  time?: ReactNode;
  look: DoneLook;
  /// The `check` look draws its check in the Stop slot (`DoneCheck`), not before the time. After a lone
  /// item's time on the hat's folded header, the check is centred in a Stop-wide column of its own one tray
  /// gap after the time (`data-place="column"`, subagents.css), so the digits keep a line's time-to-Stop
  /// spacing and never hug the check (Leo, 2026-11-08, on "47s ✓": "it just feels iffy how it's close the
  /// the number but idk if it should be so close"). Right after the time, or in the header's leading icon
  /// column with the time alone at the end, lost in the gallery.
  checkInSlot?: boolean;
}) {
  if (look === "words")
    return (
      <span className="acpmux-done-mark" data-hat-done data-look={look}>
        <span className="acpmux-done-mark__word">{state}</span>
        {time !== undefined && (
          <>
            <span className="acpmux-done-mark__sep" aria-hidden="true">
              ·
            </span>
            <span className="acpmux-done-mark__time">{time}</span>
          </>
        )}
      </span>
    );
  return (
    <span
      className="acpmux-done-mark"
      data-hat-done
      data-look={look}
      data-place={checkInSlot && time !== undefined ? "column" : undefined}
    >
      {look === "check" && !checkInSlot && <DoneCheck />}
      {look === "accent" ? (
        <span className="acpmux-done-mark__word">{state}</span>
      ) : (
        <span className="acpmux-agent-line__sr">{state}</span>
      )}
      {time !== undefined && <span className="acpmux-done-mark__time">{time}</span>}
      {look === "check" && checkInSlot && time !== undefined && <DoneCheck />}
    </span>
  );
}
