// The running turn's line while the chat waits (waitingOn.ts): what it waits on, in full text color.
// A silent model's line says why it is silent, as acpmux judged it (silentReason.ts), shows the
// harness's own line on hover, and offers Retry, which ends the silent turn and sends it again.
import { useContext, useState } from "react";
import { useT } from "../i18n";
import type { RetryNote } from "../subagents/retryState";
import { SILENT_LABEL, SilentTurnContext } from "./silentReason";
import { WAITING_LABEL, type WaitingOn } from "./waitingOn";

/// `label` is the line's own class for its words (`cv-worked__label`, or Thinking.tsx's `cv-thinking`).
export function WaitingLabel({ waiting, label = "cv-worked__label" }: { waiting: WaitingOn; label?: string }) {
  const t = useT();
  const silent = useContext(SilentTurnContext);
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<RetryNote | undefined>();
  if (waiting !== "model")
    return (
      <output className={`${label} cv-waiting`} data-waiting={waiting}>
        {t(WAITING_LABEL[waiting])}
      </output>
    );
  const reason = silent?.reason;
  const retry = silent?.retry;
  const attempts = reason?.attempt !== undefined && reason.of !== undefined ? ` (${reason.attempt}/${reason.of})` : "";
  return (
    <>
      <output
        className={`${label} cv-waiting`}
        data-waiting={waiting}
        data-silent-reason={reason?.kind ?? "no_answer"}
        title={reason?.detail}
      >
        {t(SILENT_LABEL[reason?.kind ?? "no_answer"])}
        {attempts}
      </output>
      {retry && (
        <span className="cv-worked__count">
          <span className="cv-worked__sep" aria-hidden="true">
            ·
          </span>
          <button
            type="button"
            className="cv-worked__open"
            disabled={busy}
            onClick={() => {
              setBusy(true);
              setNote(undefined);
              void retry()
                .then(setNote, () => setNote("retry.failed"))
                .finally(() => setBusy(false));
            }}
          >
            {t("turn.retry")}
          </button>
          {note && <span className="cv-worked__time"> {t(note)}</span>}
        </span>
      )}
    </>
  );
}
