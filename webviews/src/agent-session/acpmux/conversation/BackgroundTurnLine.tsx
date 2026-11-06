// The one muted line of a turn the agent ran on its own (backgroundTurns.ts): "Background task
// finished", "Scheduled check" or "Background update". While the turn runs it leads with the working
// spinner; once it ended quiet it leads with the clock. A click opens the turn's rows under it, which
// the transcript draws as its own rows (turns.ts), so the open state is the transcript's fold set,
// kept per chat like a "Worked for" fold, and survives virtualization. One with no row of its own
// yet has nothing to open, so it has no chevron and is no button. A run of
// background-task notifications folded under one line (backgroundRuns.ts) draws here too, the same
// line in the same look: "4 background tasks finished". A turn a subagent's report started draws as
// that report, "Report from …", under the subagent's "Subagent finished" line
// (subagents/SubagentReportLine.tsx).
import { useT } from "../i18n";
import type { AcpmuxRow } from "../model";
import { backgroundRunLabel } from "./backgroundRuns";
import { backgroundTurnLabel, foldsBackground } from "./backgroundTurns";
import { Clock, Spinner } from "./icons";
import { TranscriptActivityRow } from "./TranscriptActivityRow";
import { isSubagentReport, SubagentReportLine, useReportRowLook } from "../subagents/SubagentReportLine";

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
  const reportLook = useReportRowLook();
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
  // A subagent's report opens to the report itself, so it opens whether or not the turn drew a row.
  if (isSubagentReport(row) && reportLook !== "before")
    return <SubagentReportLine row={row} look={reportLook} expanded={expanded} onToggle={onToggle} />;
  const label = backgroundTurnLabel(t, turn);
  // Until a row of its own draws, there is nothing to open: a plain line, no chevron, no button.
  // A failure that said something heads its rows, which already show (headsBackground).
  const opens = turn.hasRows === true && foldsBackground(row);
  return (
    <TranscriptActivityRow
      icon={turn.running ? <Spinner /> : <Clock />}
      before={label}
      className="cv-background-turn"
      ariaLabel={label}
      expanded={opens && expanded}
      chevron={opens}
      attributes={{
        ...(opens && { "aria-expanded": String(expanded) }),
        "data-find-skip": "",
        "data-background-turn": turn.running ? "running" : opens || turn.quiet ? "quiet" : "failed",
      }}
      onClick={opens ? onToggle : undefined}
    />
  );
}
