// The `working` row: a running turn's line naming the call in flight.
import { memo } from "react";
import { WorkingFor } from "../conversation/WorkingFor";
import { TranscriptDisclosureProvider } from "../conversation/transcriptDisclosure";
import type { RowProps } from "./rowProps";

export const WorkingRow = memo(
  function WorkingRow({ row, sessionId }: RowProps) {
    // The session's disclosures say whether the running call's group shows its row (WorkingFor.tsx).
    return (
      <TranscriptDisclosureProvider sessionId={sessionId}>
        <WorkingFor row={row} />
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
    a.row.doingSendTo === b.row.doingSendTo &&
    a.row.doingSendSession === b.row.doingSendSession &&
    a.sessionId === b.sessionId,
);
