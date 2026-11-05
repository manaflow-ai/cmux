// The running turn's activity line under its todo list (Debug Settings `agent.sessionStatus`,
// cx-ncc.102; Claude Code desktop's `Edit ProductGrid.module.css 26s`): what turns.ts names (the
// running tool call, else the todo in progress) and the turn's time, ticking each second from the
// prompt like "Working for", whose place it takes, on the same page-owned second (ui/pageClock.ts):
// no timer of its own, and none while the page is hidden. No dots blink before it, as on that line.
import { useContext } from "react";
import { useSubsessionInfo } from "../subagents/subsessions";
import { useT } from "../i18n";
import type { AcpmuxRow } from "../model";
import { BackgroundHint } from "./BackgroundHint";
import { Envelope, TerminalSquare } from "./icons";
import { TranscriptActivityRow } from "./TranscriptActivityRow";
import { formatDuration } from "./turns";
import { useTicking } from "./WorkingFor";
import { StatusVerb } from "./StatusVerb";
import { WAITING_LABEL, WaitingOnContext } from "./waitingOn";

export function ActivityLine({ row, now = Date.now }: { row: AcpmuxRow; now?: () => number }) {
  const t = useT();
  const waiting = useContext(WaitingOnContext);
  const time = useTicking(waiting === undefined, now);
  // A message going out reads "Sending message to tests", never its raw command (turns.ts `sendingTo`).
  const sendName = useSubsessionInfo(row.doingSendSession)?.name ?? row.doingSendTo;
  if (waiting)
    return (
      <div className="cv-activity cv-tool">
        <span className="cv-tool__icon" aria-hidden="true" />
        <output className="cv-activity__label cv-waiting" data-waiting={waiting}>
          {t(WAITING_LABEL[waiting])}
        </output>
      </div>
    );
  if (sendName !== undefined) {
    // Keep the lane name as the same tag used by sent and received transcript rows. A sentinel
    // lets localization supply the words around the interpolated name without hard-coding them.
    const [before, after = ""] = t("send.sending", { target: "\u0000" }).split("\u0000");
    return (
      <TranscriptActivityRow
        icon={<Envelope />}
        before={before}
        name={sendName}
        after={after}
        meta={<span className="cv-command__meta">{formatDuration(Math.max(0, time - row.at))}</span>}
        className="cv-activity-row"
        // It opens nothing, so it draws no chevron (a row shows one only with something to show).
        chevron={false}
        ariaLabel={t("send.sending", { target: sendName })}
      />
    );
  }
  return (
    <div className="cv-activity cv-tool">
      <span className="cv-tool__icon" aria-hidden="true">
        {row.doingCommand ? <TerminalSquare /> : null}
      </span>
      {row.text ? (
        <>
          <span className="cv-activity__label">{row.text}</span>
          <span className="cv-activity__time">{formatDuration(Math.max(0, time - row.at))}</span>
        </>
      ) : (
        <>
          <span className="cv-activity__label">
            <StatusVerb elapsedMs={Math.max(0, time - row.at)} verbKey={row.verbKey} />
          </span>
          <span className="cv-activity__time">{formatDuration(Math.max(0, time - row.at))}</span>
        </>
      )}
      {/* A running command's ⌃B hint (BackgroundHint.tsx), keyed by the command. */}
      {row.doingCommand && <BackgroundHint key={row.text} />}
    </div>
  );
}
