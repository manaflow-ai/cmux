// "Thinking": a running turn before its first output. No mark blinks before it (Leo, 2026-10-20:
// "wtf have we removed this yet"); the word itself carries the motion, as the Codex and ChatGPT apps
// draw it: a light band in the theme accent sweeps across it (`is-shimmer`, conversation.css), and
// holds still under Reduce Motion and the static status look. Before the turn, while the prompt
// waits for its agent to start, the same line reads the start status ("Starting Claude Code…") with
// Cancel and no sweep, so the line keeps one place from send to the first output (cx-ncc.58). Only
// the status is the live region.
import { useT } from "../i18n";

export function Thinking({ status, onCancel }: { status?: string; onCancel?: () => void } = {}) {
  const t = useT();
  return (
    <div className="cv-worked" data-find-skip>
      <output className={status ? "cv-thinking" : "cv-thinking is-shimmer"}>{status ?? t("thinking")}</output>
      {status && onCancel && (
        <button type="button" className="cv-thinking__cancel" onClick={onCancel}>
          {t("switch.cancelPrompt")}
        </button>
      )}
    </div>
  );
}
