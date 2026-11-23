// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../../../experiments/experiment";

/// Hold to approve (Taste Board #176, "Hold to unlock ring progress"): an allow in the agent chat's
/// approval cards (PermissionCard.tsx, permissions/Panel.tsx) answers only after the pointer, or
/// Return, Space or the answer's letter, stays down for the hold time, while a ring around the
/// button's leading edge fills. Letting go early answers nothing. Deny never needs a hold. Off (the
/// default) keeps today's click and keys exactly. To try it, set `cmux.experiments` to
/// `{"hold-to-approve":"all"}` (or `"destructive"`) in the pane's web inspector and reload.
export const holdToApprove = defineExperiment({
  id: "hold-to-approve",
  title: "Hold to approve",
  description:
    "An allow answers only after a press-and-hold, with a ring that fills on the button; an early release answers nothing. Watch whether the hold reads as a deliberate act without slowing a routine approval.",
  arms: {
    off: { label: "Off", description: "Today: a click or a key allows at once." },
    all: { label: "Every allow", description: "Every Allow, Always allow and Approve plan needs the hold." },
    destructive: {
      label: "Only destructive",
      description:
        "Only an ask that deletes or moves files, or runs a command that deletes, overwrites or force-pushes (holdToApprove.ts isDestructiveAsk), needs the hold; the rest allow at once.",
    },
  },
  defaultArm: "off",
});

/// How long the hold lasts, in ms, per arm of `hold-to-approve-duration`.
export const HOLD_DURATIONS_MS = { ms400: 400, ms600: 600, ms900: 900, ms1500: 1500 } as const;

export const holdToApproveDuration = defineExperiment({
  id: "hold-to-approve-duration",
  title: "Hold to approve: hold time",
  description:
    'How long the pointer or key stays down before an allow answers, when hold to approve is on. Set `cmux.experiments` to `{"hold-to-approve-duration":"ms900"}` to tune it.',
  arms: {
    ms400: { label: "400 ms", description: "A short press: almost a click, still not an accident." },
    ms600: { label: "600 ms", description: "The default: a held press that reads as a decision." },
    ms900: { label: "900 ms", description: "A slower, more deliberate hold." },
    ms1500: { label: "1.5 s", description: "A long hold, for people who want approvals to feel heavy." },
  },
  defaultArm: "ms600",
});

export type HoldScope = keyof typeof holdToApprove.arms;
