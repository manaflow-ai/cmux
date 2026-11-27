import { memo, useContext } from "react";
import { TestTampering } from "../conversation/TestTampering";
import { TurnActionsContext } from "../conversation/turnActions";
import { type RowProps } from "./rowProps";

/** This renderer bypasses edited-files settings: an alarm belongs to its turn, not its card. */
export const TestTamperingRow = memo(
  function TestTamperingRow({ row, sessionId }: RowProps) {
    const { restoreTestTampering } = useContext(TurnActionsContext);
    return <TestTampering rows={[row]} sessionId={sessionId} turnId={row.turnId} onRestore={restoreTestTampering} />;
  },
  (a, b) => a.row.id === b.row.id && a.row.version === b.row.version && a.sessionId === b.sessionId,
);
