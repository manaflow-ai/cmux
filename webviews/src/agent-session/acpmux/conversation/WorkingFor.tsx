// The line over a running turn's work: "Working for 42s", ticking each second from the prompt,
// or held at `durationMs` while text streams. When the turn ends, the "Worked for" disclosure
// takes its place. The ticking text is written by the shared live clock (liveClock.ts), so a
// running turn commits nothing to React per second.
import { useT } from "../i18n";
import type { AcpmuxRow } from "../model";
import { useLiveText } from "./liveClock";
import { formatDuration } from "./turns";

export function WorkingFor({ row, now = Date.now }: { row: AcpmuxRow; now?: () => number }) {
  const t = useT();
  const held = row.durationMs !== undefined;
  const label = useLiveText(
    (time) =>
      t("turn.working", { time: formatDuration(Math.max(0, (held ? row.at + row.durationMs! : time) - row.at)) }),
    !held,
    now,
  );
  return (
    <div className="cv-worked has-divider">
      <span ref={label} className="cv-worked__label tabular-nums" />
    </div>
  );
}
