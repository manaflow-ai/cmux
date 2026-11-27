import { useId } from "react";
import { useT } from "../i18n";
import { cloudSetupAction, cloudSetupName, type CloudSetupAction, type CloudSetupNeed } from "../cloudSetup";
import type { ConnectProgress } from "../claudeConnect";
import { ConnectCard, type ConnectCardLook } from "../ConnectCard";
import { CloudSetupSteps, type CloudSetupStepsLook } from "./CloudSetupSteps";
import { Spinner } from "./icons";

export function CloudSetupCard({
  need,
  waiting = false,
  steps,
  look = "card",
  progress,
  onSetUp,
  onCancel,
  onApiKey,
  onRunHere,
  runHereLabel,
  onDismiss,
}: {
  need: CloudSetupNeed;
  waiting?: boolean;
  steps?: CloudSetupStepsLook;
  look?: ConnectCardLook;
  progress?: ConnectProgress;
  onSetUp?: (action: CloudSetupAction) => void;
  onCancel?: () => void;
  onApiKey?: (key: string) => Promise<void>;
  onRunHere?: () => void;
  runHereLabel?: string;
  onDismiss?: () => void;
}) {
  const t = useT();
  const action = cloudSetupAction(need);
  const name = cloudSetupName(need.family);
  const titleId = useId();
  const family =
    action === "setUpClaude" || action === "connectChatGPT"
      ? action === "setUpClaude"
        ? "claude"
        : "codex"
      : undefined;
  // The last set up's sign-in failed (cmux#63349): the card says why and offers Try again.
  const shown = progress ?? { phase: waiting ? "signing_in" : null, error: waiting ? null : (need.error ?? null) };
  const pending = waiting || shown.phase !== null;
  return (
    <section className="acpmux-cloud-setup" aria-labelledby={titleId} data-waiting={pending || undefined}>
      {steps && <CloudSetupSteps current="model" look={steps} />}
      <strong className="acpmux-cloud-setup__title" id={titleId}>
        {t("cloudSetup.familyTitle", { name })}
      </strong>
      {!pending && (
        <p className="acpmux-cloud-setup__body">
          {need.timedOut ? (
            t("cloudSetup.timedOut")
          ) : (
            <>
              {t("cloudSetup.body", { name })}
              {need.model && <> {t("cloudSetup.model", { model: need.model })}</>}
            </>
          )}
        </p>
      )}
      {family || onApiKey ? (
        <ConnectCard
          family={family}
          look={look}
          progress={shown}
          {...(family && onSetUp ? { onBegin: () => onSetUp(action) } : {})}
          {...(onCancel ? { onCancel } : {})}
          {...(onApiKey ? { onApiKey } : {})}
        />
      ) : pending ? (
        <output className="acpmux-cloud-start__status" aria-busy="true">
          <Spinner size={14} loading />
          <span>{t("cloudSetup.waiting")}</span>
        </output>
      ) : null}
      <span className="acpmux-cloud-ask__actions acpmux-cloud-setup__actions">
        {!family && !onApiKey && !pending && (
          <button
            type="button"
            className="acpmux-cloud-ask__button"
            data-role="default"
            data-action={action}
            disabled={!onSetUp}
            onClick={() => onSetUp?.(action)}
          >
            {t("picker.cloud.connectFamily", { name })}
          </button>
        )}
        {!family && !onApiKey && pending && onCancel && (
          <button type="button" className="acpmux-cloud-ask__button" data-action="cancel" onClick={onCancel}>
            {t("picker.setup.cancel")}
          </button>
        )}
        {!pending && onRunHere && (
          <button type="button" className="acpmux-cloud-ask__button" data-action="run-here" onClick={onRunHere}>
            {runHereLabel}
          </button>
        )}
        {!pending && onDismiss && (
          <button type="button" className="acpmux-cloud-ask__button" data-action="dismiss" onClick={onDismiss}>
            {t("harness.notNow")}
          </button>
        )}
      </span>
    </section>
  );
}
