// Waiting on me on a new chat's home (WaitingTimeline.tsx): the day's lanes come from this pane's
// acpmux, and a red stretch opens its chat at the turn the wait began in, once that turn's row is
// drawn. Mounted only while the home shows; draws nothing until Labs is on (waitingPreview.ts).
import type React from "react";

import type { AcpmuxDirectClient } from "../direct";
import { revealTurnWhenShown } from "../links";
import type { AcpmuxSessionEntry } from "../sessionList";
import { HomeWaitingTimeline } from "./WaitingTimeline";
import { useWaitingPreview } from "./waitingPreview";

export function HomeWaitingSection({
  directClient,
  sessions,
  linked,
  selectSession,
}: {
  directClient: React.RefObject<AcpmuxDirectClient | undefined>;
  sessions: readonly AcpmuxSessionEntry[];
  linked: boolean;
  selectSession: (sessionId: string) => void;
}) {
  const on = useWaitingPreview();
  // The React Compiler keeps these two stable across renders (useWaitingDay reads `read` again only
  // when it changes).
  const read = (params: { since: number; until: number }) =>
    directClient.current?.waitingDay(params) ?? Promise.resolve(undefined);
  const onJump = (sessionId: string, turnId?: string) => {
    selectSession(sessionId);
    if (turnId) void revealTurnWhenShown(turnId);
  };
  if (!on) return null;
  return <HomeWaitingTimeline read={read} sessions={sessions} linked={linked} onJump={onJump} />;
}
