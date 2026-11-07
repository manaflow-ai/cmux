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

export function DoneMark({ state, time, look }: { state: string; time?: string; look: DoneLook }) {
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
      {look === "check" && (
        <span className="acpmux-done-mark__check" aria-hidden="true">
          <Icon name="status.check" size={CHECK} row />
        </span>
      )}
      {look === "accent" ? (
        <span className="acpmux-done-mark__word">{state}</span>
      ) : (
        <span className="acpmux-agent-line__sr">{state}</span>
      )}
      {time !== undefined && <span className="acpmux-done-mark__time">{time}</span>}
    </span>
  );
}
