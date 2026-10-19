// The line over a running turn's work: "Working for 42s", ticking each second from the prompt,
// or held at `durationMs` while text streams. While a call runs (`row.doing`, turns.ts) it names
// that call beside the time instead, as Claude desktop's line does, after the same small animated
// mark as "Thinking". When the turn ends, the "Worked for" disclosure takes its place.
import { useEffect, useState } from "react";
import { type Translate, useT } from "../i18n";
import type { AcpmuxRow } from "../model";
import { formatDuration } from "./turns";
import { WorkingMark } from "./WorkingMark";

export const workingLabel = (t: Translate, at: number, now: number) =>
  t("turn.working", { time: formatDuration(Math.max(0, now - at)) });

export function WorkingFor({ row, now = Date.now }: { row: AcpmuxRow; now?: () => number }) {
  const t = useT();
  const [time, setTime] = useState(now);
  const held = row.durationMs !== undefined;
  useEffect(() => {
    if (held) return;
    setTime(now());
    const timer = setInterval(() => setTime(now()), 1000);
    return () => clearInterval(timer);
  }, [now, held]);
  const until = held ? row.at + row.durationMs! : time;
  return (
    <div className="cv-worked has-divider">
      <WorkingMark />
      {row.doing ? (
        <>
          <span className="cv-worked__label cv-worked__doing">{row.doing}</span>
          <span className="cv-worked__time">{formatDuration(Math.max(0, until - row.at))}</span>
        </>
      ) : (
        <span className="cv-worked__label">{workingLabel(t, row.at, until)}</span>
      )}
    </div>
  );
}
