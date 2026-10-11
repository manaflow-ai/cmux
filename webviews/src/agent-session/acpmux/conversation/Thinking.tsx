// "Thinking": a running turn before its first output. The label shimmers unless Reduce Motion
// is on (conversation.css). Before the turn, while the prompt waits for its agent to start, the
// same line reads the start status ("Starting Claude Code…") with Cancel, so the line keeps one
// place from send to the first output (cx-ncc.58).
import { useT } from "../i18n";

export function Thinking({ status, onCancel }: { status?: string; onCancel?: () => void } = {}) {
  const t = useT();
  return (
    <output className="cv-worked">
      <span className="cv-thinking">{status ?? t("thinking")}</span>
      {status && onCancel && (
        <button type="button" className="cv-thinking__cancel" onClick={onCancel}>
          {t("switch.cancelPrompt")}
        </button>
      )}
    </output>
  );
}
