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

/// The turn ends that are no success: stopped or failed (conversation/TurnRows.tsx `UNFINISHED`).
const UNFINISHED = new Set(["cancelled", "interrupted", "failed", "error"]);

/// The chat's newest turn summary row (snapshot rows of kind `turnSummary`): its id and how the turn ended.
export type TurnSummary = { readonly id: string; readonly status?: string };

/// How far back from the newest row a summary is looked for: a turn's summary is among the last rows
/// when it ends, so the read costs the same however long the chat is.
export const SUMMARY_LOOKBACK = 200;

/// The newest `turnSummary` row among the last SUMMARY_LOOKBACK rows of `rows`.
export function newestTurnSummary(rows: readonly { id: string; kind: string; status?: string }[]): TurnSummary | undefined {
  for (let i = rows.length - 1; i >= Math.max(0, rows.length - SUMMARY_LOOKBACK); i--) {
    const row = rows[i]!;
    if (row.kind === "turnSummary") return { id: row.id, status: row.status };
  }
  return undefined;
}

const shown = () => typeof document === "undefined" || document.visibilityState !== "hidden";

export function useFinishMoments({
  session,
  working,
  turnStartedAtMs,
  clockOffsetMs,
  stopping,
  pullRequest,
  turnSummary,
}: TurnFinishState & {
  clockOffsetMs?: number;
  stopping?: boolean;
  pullRequest?: HeaderPullRequest;
  turnSummary?: TurnSummary;
}): void {
  const lastTurn = useRef<TurnFinishState>({ session, working, turnStartedAtMs });
  const lastPullRequest = useRef(pullRequest);
  const lastPullRequestSession = useRef(session);
  // The header's pull request a chat switch carried over: the previous chat's, until this chat's
  // tab state is read (App `readTabState`), so it is no read of this chat's pull request.
  const carriedPullRequest = useRef<HeaderPullRequest | undefined>(undefined);
  // The summary row seen while the turn ran, and a long turn's sound waiting for its own summary:
  // only a turn that ended in success sounds (a failed or stopped one does not).
  const summaryWhileWorking = useRef(turnSummary?.id);
  const pendingSound = useRef<{ session?: string; seen?: string } | undefined>(undefined);
  const resolveSound = (summary: TurnSummary | undefined) => {
    const pending = pendingSound.current;
    if (!pending || pending.session !== session || !summary || summary.id === pending.seen) return;
    pendingSound.current = undefined;
    if (!UNFINISHED.has(summary.status ?? "")) playFinishSound("turn");
  };
  // The person pressed Stop on the running turn (the snapshot's `stopping`, at the last render): its
  // end is no success. A refused Stop clears it while the turn goes on, and that turn's end counts.
  const stopped = useRef(false);
  useEffect(() => {
    const last = lastTurn.current;
    const wasStopped = stopped.current;
    stopped.current = working && stopping === true;
    // A running turn keeps the start it was first seen with, should a later render leave it out;
    // only this chat's: another chat's start is not this turn's.
    const kept = last.working && last.session === session ? last.turnStartedAtMs : undefined;
    const start = working ? (turnStartedAtMs ?? kept) : undefined;
    lastTurn.current = { session, working, turnStartedAtMs: start };
    if (working) {
      summaryWhileWorking.current = turnSummary?.id;
      pendingSound.current = undefined;
    }
    if (last.session !== session) {
      pendingSound.current = undefined;
      endFinishMoment();
      return;
    }
    const started = longTurnEnded(last, { session, working }, Date.now(), clockOffsetMs);
    if (started === undefined || wasStopped || stopping === true) return;
    // An ended turn the person is not looking at already has the Agent Finished notification's sound,
    // and one under a bigger moment still showing leaves the sound to it.
    if (startFinishMoment({ kind: "turn", session, turnStartedAt: started })) {
      pendingSound.current = { session, seen: summaryWhileWorking.current };
      resolveSound(turnSummary);
    }
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- turnSummary is read by the effect below
  }, [session, working, turnStartedAtMs, clockOffsetMs, stopping]);
  // The ended turn's summary row may come a render after its end.
  // oxlint-disable-next-line react-hooks/exhaustive-deps -- resolveSound reads refs and this render's session
  useEffect(() => resolveSound(turnSummary), [turnSummary?.id, turnSummary?.status]);
  useEffect(() => {
    if (lastPullRequestSession.current !== session) {
      // A chat switch: the header still holds the previous chat's pull request.
      lastPullRequestSession.current = session;
      carriedPullRequest.current = pullRequest;
      lastPullRequest.current = undefined;
      return;
    }
    if (carriedPullRequest.current !== undefined) {
      if (pullRequest === carriedPullRequest.current) return;
      // This chat's first read of its pull request: a baseline, no transition.
      carriedPullRequest.current = undefined;
      lastPullRequest.current = pullRequest;
      return;
    }
    const last = lastPullRequest.current;
    lastPullRequest.current = pullRequest;
    const kind = pullRequestFinish(last, pullRequest);
    if (!kind || !pullRequest) return;
    // A hidden page shows no moment but still sounds: nothing else says a merge happened.
    if (startFinishMoment({ kind, session, url: pullRequest.url }) || !shown()) playFinishSound(kind);
  }, [pullRequest, session]);
  // The chat page going away ends a moment it still shows.
  useEffect(() => endFinishMoment, []);
}
