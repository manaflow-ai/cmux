// The App's one reader of finish moments (finishMoments.ts): it compares each render's turn state and
// the header's pull request with the last, and starts a moment and its sound on a transition. It
// runs per render of the App, which already draws for these values; a streamed token changes none
// of them, so it does no work per token.
import { useEffect, useRef } from "react";
import { callNative } from "../callNative";
import { chatDisplayValues } from "../chatDisplay";
import type { HeaderPullRequest } from "../header/headerState";
import {
  endFinishMoment,
  longTurnEnded,
  pullRequestFinish,
  startFinishMoment,
  type FinishKind,
  type TurnFinishState,
} from "./finishMoments";

/// Agent Chat > Play Sound When Work Finishes (schemas/settings/source/agent-pane-display.json): off by default.
export const FINISH_SOUND_KEY = "agentPane.display.finishSound";

/// Asks the host for the moment's sound when the person turned it on. The host plays nothing while
/// macOS's Play user interface sound effects is off, and at most one sound per burst
/// (CmuxNextAgentPane `pane.finishSound`).
export function playFinishSound(kind: FinishKind, play = callNative): void {
  if (chatDisplayValues()[FINISH_SOUND_KEY] !== true) return;
  void play("pane.finishSound", { kind }).catch(() => undefined);
}

const shown = () => typeof document === "undefined" || document.visibilityState !== "hidden";

export function useFinishMoments({
  session,
  working,
  turnStartedAtMs,
  clockOffsetMs,
  pullRequest,
}: TurnFinishState & { clockOffsetMs?: number; pullRequest?: HeaderPullRequest }): void {
  const lastTurn = useRef<TurnFinishState>({ session, working, turnStartedAtMs });
  const lastPullRequest = useRef(pullRequest);
  useEffect(() => {
    const last = lastTurn.current;
    // A running turn keeps the start it was first seen with, should a later render leave it out.
    const start = working ? (turnStartedAtMs ?? (last.working ? last.turnStartedAtMs : undefined)) : undefined;
    lastTurn.current = { session, working, turnStartedAtMs: start };
    if (last.session !== session) {
      endFinishMoment();
      return;
    }
    const started = longTurnEnded(last, { session, working }, Date.now(), clockOffsetMs);
    if (started === undefined) return;
    startFinishMoment({ kind: "turn", session, turnStartedAt: started });
    // An ended turn the person is not looking at already has the Agent Finished notification's sound.
    if (shown()) playFinishSound("turn");
  }, [session, working, turnStartedAtMs, clockOffsetMs]);
  useEffect(() => {
    const kind = pullRequestFinish(lastPullRequest.current, pullRequest);
    lastPullRequest.current = pullRequest;
    if (!kind || !pullRequest) return;
    startFinishMoment({ kind, session, url: pullRequest.url });
    playFinishSound(kind);
  }, [pullRequest, session]);
  // The chat page going away ends a moment it still shows.
  useEffect(() => endFinishMoment, []);
}
