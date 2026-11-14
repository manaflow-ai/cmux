// How a finished line ends: in the running tray's lines (AgentLine.tsx) and in the composer hat's header
// when it holds one finished item (SubagentTray.tsx). Leo, 2026-11-07, on "Done · 8m 12s": "I just feel
// like there's something off about this ... I know that the thing is aligned, but it just doesn't look
// that... Great." The default is a bare check stroke in a muted success colour and the total in tabular figures;
// the word stays for screen readers. hatParts.experiment.ts holds the arms.
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";

/// The arms of hatParts.experiment.ts `hatDoneLook`.
export type DoneLook = "check" | "words" | "accent" | "time";

const CHECK = rowIconSize(12);

/// The check alone, in a finished line's Stop slot (AgentLine.tsx) or after a lone item's time in the hat's
/// header: the same size and column as the Stop square it takes over, so nothing moves when a line ends
/// (Leo, 2026-11-07: "instead of the done on the left, you can just put like a check mark right where this
/// stop square would be").
export function DoneCheck() {
  return (
    <span className="acpmux-done-mark__check" data-done-check aria-hidden="true">
      <Icon name="status.check" size={CHECK} row />
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
  time?: string;
  look: DoneLook;
  /// The `check` look draws its check in the Stop slot (`DoneCheck`), not before the time.
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
    <span className="acpmux-done-mark" data-hat-done data-look={look}>
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
