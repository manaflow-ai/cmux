import { type ReactNode, useState } from "react";
import { intl } from "../../ui/intl";
import { type StringKey, type Translate, useT } from "./i18n";
import { Notice } from "./NoticeSlot";
import type { RecoveryStatus, RestartOutcomeRow } from "./recoveryStatus";

/// Arms (`cancel` false) or cancels the chat's one-shot resume at the usage-limit reset:
/// `_acpmux/retry {sessionId, atReset: true, cancel?}`. Rejects when acpmux refused.
export type ResumeAtResetAction = (cancel: boolean) => Promise<unknown>;

const WHY: Record<string, StringKey> = {
  auto_resume_off: "restartOutcome.why.auto_resume_off",
  attempts_exhausted: "restartOutcome.why.attempts_exhausted",
  stopped: "restartOutcome.why.stopped",
  remote_floor_cancel: "restartOutcome.why.remote",
  remote_control_ended: "restartOutcome.why.remote",
  trigger: "restartOutcome.why.trigger",
  hidden_context: "restartOutcome.why.hidden_context",
  prompt_not_received: "restartOutcome.why.prompt_not_received",
  no_prompt: "restartOutcome.why.no_prompt",
};

function resetTime(at: number, locale?: string): string {
  const options: Intl.DateTimeFormatOptions = { hour: "numeric", minute: "2-digit" };
  try {
    return intl.DateTimeFormat(locale, options).format(at);
  } catch {
    return intl.DateTimeFormat(undefined, options).format(at);
  }
}

function outcomeLine(t: Translate, outcome: NonNullable<RecoveryStatus["restartOutcome"]>): string {
  if (outcome.state === "resumed")
    return t(outcome.delivery === "delivered" ? "restartOutcome.delivered" : "restartOutcome.resumed");
  if (outcome.state === "unable_to_resume" && outcome.nextAction === "retry") return t("restartOutcome.unable");
  return t(outcome.nextAction === "review_then_send" ? "restartOutcome.review" : "restartOutcome.sendAgain");
}

/// Why, and what the cut turn started that nobody saw finish: only what the log shows, so a tool
/// is never said to be running, only that its outcome is unknown.
function OutcomeDetails({ t, outcome }: { t: Translate; outcome: RestartOutcomeRow }) {
  const why = outcome.why ? WHY[outcome.why] : undefined;
  const tools = outcome.unfinishedTools ?? [];
  if (!why && tools.length === 0) return null;
  const list = tools.join(", ") + (outcome.toolsOmitted ? ", …" : "");
  return (
    <details className="acpmux-recovery-details" data-recovery-details="">
      <summary>{t("turn.failure.details")}</summary>
      {why && <p>{t(why)}</p>}
      {tools.length > 0 && <p data-recovery-tools="">{t("restartOutcome.unfinishedTools", { tools: list })}</p>}
    </details>
  );
}

/// One quiet line in the composer notice slot for what acpmux did, or can do, about the chat's
/// last turn: the opt-in one-shot resume at the usage-limit reset (arm it, or cancel it once
/// armed; no countdown when the provider reported no reset), and what recovery did with a turn a
/// daemon restart cut, with its detail behind Details. It renders acpmux's rows only and sends
/// nothing by itself.
export function RecoveryNotice({
  state,
  onResumeAtReset,
  locale,
}: {
  state: RecoveryStatus | undefined;
  /// Absent where the daemon does not serve `resume-at-reset-v1`, or the pane may not send.
  onResumeAtReset?: ResumeAtResetAction;
  locale?: string;
}) {
  const t = useT();
  const [pending, setPending] = useState(false);
  const [failed, setFailed] = useState<string>();
  const reset = state?.resumeAtReset;
  const outcome = state?.restartOutcome;
  const resetKey = reset ? `${reset.turnId}:${reset.state}` : undefined;
  const run = (cancel: boolean) => {
    if (!onResumeAtReset || pending) return;
    setPending(true);
    setFailed(undefined);
    onResumeAtReset(cancel).then(
      () => setPending(false),
      () => {
        setPending(false);
        setFailed(resetKey);
      },
    );
  };
  let line: ReactNode = null;
  if (reset) {
    const time = reset.resetsAt !== undefined ? resetTime(reset.resetsAt, locale) : undefined;
    const text =
      reset.state === "armed" && time
        ? t("resumeAtReset.armed", { time })
        : reset.state === "offered" && time
          ? t("resumeAtReset.offered", { time })
          : t("resumeAtReset.unknown");
    const action =
      reset.state === "unknown_reset" || !onResumeAtReset ? null : (
        <button
          type="button"
          className="acpmux-recovery-action"
          data-recovery-action={reset.state === "armed" ? "cancel" : "arm"}
          disabled={pending}
          onClick={() => run(reset.state === "armed")}
        >
          {reset.state === "armed" ? t("checkpoint.cancel") : t("resumeAtReset.arm")}
        </button>
      );
    line = (
      <output className="acpmux-switch-notice acpmux-recovery-notice" data-resume-at-reset={reset.state}>
        {text} {action}
        {failed === resetKey && failed !== undefined && <span data-recovery-failed=""> {t("retry.failed")}</span>}
      </output>
    );
  } else if (outcome) {
    line = (
      <output
        className="acpmux-switch-notice acpmux-recovery-notice"
        data-restart-outcome={outcome.state}
        data-restart-delivery={outcome.delivery}
      >
        {outcomeLine(t, outcome)}
        <OutcomeDetails t={t} outcome={outcome} />
      </output>
    );
  }
  return (
    <Notice id="recovery" tier="status" when={line}>
      {line}
    </Notice>
  );
}
