// The pane's status island wiring (App.tsx): the island's state from the snapshot, while the
// experiment is on. The asks are the Needs you items read from the same snapshot (needsYouItems),
// whether or not the Needs you badge is installed, so the island needs no list of its own.
import { useMemo } from "react";
import type { AcpmuxSnapshot } from "../model";
import { useAttentionTabs } from "../needsYou/attentionTabs";
import { needsYouItems } from "../needsYou/model";
import { islandState, type IslandState } from "./model";

export function useStatusIsland(
  on: boolean,
  snapshot: Pick<AcpmuxSnapshot, "sessions" | "asks" | "sessionId" | "rows"> &
    Partial<Pick<AcpmuxSnapshot, "queue" | "queueApproval">>,
): IslandState | undefined {
  const { sessions, asks, sessionId, rows, queue, queueApproval } = snapshot;
  // Off: no subscription, so host attention pushes do not rerender the pane for a hidden island.
  const tabs = useAttentionTabs(on);
  return useMemo(() => {
    if (!on) return undefined;
    const items = needsYouItems({
      sessions,
      asks: asks ?? [],
      open: { ...(sessionId ? { sessionId } : {}), rows, queue, queueApproval },
      tabs,
    });
    return islandState({ sessions, items, asks: asks ?? [] });
  }, [on, sessions, asks, sessionId, rows, queue, queueApproval, tabs]);
}
