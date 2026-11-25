// A first Cloud send's setup, as one path: sign in, a plan, a model connection, then the chat starts.
// Each gate a new person meets after Send (the sign-in card, the pricing card, Set up Cloud) draws this
// strip at its top, so the card reads as a step on the way rather than a failure, and the person sees
// what is left. The step is read from the start (cloudSetupStep): the gates come in this order because
// the page holds a send for the plan once signed in (cloudStartPlanHeld) and the host checks the model
// connection before it makes a machine (CloudStartChat.swift).
import { useT } from "../i18n";
import { CLOUD_SETUP_STEPS, type CloudSetupStepId, type CloudSetupStepsLook } from "./cloudSetupStep";
import { Check } from "./icons";

const LABELS = {
  account: "cloudSetup.steps.account",
  plan: "cloudSetup.steps.plan",
  model: "cloudSetup.steps.model",
} as const satisfies Record<CloudSetupStepId, string>;

export function CloudSetupSteps({ current, look = "rail" }: { current: CloudSetupStepId; look?: CloudSetupStepsLook }) {
  const t = useT();
  const at = CLOUD_SETUP_STEPS.indexOf(current);
  const progress = t("cloudSetup.steps.progress", { step: at + 1, total: CLOUD_SETUP_STEPS.length });
  if (look === "count") {
    return (
      <p className="acpmux-cloud-steps" data-look="count">
        {progress} · {t(LABELS[current])}
      </p>
    );
  }
  return (
    <ol className="acpmux-cloud-steps" data-look={look} aria-label={progress}>
      {CLOUD_SETUP_STEPS.map((id, index) => {
        const state = index < at ? "done" : index === at ? "current" : "next";
        return (
          <li key={id} className="acpmux-cloud-steps__step" data-step={state} data-step-id={id}>
            <span className="acpmux-cloud-steps__mark" aria-hidden>
              {state === "done" ? <Check size={12} /> : index + 1}
            </span>
            <span className="acpmux-cloud-steps__label" {...(state === "current" ? { "aria-current": "step" } : {})}>
              {t(LABELS[id])}
            </span>
          </li>
        );
      })}
    </ol>
  );
}
