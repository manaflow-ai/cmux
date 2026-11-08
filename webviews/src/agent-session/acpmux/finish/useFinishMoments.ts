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
  stopping,
  pullRequest,
}: TurnFinishState & { clockOffsetMs?: number; stopping?: boolean; pullRequest?: HeaderPullRequest }): void {
  const lastTurn = useRef<TurnFinishState>({ session, working, turnStartedAtMs });
  const lastPullRequest = useRef(pullRequest);
  const lastPullRequestSession = useRef(session);
  // The person pressed Stop on the running turn (the snapshot's `stopping`, at the last render): its
  // end is no success. A refused Stop clears it while the turn goes on, and that turn's end counts.
  const stopped = useRef(false);
  useEffect(() => {
    const last = lastTurn.current;
    const wasStopped = stopped.current;
    stopped.current = working && stopping === true;
    // A running turn keeps the start it was first seen with, should a later render leave it out.
    const start = working ? (turnStartedAtMs ?? (last.working ? last.turnStartedAtMs : undefined)) : undefined;
    lastTurn.current = { session, working, turnStartedAtMs: start };
    if (last.session !== session) {
      endFinishMoment();
      return;
    }
    const started = longTurnEnded(last, { session, working }, Date.now(), clockOffsetMs);
    if (started === undefined || wasStopped || stopping === true) return;
    // An ended turn the person is not looking at already has the Agent Finished notification's sound,
    // and one under a bigger moment still showing leaves the sound to it.
    if (startFinishMoment({ kind: "turn", session, turnStartedAt: started })) playFinishSound("turn");
  }, [session, working, turnStartedAtMs, clockOffsetMs, stopping]);
  useEffect(() => {
    // Another chat's read of the same pull request is that chat's first read, no transition.
    const last = lastPullRequestSession.current === session ? lastPullRequest.current : undefined;
    lastPullRequest.current = pullRequest;
    lastPullRequestSession.current = session;
    const kind = pullRequestFinish(last, pullRequest);
    if (!kind || !pullRequest) return;
    // A hidden page shows no moment but still sounds: nothing else says a merge happened.
    if (startFinishMoment({ kind, session, url: pullRequest.url }) || !shown()) playFinishSound(kind);
  }, [pullRequest, session]);
  // The chat page going away ends a moment it still shows.
  useEffect(() => endFinishMoment, []);
}
