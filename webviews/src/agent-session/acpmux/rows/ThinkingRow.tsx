import { memo, useContext, useEffect } from "react";
import { experimentArm } from "../../../experiments/experiment";
import { cloudStartQuietLook } from "../cloudStart.experiment";
import { CloudAgentStartContext, CloudAgentStartLine } from "../conversation/CloudAgentStartLine";
import { Thinking } from "../conversation/Thinking";
import { WaitingOnContext } from "../conversation/waitingOn";
import { LiveLinePulseContext } from "../conversation/liveLinePulse";
import { LIVE_THINKING } from "../conversation/turns";
import { glyphTrigger, setLiveGlyphTrigger } from "../conversation/thinkingGlyphModel";
import { type RowProps } from "./rowProps";
import { sameLiveWait, sameNames } from "../conversation/liveWait";

/// A running turn's status: "Thinking", then "Working for 42s" (turnView in conversation/turns.ts).
export const ThinkingRow = memo(
  function ThinkingRow({ row }: RowProps) {
    // The transcript's live line hears its chunks without a draw (liveLinePulse.ts).
    const pulse = useContext(LiveLinePulseContext);
    // A Cloud chat's first prompt waits for its agent to start on the machine: the line names it
    // (CloudAgentStartLine), as the Mac's start view did, unless the quiet look's `thinking` arm is on.
    const cloudAgent = useContext(CloudAgentStartContext);
    const waiting = useContext(WaitingOnContext);
    // A look's thinking glyph plays the document's trigger for what the agent does now; the transcript's
    // live line tells Jump to latest too (thinkingGlyphModel.ts).
    const trigger = glyphTrigger({
      starting: row.queued !== undefined,
      kind: row.doingKind,
      sendTo: row.doingSendTo,
      liveState: row.liveState,
    });
    const live = row.id === LIVE_THINKING;
    useEffect(() => {
      if (live) setLiveGlyphTrigger(trigger);
    }, [live, trigger]);
    if (row.queued !== undefined && cloudAgent && !waiting && experimentArm(cloudStartQuietLook) !== "thinking")
      return <CloudAgentStartLine agent={cloudAgent} since={row.at} below={row.below} />;
    return (
      <Thinking
        starting={row.queued !== undefined}
        since={row.at}
        doing={row.doing}
        activityDots={row.id === LIVE_THINKING}
        doingAt={row.doingAt}
        doingShell={row.doingShell}
        sendTo={row.doingSendTo}
        sendSession={row.doingSendSession}
        draft={row.doingDraft}
        done={row.doingDone}
        call={row.doingCall}
        doneMs={row.doingForMs}
        liveState={row.liveState}
        liveAgents={row.liveAgents}
        liveAgentNames={row.liveAgentNames}
        liveCompaction={row.liveCompaction}
        phaseAt={row.phaseAt}
        heardAt={row.heardAt}
        heardKey={row.heardKey}
        liveWait={row.liveWait}
        waitAt={row.waitAt}
        turnTotal={row.turnTotal}
        untimed={row.untimed}
        verbKey={row.verbKey}
        quietKey={row.quietKey}
        quietAt={row.quietAt}
        below={row.below}
        command={row.doingCommand}
        retry={row.retry}
        retryAt={row.retryAt}
        pulse={row.id === LIVE_THINKING ? (pulse ?? undefined) : undefined}
        glyphTrigger={trigger}
      />
    );
  },
  (a, b) =>
    a.row.id === b.row.id &&
    a.row.version === b.row.version &&
    a.row.queued === b.row.queued &&
    a.row.at === b.row.at &&
    a.row.doing === b.row.doing &&
    a.row.doingAt === b.row.doingAt &&
    a.row.doingShell === b.row.doingShell &&
    a.row.doingKind === b.row.doingKind &&
    a.row.doingSendTo === b.row.doingSendTo &&
    a.row.doingSendSession === b.row.doingSendSession &&
    a.row.doingDraft === b.row.doingDraft &&
    a.row.doingDone === b.row.doingDone &&
    a.row.doingCall === b.row.doingCall &&
    a.row.doingForMs === b.row.doingForMs &&
    a.row.liveState === b.row.liveState &&
    a.row.liveAgents === b.row.liveAgents &&
    sameNames(a.row.liveAgentNames, b.row.liveAgentNames) &&
    a.row.liveCompaction === b.row.liveCompaction &&
    a.row.phaseAt === b.row.phaseAt &&
    a.row.heardAt === b.row.heardAt &&
    a.row.heardKey === b.row.heardKey &&
    sameLiveWait(a.row.liveWait, b.row.liveWait) &&
    a.row.waitAt === b.row.waitAt &&
    a.row.turnTotal === b.row.turnTotal &&
    a.row.untimed === b.row.untimed &&
    a.row.verbKey === b.row.verbKey &&
    a.row.quietKey === b.row.quietKey &&
    a.row.quietAt === b.row.quietAt &&
    a.row.below === b.row.below &&
    a.row.doingCommand === b.row.doingCommand &&
    a.row.retry === b.row.retry &&
    a.row.retryAt === b.row.retryAt,
);
