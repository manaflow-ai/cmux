import { createContext, useCallback, useState } from "react";
import type { AcpmuxRow, ConversationLayout } from "../model";
import { latestMessage } from "../conversation/messagePlacement";

export const PullRequestHostVisibility = createContext<((visible: boolean) => void) | undefined>(undefined);

/// Layout chooses the candidate incrementally. A streaming reply's actual rendered prefix
/// confirms its host before the fallback disappears; new source text can be ahead of reveal.
export function usePullRequestPlacement(
  rows: readonly AcpmuxRow[],
  layout: ConversationLayout,
  enabled: boolean,
  sessionId: string | undefined,
) {
  const row = enabled ? latestMessage(rows, layout) : undefined;
  const rowId = row?.id;
  const [shown, setShown] = useState<{ rowId: string | undefined; sessionId: string | undefined; visible: boolean }>();
  const report = useCallback(
    (visible: boolean) => {
      setShown((previous) =>
        previous && previous.rowId === rowId && previous.sessionId === sessionId && previous.visible === visible
          ? previous
          : { rowId, sessionId, visible },
      );
    },
    [rowId, sessionId],
  );
  const waitingForReveal =
    row?.kind === "assistant" && !(shown && shown.rowId === rowId && shown.sessionId === sessionId && shown.visible);
  return { rowId, report, fallback: enabled && (!row || waitingForReveal) };
}
