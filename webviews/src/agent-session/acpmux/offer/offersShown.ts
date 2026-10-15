import { experimentArm } from "../../../experiments/experiment";
import { sessionOffer } from "./sessionOffer.experiment";

/// Labs preview features as the host last said (`applyPreview`, `labs.previewFeatures`).
let preview = false;

/// Records the host's Labs preview setting; true when it changed what draws.
export function setOffersPreview(on: boolean): boolean {
  const before = offersShown();
  preview = on;
  return offersShown() !== before;
}

/// Whether an agent's offers draw (cx-lo9yf): with Labs preview features on, or the
/// `session-offer` experiment's `on` arm. Off by default; off, offers draw nothing.
export function offersShown(): boolean {
  return preview || experimentArm(sessionOffer) === "on";
}

/// The row kind of a task's result while its prompt waits in the chat's queue: its received line
/// (SuggestedTasks.tsx `ReceivedResult`), drawn before the prompt itself lands.
export const OFFER_RESULT = "offerResult";
