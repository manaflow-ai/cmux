// The line over a running turn's work: "Working for 42s", ticking each second from the prompt,
// or held at `durationMs` while text streams. When the turn ends, the "Worked for" disclosure
// takes its place.
import { useEffect, useState } from "react";
import type { AcpmuxRow } from "../model";
import { formatDuration } from "./turns";

export const workingLabel = (at: number, now: number) => `Working for ${formatDuration(Math.max(0, now - at))}`;

export function WorkingFor({ row, now = Date.now }: { row: AcpmuxRow; now?: () => number }) {
  const [time, setTime] = useState(now);
  const held = row.durationMs !== undefined;
  useEffect(() => {
    if (held) return;
    setTime(now());
    const timer = setInterval(() => setTime(now()), 1000);
    return () => clearInterval(timer);
  }, [now, held]);
  return (
    <div className="cv-worked has-divider">
      <span className="cv-worked__label">{workingLabel(row.at, held ? row.at + row.durationMs! : time)}</span>
    </div>
  );
}
