import { memo } from "react";
import { Thinking } from "../conversation/Thinking";
import { type RowProps } from "./rowProps";

/// A running turn's status: "Thinking", then "Working for 42s" (turnView in conversation/turns.ts).
export const ThinkingRow = memo(
  function ThinkingRow({ row }: RowProps) {
    return (
      <Thinking
        starting={row.queued !== undefined}
        since={row.at}
        doing={row.doing}
        doingAt={row.doingAt}
        doingShell={row.doingShell}
        sendTo={row.doingSendTo}
        sendSession={row.doingSendSession}
        draft={row.doingDraft}
        done={row.doingDone}
        doneMs={row.doingForMs}
        liveState={row.liveState}
        liveAgents={row.liveAgents}
        thoughtMs={row.thoughtMs}
        turnTotal={row.turnTotal}
        untimed={row.untimed}
        verbKey={row.verbKey}
        quietKey={row.quietKey}
        quietAt={row.quietAt}
        below={row.below}
        command={row.doingCommand}
        retry={row.retry}
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
    a.row.doingSendTo === b.row.doingSendTo &&
    a.row.doingSendSession === b.row.doingSendSession &&
    a.row.doingDraft === b.row.doingDraft &&
    a.row.doingDone === b.row.doingDone &&
    a.row.doingForMs === b.row.doingForMs &&
    a.row.liveState === b.row.liveState &&
    a.row.liveAgents === b.row.liveAgents &&
    a.row.thoughtMs === b.row.thoughtMs &&
    a.row.turnTotal === b.row.turnTotal &&
    a.row.untimed === b.row.untimed &&
    a.row.verbKey === b.row.verbKey &&
    a.row.quietKey === b.row.quietKey &&
    a.row.quietAt === b.row.quietAt &&
    a.row.below === b.row.below &&
    a.row.doingCommand === b.row.doingCommand &&
    a.row.retry === b.row.retry,
);
