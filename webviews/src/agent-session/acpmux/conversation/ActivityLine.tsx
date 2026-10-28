// The running turn's activity line under its todo list (Debug Settings `agent.sessionStatus`,
// cx-ncc.102; Claude Code desktop's `Edit ProductGrid.module.css 26s`): what turns.ts names (the
// running tool call, else the todo in progress) and the turn's time from the prompt like "Working
// for", whose place it takes: each second under a minute, each minute after (ui/useElapsedNow.ts).
// No dots blink before it, as on that line. The page's clock rests while the page is hidden and
// ticks once when it shows (pageClock.ts).
import type { PageClock } from "../../../ui/pageClock";
import { useElapsedNow } from "../../../ui/useElapsedNow";
import { useSubsessionInfo } from "../subagents/subsessions";
import { useT } from "../i18n";
import type { AcpmuxRow } from "../model";
import { BackgroundHint } from "./BackgroundHint";
import { workingLabel, workingTime } from "./WorkingFor";

/// `clock` is the page's clock (pageClock.ts); a test passes one it moves.
export function ActivityLine({ row, clock }: { row: AcpmuxRow; clock?: PageClock }) {
  const t = useT();
  const time = useElapsedNow(row.at, { clock });
  // A message going out reads "Sending message to tests", never its raw command (turns.ts `sendingTo`).
  const sendName = useSubsessionInfo(row.doingSendSession)?.name ?? row.doingSendTo;
  return (
    <div className="cv-activity">
      {row.text ? (
        <>
          <span className="cv-activity__label">
            {sendName !== undefined ? t("send.sending", { target: sendName }) : row.text}
          </span>
          <span className="cv-activity__time">{workingTime(row.at, time)}</span>
        </>
      ) : (
        <span className="cv-activity__label">{workingLabel(t, row.at, time)}</span>
      )}
      {/* A running command's ⌃B hint (BackgroundHint.tsx), keyed by the command. */}
      {row.doingCommand && <BackgroundHint key={row.text} />}
    </div>
  );
}
