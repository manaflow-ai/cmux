// The one muted line of a turn the agent ran on its own (backgroundTurns.ts): "Background task
// finished", "Scheduled check" or "Background update". While the turn runs it leads with the working
// spinner; once it ended quiet it leads with the clock. A click opens the turn's rows under it, which
// the transcript draws as its own rows (turns.ts), so the open state is the transcript's fold set,
// kept per chat like a "Worked for" fold, and survives virtualization. A run of background-task
// notifications folded under one line (backgroundRuns.ts) draws here too, the same line in the same
// look: "4 background tasks finished".
import { useT } from "../i18n";
import type { AcpmuxRow } from "../model";
import { backgroundRunLabel } from "./backgroundRuns";
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
  const run = row.backgroundRun;
  if (run) {
    const label = backgroundRunLabel(t, run);
    return (
      <TranscriptActivityRow
        icon={<Clock />}
        before={label}
        className="cv-background-turn"
        ariaLabel={label}
        expanded={expanded}
        attributes={{
          "aria-expanded": String(expanded),
          "data-find-skip": "",
          "data-background-turn": "run",
        }}
        onClick={onToggle}
      />
    );
  }
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
