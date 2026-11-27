import { memo } from "react";

/// The child view's "Subagent of" pill's place in the transcript: VirtualTranscript draws the pill
/// itself, pinned over the top, so this row only keeps its room (model.ts SUBAGENT_OF).
export const SubagentOfPillRow = memo(
  function SubagentOfPillRow() {
    return <div className="cv-subagent-of-slot" aria-hidden="true" />;
  },
  () => true,
);
/// The pill's row height (model.ts: 28px with 8px above and below).
export const SUBAGENT_OF_HEIGHT = 44;
