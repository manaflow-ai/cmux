import { useId } from "react";
import { useT } from "../i18n";
import { type CloudSetupAction, type CloudSetupNeed, cloudSetupAction, cloudSetupName } from "../cloudSetup";
import { Spinner } from "./icons";

export function CloudSetupCard({
  need,
  waiting = false,
  onSetUp,
  onRunHere,
  runHereLabel,
  onDismiss,
}: {
  need: CloudSetupNeed;
  /// A button's way in is out: the card says it waits, and the buttons rest until it ends.
  waiting?: boolean;
  onSetUp?: (action: CloudSetupAction) => void;
  onRunHere?: () => void;
  runHereLabel: string;
  onDismiss?: () => void;
}) {
  const t = useT();
  const action = cloudSetupAction(need);
  const name = cloudSetupName(need.family);
  const titleId = useId();
  return (
    <section className="acpmux-cloud-setup" aria-labelledby={titleId} data-waiting={waiting || undefined}>
      <strong className="acpmux-cloud-setup__title" id={titleId}>
        {t("cloudSetup.title", { name })}
      </strong>
      {waiting ? (
        <output className="acpmux-cloud-start__status" aria-busy="true">
          <Spinner size={14} loading />
          <span>{t("cloudSetup.waiting")}</span>
        </output>
      ) : (
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
      <span className="acpmux-cloud-ask__actions acpmux-cloud-setup__actions">
        {!waiting && (
          <>
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
            {onRunHere && (
              <button
                type="button"
                className="acpmux-cloud-ask__button"
                data-action="run-here"
                onClick={() => onRunHere()}
              >
                {runHereLabel}
              </button>
            )}
          </>
        )}
        {onDismiss && (
          <button type="button" className="acpmux-cloud-ask__button" data-action="dismiss" onClick={() => onDismiss()}>
            {t("harness.notNow")}
          </button>
        )}
      </span>
    </section>
  );
}
