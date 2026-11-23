// l10n-allow-file: experiment descriptions are gallery/debug text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// What the person's own queued prompts do after they press Stop (design court 2026-11-23,
/// d-6d563cb618). Other agents' messages and automatic retries already wait after a person's Stop
/// (acpmux `hub/cancel.rs` `hold_agent_messages`); this is only about the person's own queue.
/// The `hold` arm sends the Stop with `_meta.acpmux.holdQueue` (direct.ts `cancel`), and acpmux
/// holds those prompts for Resume (`hold_own_prompts`). The court recommends `hold` as the
/// default; `run-on` stays the default until that is taken, as it was shipped on purpose.
export const stopHoldsQueue = defineExperiment({
  id: "stop-holds-queue",
  title: "Queued prompts after Stop",
  description:
    "Queue a prompt behind a running turn, then press Stop. Watch whether the queued prompt starts a turn by itself or waits under a Paused after Stop note with Resume.",
  arms: {
    "run-on": {
      label: "Run on",
      description: "Stop ends the running turn; your next queued prompt starts at once, as before.",
    },
    hold: {
      label: "Hold for Resume",
      description:
        "Stop ends the running turn and your queued prompts wait under Paused after Stop until you press Resume or send one now.",
    },
  },
  defaultArm: "run-on",
});

export type StopHoldsQueueArm = keyof typeof stopHoldsQueue.arms;
