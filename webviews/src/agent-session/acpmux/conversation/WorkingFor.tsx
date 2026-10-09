// The line over a running turn's work: "Working for 42s", ticking each second from the prompt,
// or held at `durationMs` while text streams. When the turn ends, the "Worked for" disclosure
// takes its place.
import { useEffect, useLayoutEffect, useRef } from "react";
import { useT } from "../i18n";
import type { AcpmuxRow } from "../model";
import { formatDuration } from "./turns";

export const workingLabel = (at: number, now: number) => `Working for ${formatDuration(Math.max(0, now - at))}`;

export function WorkingFor({ row, now = Date.now }: { row: AcpmuxRow; now?: () => number }) {
  const t = useT();
  const label = useRef<HTMLSpanElement>(null);
  const clock = useRef(now);
  clock.current = now;
  const held = row.durationMs !== undefined;
  const write = () => {
    const node = label.current;
    if (!node) return;
    const elapsed = formatDuration(Math.max(0, (held ? row.at + row.durationMs! : clock.current()) - row.at));
    node.textContent = t("turn.working", { time: elapsed });
  };
  // The timer is intentionally outside React state: a running transcript can have many active
  // rows, and updating a text node keeps a one-second clock from reconciling the whole pane.
  useLayoutEffect(write, [row.at, row.durationMs, held, t]);
  useEffect(() => {
    write();
    if (held) return;
    const timer = setInterval(write, 1000);
    return () => clearInterval(timer);
  }, [held, row.at, row.durationMs, t]);
  return (
    <div className="cv-worked has-divider">
      <span ref={label} className="cv-worked__label" />
    </div>
  );
}
