// The chat's turn as one phase, read from the snapshot alone, for every notice above the composer
// that speaks about the live turn (the stuck banner, the automatic retry's line). Each used to read
// its own field of the chat's summary, and those fields are the daemon's word as of the last
// summary the pane heard: with the pane's link down, that summary is frozen, so "the agent seems
// stuck" showed beside "Reconnecting…", and "Automatically resumed (attempt 2)" stayed under a turn
// that ended long ago. A notice about the running turn shows only in the phase it is about.
import { linkUp, type AcpmuxSnapshot } from "./model";

/// `offline`: the pane's link is down, so nothing it holds about the turn is current. `stopping`: a
/// Stop the turn has not ended on yet. `working`: a turn runs. `idle`: none runs.
export type TurnPhase = "offline" | "idle" | "working" | "stopping";

export function turnPhase(snapshot: Pick<AcpmuxSnapshot, "connection" | "isWorking" | "stopping">): TurnPhase {
  if (!linkUp(snapshot.connection)) return "offline";
  if (!snapshot.isWorking) return "idle";
  return snapshot.stopping ? "stopping" : "working";
}

/// What the stuck banner may say: the daemon's loop or silence diagnosis, only while the turn it is
/// about runs and the pane hears the daemon. `silent` is the pane's own words for a silent turn.
export function stuckNotice(
  phase: TurnPhase,
  summary: { loopEpisode?: { diagnosis?: string }; stalledSince?: number } | undefined,
  silent: string,
): string | undefined {
  if (phase !== "working") return undefined;
  return summary?.loopEpisode?.diagnosis || (summary?.stalledSince != null ? silent : undefined);
}

/// What the automatic retry's line may say: the daemon's wait for its next attempt while the pane
/// hears the daemon (a frozen wait counts down to an attempt nobody makes), and the attempt it sent
/// only while that attempt's turn runs (after it, the turn's own reply says how it went).
export function liveAutoResume<T extends { retry?: unknown; attempt?: number }>(
  phase: TurnPhase,
  state: T | undefined,
): T | undefined {
  if (!state || phase === "offline") return undefined;
  if (state.retry) return state;
  return phase === "working" || phase === "stopping" ? state : undefined;
}
