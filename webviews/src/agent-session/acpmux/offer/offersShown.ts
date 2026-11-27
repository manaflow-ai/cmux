import { experimentArm } from "../../../experiments/experiment";
import { sessionOffer } from "./sessionOffer.experiment";

/// Whether suggested tasks are on, as the host last said (`applySuggestedTasks`): the
/// `sessions.promptSuggestions` setting, or the Debug tunable `agent.suggestedTasks` forcing them on.
let toggle = false;

/// Records the host's suggested tasks toggle; true when it changed what draws.
export function setSuggestedTasks(on: boolean): boolean {
  const before = offersShown();
  toggle = on;
  return offersShown() !== before;
}

/// Whether an agent's offers draw (cx-lo9yf): with the host's suggested tasks on, or the
/// `session-offer` experiment's `on` arm. The host's value is Settings > Suggest Follow-Up Tasks (on by
/// default) or the `agent.suggestedTasks` Debug toggle forcing it on; off, offers draw nothing.
export function offersShown(): boolean {
  return toggle || experimentArm(sessionOffer) === "on";
}

/// The row kind of a task's result while its prompt waits in the chat's queue: its received line
/// (SuggestedTasks.tsx `ReceivedResult`), drawn before the prompt itself lands.
export const OFFER_RESULT = "offerResult";
