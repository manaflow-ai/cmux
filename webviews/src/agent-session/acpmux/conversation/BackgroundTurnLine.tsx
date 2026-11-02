// The one muted line of a turn the agent ran on its own (backgroundTurns.ts): "Background task
// finished", "Scheduled check" or "Background update". While the turn runs it leads with the working
// spinner; once it ended quiet it leads with the clock. A click opens the turn's rows under it, which
// the transcript draws as its own rows (turns.ts), so the open state is the transcript's fold set,
// kept per chat like a "Worked for" fold, and survives virtualization.
import { useT } from "../i18n";
import type { AcpmuxRow } from "../model";
import { backgroundTurnLabel } from "./backgroundTurns";
import { Clock, Spinner } from "./icons";
import { TranscriptActivityRow } from "./TranscriptActivityRow";

export function BackgroundTurnLine({
  row,
  expanded,
  onToggle,
}: {
  row: AcpmuxRow;
  expanded: boolean;
  onToggle: () => void;
}) {
  const t = useT();
  const turn = row.background;
  if (!turn) return null;
  const label = backgroundTurnLabel(t, turn);
  return (
    <TranscriptActivityRow
      icon={turn.running ? <Spinner /> : <Clock />}
      before={label}
      className="cv-background-turn"
      ariaLabel={label}
      expanded={expanded}
      attributes={{
        "aria-expanded": String(expanded),
        "data-find-skip": "",
        "data-background-turn": turn.running ? "running" : "quiet",
      }}
      onClick={onToggle}
    />
  );
}
