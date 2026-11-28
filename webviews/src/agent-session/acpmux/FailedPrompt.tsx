import { useT } from "./i18n";
import type { AcpmuxRow } from "./model";

/// Under a prompt that was not sent (the host refused it, or the send failed): why, and Retry,
/// which sends the same prompt again (`chat.retryPrompt`). A sent prompt shows nothing here, so a
/// bubble never waits for a reply that cannot come.
export function FailedPrompt({ row }: { row: AcpmuxRow }) {
  const t = useT();
  if (!row.failed) return null;
  return (
    <div className="cv-user__status cv-user__status--failed" aria-live="polite">
      <span>{row.error ?? t("prompt.notSentGesture")}</span>
      <button
        type="button"
        className="cv-user__cancel"
        onClick={() => void window.cmuxAcpmuxActions?.["chat.retryPrompt"]?.({ rowId: row.id })}
      >
        {t("turn.retry")}
      </button>
    </div>
  );
}
