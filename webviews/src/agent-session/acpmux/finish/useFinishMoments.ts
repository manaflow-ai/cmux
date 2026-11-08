// The App's one reader of finish moments (finishMoments.ts): it compares each render's turn state and
// the header's pull request with the last, and starts a moment and its sound on a transition. It
// runs per render of the App, which already draws for these values; a streamed token changes none
// of them, so it does no work per token.
import { useEffect, useRef } from "react";
import { callNative } from "../callNative";
import { chatDisplayValues } from "../chatDisplay";
import type { HeaderPullRequest } from "../header/headerState";
import type { AcpmuxRow } from "../model";
import {
  endFinishMoment,
  longTurnEnded,
  pullRequestFinish,
  startFinishMoment,
  type FinishKind,
  type TurnFinishState,
  UNFINISHED_TURN,
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

/// The ended turn's summary row (direct.ts `turnSummary`) says it failed or stopped. Read once, at a
/// turn's end, from the last row back to the turn's start; no summary row reads as a success.
export function turnFailed(rows: readonly AcpmuxRow[] | undefined, startedAt: number): boolean {
  for (let index = (rows?.length ?? 0) - 1; index >= 0; index -= 1) {
    const row = rows![index]!;
    if (row.at < startedAt - 2_000) return false;
    if (row.kind === "turnSummary") return UNFINISHED_TURN.has(String((row as { status?: unknown }).status ?? ""));
  }
  return false;
}

export function useFinishMoments({
  session,
  working,
  turnStartedAtMs,
  clockOffsetMs,
  stopping,
  rows,
  pullRequest,
  pullRequestSession,
}: TurnFinishState & {
  clockOffsetMs?: number;
  stopping?: boolean;
  /// The chat's rows, read only at a long turn's end.
  rows?: readonly AcpmuxRow[];
  pullRequest?: HeaderPullRequest;
  /// The chat whose tab state the header's pull request was read for: until the switched-to chat's
  /// read lands, the header still shows the last chat's.
  pullRequestSession?: string;
}): void {
  const lastTurn = useRef<TurnFinishState>({ session, working, turnStartedAtMs });
  const lastPullRequest = useRef(pullRequest);
  const lastPullRequestSession = useRef(session);
  // The person pressed Stop on the running turn (the snapshot's `stopping`, at the last render): its
  // end is no success. A refused Stop clears it while the turn goes on, and that turn's end counts.
  const stopped = useRef(false);
  const lastRows = useRef(rows);
  lastRows.current = rows;
  useEffect(() => {
    const last = lastTurn.current;
    const wasStopped = stopped.current;
    stopped.current = working && stopping === true;
    // A running turn keeps the start it was first seen with, should a later render leave it out; a
    // switch to another working chat starts from that chat's own.
    const start = working
      ? (turnStartedAtMs ?? (last.working && last.session === session ? last.turnStartedAtMs : undefined))
      : undefined;
    lastTurn.current = { session, working, turnStartedAtMs: start };
    if (last.session !== session) {
      endFinishMoment();
      return;
    }
    const started = longTurnEnded(last, { session, working }, Date.now(), clockOffsetMs);
    if (started === undefined || wasStopped || stopping === true) return;
    // A failed turn draws no check (TurnRows.tsx `WorkedFor`) and gets no success sound.
    if (turnFailed(lastRows.current, started)) return;
    // An ended turn the person is not looking at already has the Agent Finished notification's sound,
    // and one under a bigger moment still showing leaves the sound to it.
    if (startFinishMoment({ kind: "turn", session, turnStartedAt: started })) playFinishSound("turn");
  }, [session, working, turnStartedAtMs, clockOffsetMs, stopping]);
  useEffect(() => {
    // The last chat's pull request, still shown while this chat's tab state is read, is unknown here;
    // another chat's read of the same pull request is that chat's first read, no transition.
    const current = pullRequestSession === session ? pullRequest : undefined;
    const last = lastPullRequestSession.current === session ? lastPullRequest.current : undefined;
    lastPullRequest.current = current;
    lastPullRequestSession.current = session;
    const kind = pullRequestFinish(last, current);
    if (!kind || !current) return;
    // A hidden page shows no moment but still sounds: nothing else says a merge happened.
    if (startFinishMoment({ kind, session, url: current.url }) || !shown()) playFinishSound(kind);
  }, [pullRequest, pullRequestSession, session]);
  // The chat page going away ends a moment it still shows.
  useEffect(() => endFinishMoment, []);
}
