// l10n-allow-file: experiment descriptions are gallery (developer tool) text, never shown in the pane.
import { defineExperiment } from "../experiments/experiment";

/// Toasts v2 (Leo, 2026-11-19: "Promise toasts with Undo. One toast starts as a spinner ('Running
/// tests…') and turns into success or error in place without stacking; closing a tab or workspace,
/// or archiving a session, shows a one-line toast with an inline Undo."). The arms vary how a
/// stack toast (NoticeStack) draws its state and its Undo; the working → result change in place is
/// the same in every arm (NoticeQueue.promise). Compare in the gallery: `agent-pane.toasts`,
/// variants `promise-*` and `undo-*`, view `compare`. For dogfood set `cmux.experiments` to
/// `{"toasts-v2":"mark"}` in the pane's web inspector and reload.
export const toastsV2 = defineExperiment({
  id: "toasts-v2",
  title: "Toasts v2: promise and Undo",
  description:
    "How a toast shows working, success and error in one card that changes in place, and how its one-line Undo looks. Look for: no jump when the state changes, the mark and the Undo reading at a glance.",
  arms: {
    off: {
      label: "Off",
      description: "Today's toast: quiet glass, a ghost Undo; a working toast shows a spinner, a result its mark.",
    },
    mark: {
      label: "Mark",
      description:
        "Recommended. Quiet glass; the leading mark tells the state (spinner, a check in the success colour, the error ring in red, the error's title red); the Undo an ink-filled compact button.",
    },
    tinted: {
      label: "Tinted",
      description:
        "Status-tinted surface: success and error tint the card, its mark and its text in their colour (the rich-colours pattern). Conflicts with the never-red-slabs rule (Leo 2026-10-29: the card stays quiet glass); here only to compare.",
    },
    "accent-bar": {
      label: "Accent bar",
      description:
        "Quiet glass with a thin bar at the leading edge in the state's colour, the mark beside the text; ink-filled Undo.",
    },
  },
  defaultArm: "off",
});

export type ToastLook = keyof typeof toastsV2.arms;
