import React from "react";
import { Spinner } from "./conversation/icons";
import { useT, type Translate } from "./i18n";
import { sandboxFailureKey, sandboxRetryable, type SandboxReceipt, type SandboxRun } from "./sandboxRun";
import "./sandboxRun.css";

/// A Sandboxed send in the chat (hq#3367): the message, then a spinner while the throwaway VM runs
/// it, then its receipt as the chat's result. The reply leads; how it ended, what it cost and
/// whether the VM is gone follow.
export function SandboxRunView({
  run,
  onBack,
  onPersistent,
  onCheckAgain,
  unread = false,
}: {
  run: SandboxRun;
  /// The newest read of the host didn't answer: the card offers Check again, whatever its state (the
  /// chat view hides the composer's notice while a card shows).
  unread?: boolean;
  onBack?(): void;
  /// Sandboxed was picked but can't run now: send as a Persistent chat instead.
  onPersistent?(): void;
  /// The answer was lost (the run may still be going): read the host's send again.
  onCheckAgain?(): void;
}) {
  const t = useT();
  // A failure that may hide a live Run says so, whatever the host's own words were.
  const failureKey =
    run.state === "failed"
      ? (sandboxFailureKey(run.code) ?? (sandboxRetryable(run) ? undefined : "sandbox.error.uncertain"))
      : undefined;
  return (
    <div className="acpmux-sandbox-run" data-state={run.state}>
      {onBack && (
        <button type="button" className="acpmux-folder-choice-button acpmux-sandbox-back" onClick={onBack}>
          {t("sandbox.back")}
        </button>
      )}
      <div className="cv-user">
        <div className="ui-glass cv-user__bubble selectable">{run.task}</div>
      </div>
      {run.state === "running" ? (
        <output className="acpmux-sandbox-running">
          <Spinner size={14} loading />
          <span>{t("sandbox.running")}</span>
          {unread && onCheckAgain && (
            <>
              {" "}
              <span>{t("sandbox.unchecked")}</span>{" "}
              <button type="button" className="acpmux-folder-choice-button" onClick={onCheckAgain}>
                {t("sandbox.checkAgain")}
              </button>
            </>
          )}
        </output>
      ) : run.state === "failed" ? (
        <div className="acpmux-sandbox-receipt" role="alert">
          {t(failureKey ?? "sandbox.error.failed")}
          {onCheckAgain && (unread || !sandboxRetryable(run)) && (
            <>
              {" "}
              <button type="button" className="acpmux-folder-choice-button" onClick={onCheckAgain}>
                {t("sandbox.checkAgain")}
              </button>
            </>
          )}
          {onPersistent && (
            <>
              {" "}
              <button type="button" className="acpmux-folder-choice-button" onClick={onPersistent}>
                {t("sandbox.usePersistent")}
              </button>
            </>
          )}
        </div>
      ) : (
        <SandboxReceiptCard receipt={run.receipt} />
      )}
    </div>
  );
}

function seconds(t: Translate, ms: number | null | undefined): string | undefined {
  return typeof ms === "number" ? t("sandbox.seconds", { value: (ms / 1000).toFixed(1) }) : undefined;
}

/// The receipt card: the reply first, then status and exit, time, cost, artifacts and cleanup.
export function SandboxReceiptCard({ receipt }: { receipt: SandboxReceipt }) {
  const t = useT();
  const succeeded = receipt.status === "succeeded";
  const exit = receipt.timedOut
    ? t("sandbox.timedOut")
    : typeof receipt.exitCode === "number"
      ? t("sandbox.exit", { code: String(receipt.exitCode) })
      : undefined;
  const total = seconds(t, receipt.timings?.totalMs);
  const boot = seconds(t, receipt.timings?.bootMs);
  const usd = receipt.cost?.estimateUsd;
  return (
    <section className="acpmux-sandbox-receipt" aria-label={t("sandbox.receipt")} data-succeeded={String(succeeded)}>
      {receipt.reply && <div className="acpmux-sandbox-reply selectable">{receipt.reply}</div>}
      <dl className="acpmux-sandbox-facts">
        <dt>{t("sandbox.status")}</dt>
        <dd>{[t(succeeded ? "sandbox.succeeded" : "sandbox.failed"), exit].filter(Boolean).join(" · ")}</dd>
        {total && (
          <>
            <dt>{t("sandbox.time")}</dt>
            <dd>{boot ? t("sandbox.timeWithBoot", { total, boot }) : total}</dd>
          </>
        )}
        <dt>{t("sandbox.cost")}</dt>
        <dd>{typeof usd === "number" ? t("sandbox.costValue", { usd: usd.toFixed(4) }) : t("sandbox.costUnknown")}</dd>
        {receipt.artifacts && receipt.artifacts.length > 0 && (
          <>
            <dt>{t("sandbox.artifacts")}</dt>
            <dd>{receipt.artifacts.map((artifact) => artifact.name ?? "?").join(", ")}</dd>
          </>
        )}
        <dt>{t("sandbox.vm")}</dt>
        <dd>{t(receipt.cleanup === "destroyed" ? "sandbox.vmDestroyed" : "sandbox.vmPending")}</dd>
      </dl>
    </section>
  );
}
