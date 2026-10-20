// The running turn's activity line under its todo list (Debug Settings `agent.sessionStatus`,
// cx-ncc.102; Claude Code desktop's `••• Edit ProductGrid.module.css 26s`): what turns.ts names
// (the running tool call, else the todo in progress) and the turn's time, ticking each second from
// the prompt like "Working for", whose place it takes.
import { useEffect, useState } from "react";
import { useT } from "../i18n";
import type { AcpmuxRow } from "../model";
import { formatDuration } from "./turns";
import { workingLabel } from "./WorkingFor";

export function ActivityLine({ row, now = Date.now }: { row: AcpmuxRow; now?: () => number }) {
  const t = useT();
  const [time, setTime] = useState(now);
  useEffect(() => {
    setTime(now());
    const timer = setInterval(() => setTime(now()), 1000);
    return () => clearInterval(timer);
  }, [now]);
  return (
    <div className="cv-activity">
      <span className="cv-activity__dots" aria-hidden="true">
        <span />
        <span />
        <span />
      </span>
      {row.text ? (
        <>
          <span className="cv-activity__label">{row.text}</span>
          <span className="cv-activity__time">{formatDuration(Math.max(0, time - row.at))}</span>
        </>
      ) : (
        <span className="cv-activity__label">{workingLabel(t, row.at, time)}</span>
      )}
    </div>
  );
}
