// "Thinking 4s": a running turn before its first output, after the working mark (WorkingMark.tsx),
// with the time since the prompt (`since`), ticking each second, so a long first think never reads
// as a stuck label. The label stays still; the mark is the only motion. Before the turn, while
// the prompt waits for its agent to start, the same line reads the start status ("Starting
// Claude Code…") with Cancel and no time, so the line keeps one place from send to the first
// output (cx-ncc.58). Only the status is the live region.
import { useT } from "../i18n";
import { formatDuration } from "./turns";
import { useTicking } from "./WorkingFor";
import { WorkingMark } from "./WorkingMark";

export function Thinking({
  status,
  onCancel,
  since,
  now = Date.now,
}: { status?: string; onCancel?: () => void; since?: number; now?: () => number } = {}) {
  const t = useT();
  const timed = !status && since !== undefined;
  const time = useTicking(timed, now);
  return (
    <div className="cv-worked">
      <WorkingMark />
      <output className="cv-thinking">{status ?? t("thinking")}</output>
      {timed && <span className="cv-worked__time">{formatDuration(Math.max(0, time - since))}</span>}
      {status && onCancel && (
        <button type="button" className="cv-thinking__cancel" onClick={onCancel}>
          {t("switch.cancelPrompt")}
        </button>
      )}
    </div>
  );
}
