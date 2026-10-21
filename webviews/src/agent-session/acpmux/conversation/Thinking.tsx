// "Thinking": a running turn before its first output. The line holds still: no mark blinks before
// it (Leo, 2026-10-20: "wtf have we removed this yet"). Before the turn, while the prompt waits
// for its agent to start, the same line reads the start status ("Starting Claude Code…") with
// Cancel, so the line keeps one place from send to the first output (cx-ncc.58). Only the
// status is the live region.
import { useT } from "../i18n";

export function Thinking({ status, onCancel }: { status?: string; onCancel?: () => void } = {}) {
  const t = useT();
  return (
    <div className="cv-worked" data-find-skip>
      <output className="cv-thinking">{status ?? t("thinking")}</output>
      {status && onCancel && (
        <button type="button" className="cv-thinking__cancel" onClick={onCancel}>
          {t("switch.cancelPrompt")}
        </button>
      )}
    </div>
  );
}
