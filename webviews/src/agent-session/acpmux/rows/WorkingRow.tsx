import { memo } from "react";
import { WorkingFor } from "../conversation/WorkingFor";
import { TranscriptDisclosureProvider } from "../conversation/transcriptDisclosure";
import { workedFoldOfHeader } from "../conversation/turns";
import { type RowProps } from "./rowProps";

export const WorkingRow = memo(
  function WorkingRow({ row, sessionId, expanded, onToggleActivity }: RowProps) {
    // The session's disclosures say whether the running call's group shows its row (WorkingFor.tsx).
    return (
      <TranscriptDisclosureProvider sessionId={sessionId}>
        <WorkingFor
          row={row}
          expanded={expanded}
          // The running turn's "Working for" opens its work under its "Worked for" key (#50987).
          onToggle={row.below ? undefined : () => onToggleActivity(workedFoldOfHeader(row.id))}
        />
      </TranscriptDisclosureProvider>
    );
  },
  (a, b) =>
    a.row.id === b.row.id &&
    a.row.version === b.row.version &&
    a.row.at === b.row.at &&
    a.row.durationMs === b.row.durationMs &&
    a.row.doing === b.row.doing &&
    a.row.thinkingNow === b.row.thinkingNow &&
    a.row.below === b.row.below &&
    a.row.doingCommand === b.row.doingCommand &&
    a.row.doingDraft === b.row.doingDraft &&
    a.row.doingGroup === b.row.doingGroup &&
    a.row.doingGroupOpen === b.row.doingGroupOpen &&
    a.row.doingRun === b.row.doingRun &&
    a.row.doingSendTo === b.row.doingSendTo &&
    a.row.doingSendSession === b.row.doingSendSession &&
    a.sessionId === b.sessionId &&
    a.expanded === b.expanded &&
    a.onToggleActivity === b.onToggleActivity,
);
