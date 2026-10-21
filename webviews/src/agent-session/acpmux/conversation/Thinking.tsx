// "Thinking": a running turn before its first output. The line holds still: no mark blinks before
// it (Leo, 2026-10-20: "wtf have we removed this yet"). Before the turn, while the prompt waits
// for its agent to start, the same line reads the start status ("Starting Claude Code…") with
// Cancel, so the line keeps one place from send to the first output (cx-ncc.58). Only the
// status is the live region. While the chat waits on the person (an ask above the composer,
// waitingOn.ts), the line says that instead: never "Thinking" while the agent is blocked on them.
import { useContext } from "react";
import { useT } from "../i18n";
import { WAITING_LABEL, WaitingOnContext } from "./waitingOn";

export function Thinking({ status, onCancel }: { status?: string; onCancel?: () => void } = {}) {
  const t = useT();
  const waiting = useContext(WaitingOnContext);
  return (
    <div className="cv-worked" data-find-skip>
      {waiting ? (
        <output className="cv-thinking cv-waiting" data-waiting={waiting}>
          {t(WAITING_LABEL[waiting])}
        </output>
      ) : (
        <output className="cv-thinking">{status ?? t("thinking")}</output>
      )}
      {status && onCancel && (
        <button type="button" className="cv-thinking__cancel" onClick={onCancel}>
          {t("switch.cancelPrompt")}
        </button>
      )}
    </div>
  );
}
