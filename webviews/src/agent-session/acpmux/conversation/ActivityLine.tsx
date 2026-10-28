// The running turn's activity line under its todo list (Debug Settings `agent.sessionStatus`,
// cx-ncc.102; Claude Code desktop's `Edit ProductGrid.module.css 26s`): what turns.ts names (the
// running tool call, else the todo in progress) and the turn's time, ticking each second from the
// prompt like "Working for", whose place it takes. No dots blink before it, as on that line.
import { useEffect, useState } from "react";
import { useSubsessionInfo } from "../subagents/subsessions";
import { useT } from "../i18n";
import type { AcpmuxRow } from "../model";
import { BackgroundHint } from "./BackgroundHint";
import { formatDuration } from "./turns";
import { workingLabel } from "./WorkingFor";

export function ActivityLine({ row, now = Date.now }: { row: AcpmuxRow; now?: () => number }) {
  const t = useT();
  const [time, setTime] = useState(now);
  // A message going out reads "Sending message to tests", never its raw command (turns.ts `sendingTo`).
  const sendName = useSubsessionInfo(row.doingSendSession)?.name ?? row.doingSendTo;
  useEffect(() => {
    setTime(now());
    const timer = setInterval(() => setTime(now()), 1000);
    return () => clearInterval(timer);
  }, [now]);
  return (
    <div className="cv-activity">
      {row.text ? (
        <>
          <span className="cv-activity__label">
            {sendName !== undefined ? t("send.sending", { target: sendName }) : row.text}
          </span>
          <span className="cv-activity__time">{formatDuration(Math.max(0, time - row.at))}</span>
        </>
      ) : (
        <span className="cv-activity__label">{workingLabel(t, row.at, time)}</span>
      )}
      {/* A running command's ⌃B hint (BackgroundHint.tsx), keyed by the command. */}
      {row.doingCommand && <BackgroundHint key={row.text} />}
    </div>
  );
}
