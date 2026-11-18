// Cloud first use (cmux-tui/docs/model-connections.md, "Cloud first use"; Capy's Models onboarding):
// a Cloud chat whose picked model no connection serves shows this card in the chat, under the
// message, instead of a failure. Each button is one of Settings > Models' ways in, run on this Mac
// (`cloud.setUp`, cloudSetup.ts): Continue with ChatGPT and Sign in to Claude add the subscription as a
// connection here, Add an API key and Open Settings open Settings > Models. Once a connection serving
// the model appears, the chat starts by itself with the same prompt. Nothing is recorded before then.
import { useId } from "react";
import { useT } from "../i18n";
import { cloudSetupActions, type CloudSetupAction, type CloudSetupNeed } from "../cloudSetup";
import { Spinner } from "./icons";

const LABELS = {
  connectChatGPT: "cloudSetup.chatgpt",
  setUpClaude: "cloudSetup.claude",
  addKey: "cloudSetup.apiKey",
  openSettings: "cloudSetup.settings",
} as const satisfies Record<CloudSetupAction, string>;

export function CloudSetupCard({
  need,
  waiting = false,
  onSetUp,
  onDismiss,
}: {
  need: CloudSetupNeed;
  /// A button's way in is out: the card says it waits, and the buttons rest until it ends.
  waiting?: boolean;
  onSetUp?: (action: CloudSetupAction) => void;
  /// Not now: leaves the card; the prompt stays in the composer.
  onDismiss?: () => void;
}) {
  const t = useT();
  const actions = cloudSetupActions(need);
  const titleId = useId();
  return (
    <section className="acpmux-cloud-setup" aria-labelledby={titleId} data-waiting={waiting || undefined}>
      <strong className="acpmux-cloud-setup__title" id={titleId}>
        {t("cloudSetup.title")}
      </strong>
      <p className="acpmux-cloud-setup__body">
        {t("cloudSetup.body")}
        {need.model && <> {t("cloudSetup.model", { model: need.model })}</>}
      </p>
      {waiting ? (
        <output className="acpmux-cloud-start__status" aria-busy="true">
          <Spinner size={14} loading />
          <span>{t("cloudSetup.waiting")}</span>
        </output>
      ) : null}
      <span className="acpmux-cloud-ask__actions acpmux-cloud-setup__actions">
        {actions.map((action, index) => (
          <button
            key={action}
            type="button"
            className="acpmux-cloud-ask__button"
            data-role={index === 0 ? "default" : undefined}
            data-action={action}
            disabled={waiting || !onSetUp}
            onClick={() => onSetUp?.(action)}
          >
            {t(LABELS[action])}
          </button>
        ))}
        {onDismiss && (
          <button type="button" className="acpmux-cloud-ask__button" data-action="dismiss" onClick={() => onDismiss()}>
            {t("harness.notNow")}
          </button>
        )}
      </span>
    </section>
  );
}
