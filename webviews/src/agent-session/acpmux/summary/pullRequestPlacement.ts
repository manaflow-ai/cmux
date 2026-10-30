import { createContext, useCallback, useState } from "react";
import type { AcpmuxRow, ConversationLayout } from "../model";
import { latestMessageIndex } from "../conversation/messagePlacement";

export const PullRequestHostVisibility = createContext<((visible: boolean) => void) | undefined>(undefined);

/// Layout chooses the candidate incrementally. A streaming reply's actual rendered prefix
/// confirms its host before the fallback disappears; new source text can be ahead of reveal.
export function usePullRequestPlacement(
  rows: readonly AcpmuxRow[],
  layout: ConversationLayout,
  enabled: boolean,
  sessionId: string | undefined,
) {
  const index = enabled ? latestMessageIndex(layout) : -1;
  const row = index >= 0 ? rows[index] : undefined;
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
  const hosted = shown && shown.rowId === rowId && shown.sessionId === sessionId && shown.visible;
  /// Whether the links stand in after the latest row: with no host, or while the host is drawn
  /// (`drawn(index)`, the transcript's mounted rows) and shows none. A host the transcript unmounted
  /// because it scrolled out of the mounted window still holds them: its unmount reports them gone,
  /// and standing them in then put a tray over the stack that cut the transcript short mid-scroll.
  const fallback = (drawn: (index: number) => boolean) => enabled && (!row || (drawn(index) && !hosted));
  return { rowId, report, fallback };
}
