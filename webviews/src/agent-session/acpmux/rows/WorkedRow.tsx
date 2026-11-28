import { memo } from "react";
import { WorkedFor } from "../conversation/TurnRows";
import { WorkingFor } from "../conversation/WorkingFor";
import { TranscriptDisclosureProvider } from "../conversation/transcriptDisclosure";
import { type RowProps } from "./rowProps";

/// A turn's header, one row from the turn's start to its end (turns.ts `turnHeaderId`): "Working for
/// 32s" while the turn runs (`turnPhase`), then "Worked for 15s", which opens the turn's commentary
/// and tool calls (turnView in conversation/turns.ts). The row keeps its id, kind and element; only
/// its phase, and so its words, change at the turn's end.
export const WorkedRow = memo(
  function WorkedRow({ row, onToggleActivity, expanded, controls, sessionId }: RowProps) {
    if (row.turnPhase === "running")
      // The session's disclosures say whether the running call's group shows its row (WorkingFor.tsx).
      return (
        <TranscriptDisclosureProvider sessionId={sessionId}>
          <WorkingFor
            row={row}
            expanded={expanded}
            // Under the `folded` live arm (the header carries `foldOpen`) it opens the running turn's work,
            // under its own id: the key its "Worked for" opens with once the turn ended (#50987).
            onToggle={row.foldOpen === undefined ? undefined : () => onToggleActivity(row.id)}
          />
        </TranscriptDisclosureProvider>
      );
    return <WorkedFor row={row} expanded={expanded} controls={controls} onToggle={() => onToggleActivity(row.id)} />;
  },
  (a, b) =>
    a.row.id === b.row.id &&
    a.row.version === b.row.version &&
    a.row.turnPhase === b.row.turnPhase &&
    a.row.foldOpen === b.row.foldOpen &&
    a.row.foldEmpty === b.row.foldEmpty &&
    // Running, its clock reads `at` and `durationMs`, which the version does not cover.
    a.row.at === b.row.at &&
    a.row.durationMs === b.row.durationMs &&
    a.expanded === b.expanded &&
    a.controls === b.controls &&
    a.sessionId === b.sessionId &&
    a.onToggleActivity === b.onToggleActivity,
);
