// "Thinking 4s": a running turn before its first output, with the time since the prompt (`since`),
// ticking each second, so a long first think never reads as a stuck label. The line holds still
// otherwise: no mark blinks before it (Leo, 2026-10-20: "wtf have we removed this yet"). Before the
// turn, while the prompt waits for its agent to start, the same line reads the start status
// ("Starting Claude Code…") with Cancel and no time, so the line keeps one place from send to the
// first output (cx-ncc.58). Only the status is the live region.
import { useT } from "../i18n";
import { formatDuration } from "./turns";
import { useTicking } from "./WorkingFor";

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
    <div className="cv-worked" data-find-skip>
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
