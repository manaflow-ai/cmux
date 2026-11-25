// Cloud first use (cmux-tui/docs/model-connections.md, "Cloud first use"; Capy's Models onboarding):
// a Cloud chat whose picked model no connection serves shows this card in the chat, under the
// message, instead of a failure. Its heart is the inline connect card (ConnectCard.tsx) for the
// model's family: the mark, one line, one button that signs in through cmux's browser on this Mac
// (`cloud.setUp`, cloudSetup.ts: `setUpClaude` runs Claude's one click, `connectChatGPT` Codex's),
// and a progress line under it while that runs, with Cancel. The other family's way in, Add an API
// key (or the inline key field, when the host takes one) and Open Settings stay as quiet buttons.
// Once a connection serving the model appears, the chat starts by itself with the same prompt.
import { useId } from "react";
import { useT } from "../i18n";
import { cloudSetupActions, type CloudSetupAction, type CloudSetupNeed } from "../cloudSetup";
import type { ConnectProgress } from "../claudeConnect";
import { ConnectCard, type ConnectCardLook } from "../ConnectCard";
import { CloudSetupSteps, type CloudSetupStepsLook } from "./CloudSetupSteps";

const LABELS = {
  connectChatGPT: "cloudSetup.chatgpt",
  setUpClaude: "cloudSetup.claude",
  addKey: "cloudSetup.apiKey",
  openSettings: "cloudSetup.settings",
} as const satisfies Record<CloudSetupAction, string>;

export function CloudSetupCard({
  need,
  waiting = false,
  steps,
  look = "card",
  progress,
  onSetUp,
  onCancel,
  onApiKey,
  onDismiss,
}: {
  need: CloudSetupNeed;
  /// A first send's model step: the setup strip (CloudSetupSteps) above the title.
  steps?: CloudSetupStepsLook;
  /// A button's way in is out: the card says it waits, and the buttons rest until it ends.
  waiting?: boolean;
  onSetUp?: (action: CloudSetupAction) => void;
  /// The connect card's look (ConnectCard): `card` ships.
  look?: ConnectCardLook;
  /// The host's own progress for the sign-in, when it says more than `waiting` (a gallery's steps).
  progress?: ConnectProgress;
  /// Cancel while it waits: withdraws the sign-in.
  onCancel?: () => void;
  /// Saves a pasted API key here; absent: Add an API key opens Settings.
  onApiKey?: (key: string) => Promise<void>;
  /// Not now: leaves the card; the prompt stays in the composer.
  onDismiss?: () => void;
}) {
  const t = useT();
  const [primary, ...rest] = cloudSetupActions(need);
  const others = rest.filter((action) => !(onApiKey && action === "addKey"));
  const titleId = useId();
  const shown = progress ?? { phase: waiting ? "signing_in" : null, error: null };
  return (
    <section className="acpmux-cloud-setup" aria-labelledby={titleId} data-waiting={waiting || undefined}>
      {steps && <CloudSetupSteps current="model" look={steps} />}
      <strong className="acpmux-cloud-setup__title" id={titleId}>
        {t("cloudSetup.title")}
      </strong>
      {need.model && <p className="acpmux-cloud-setup__body">{t("cloudSetup.model", { model: need.model })}</p>}
      <ConnectCard
        family={need.family}
        look={look}
        progress={shown}
        {...(onSetUp && primary ? { onBegin: () => onSetUp(primary) } : {})}
        {...(onCancel ? { onCancel } : {})}
        {...(onApiKey ? { onApiKey } : {})}
      />
      <span className="acpmux-cloud-ask__actions acpmux-cloud-setup__actions">
        {others.map((action) => (
          <button
            key={action}
            type="button"
            className="acpmux-cloud-ask__button"
            data-action={action}
            disabled={waiting || !onSetUp}
            onClick={() => onSetUp?.(action)}
          >
            {t(LABELS[action])}
          </button>
        ))}
        {onDismiss && !waiting && (
          <button type="button" className="acpmux-cloud-ask__button" data-action="dismiss" onClick={() => onDismiss()}>
            {t("harness.notNow")}
          </button>
        )}
      </span>
    </section>
  );
}
